local plan = require("nuget.plan")
local solution = require("nuget.solution")
local xml = require("nuget.xml")

describe("xml", function()
  local text = table.concat({
    "<Project>",
    '  <!-- <PackageReference Include="Serilog" Version="1.0.0" /> -->',
    "  <ItemGroup>",
    '    <PackageReference Include="Serilog" Version="2.10.0" />',
    '    <PackageReference Include="Newtonsoft.Json">',
    "      <Version>12.0.1</Version>",
    "    </PackageReference>",
    "    <PackageReference Include='Polly' VersionOverride='7.2.0' />",
    '    <PackageReference Include="Dapper" Version="$(DapperVersion)" />',
    '    <PackageReference Include="A;B" Version="1.0.0" />',
    "  </ItemGroup>",
    "</Project>",
    "",
  }, "\n")

  it("finds items by id, ignoring comments and case", function()
    assert.equals(1, #xml.find(text, "PackageReference", "serilog"))
    assert.equals(0, #xml.find(text, "PackageReference", "Nope"))
    assert.equals(1, #xml.find(text, "PackageReference", "B"))
  end)

  it("reads versions from attributes and child elements", function()
    assert.equals("2.10.0", xml.version_of(xml.find(text, "PackageReference", "Serilog")[1], "version").value)
    assert.equals("12.0.1", xml.version_of(xml.find(text, "PackageReference", "Newtonsoft.Json")[1], "version").value)
    assert.equals("7.2.0", xml.version_of(xml.find(text, "PackageReference", "Polly")[1], "versionoverride").value)
  end)

  it("changes only the version it is asked to", function()
    local out = xml.set_version(text, "PackageReference", "Serilog", "version", "4.4.0")
    assert.matches('<PackageReference Include="Serilog" Version="4.4.0" />', out, 1, true)
    -- The commented-out copy is left alone
    assert.matches('<PackageReference Include="Serilog" Version="1.0.0" />', out, 1, true)
    assert.equals(#text - 1, #out) -- "2.10.0" -> "4.4.0", nothing else moved

    out = xml.set_version(text, "PackageReference", "Newtonsoft.Json", "version", "13.0.4")
    assert.matches("<Version>13.0.4</Version>", out, 1, true)

    out = xml.set_version(text, "PackageReference", "Polly", "versionoverride", "8.0.0")
    assert.matches("VersionOverride='8.0.0'", out, 1, true)
  end)

  it("refuses to overwrite an MSBuild property", function()
    local out, err = xml.set_version(text, "PackageReference", "Dapper", "version", "2.1.0")
    assert.is_nil(out)
    assert.matches("DapperVersion", err)
  end)

  it("removes an item with its line", function()
    local out = xml.remove(text, "PackageReference", "Serilog")
    assert.is_nil(out:find('Include="Serilog" Version="2.10.0"', 1, true))
    assert.is_not_nil(out:find('<ItemGroup>\n    <PackageReference Include="Newtonsoft.Json">', 1, true))
    out = xml.remove(text, "PackageReference", "Newtonsoft.Json")
    assert.is_nil(out:find("Newtonsoft", 1, true))
    assert.is_nil(out:find("<Version>12.0.1</Version>", 1, true))
  end)

  it("will not remove one package of a list", function()
    local out, err = xml.remove(text, "PackageReference", "B")
    assert.is_nil(out)
    assert.matches("together with other packages", err)
  end)
end)

describe("version origin", function()
  local dir

  local function write(path, lines)
    vim.fn.mkdir(vim.fs.dirname(dir .. "/" .. path), "p")
    vim.fn.writefile(lines, dir .. "/" .. path)
  end

  before_each(function()
    solution.clear_cache()
    dir = vim.fs.normalize(vim.fn.tempname())
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  it("knows every place a version can be written", function()
    write("Directory.Packages.props", {
      "<Project>",
      "  <PropertyGroup><ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally></PropertyGroup>",
      '  <ItemGroup><PackageVersion Include="Serilog" Version="2.10.0" /></ItemGroup>',
      '  <ItemGroup><GlobalPackageReference Include="Analyzers" Version="8.0.0" /></ItemGroup>',
      "</Project>",
    })
    write("Directory.Build.props", {
      "<Project><ItemGroup>",
      '  <PackageReference Include="Imported" Version="1.0.0" />',
      '  <PackageReference Include="ImportedCentral" />',
      "</ItemGroup></Project>",
    })
    write("Web/Web.csproj", {
      '<Project Sdk="Microsoft.NET.Sdk"><ItemGroup>',
      '  <PackageReference Include="Serilog" />',
      '  <PackageReference Include="Polly" VersionOverride="7.2.0" />',
      "</ItemGroup></Project>",
    })
    local web = dir .. "/Web/Web.csproj"
    local props = dir .. "/Directory.Packages.props"
    local build = dir .. "/Directory.Build.props"
    assert.same({ kind = "central", file = props, ref_file = web }, solution.version_origin(web, "Serilog"))
    assert.same({ kind = "override", file = web, ref_file = web }, solution.version_origin(web, "Polly"))
    assert.same({ kind = "imported", file = build, ref_file = build }, solution.version_origin(web, "Imported"))
    assert.same(
      { kind = "imported_central", file = props, ref_file = build },
      solution.version_origin(web, "ImportedCentral")
    )
    assert.same({ kind = "global", file = props, ref_file = props }, solution.version_origin(web, "Analyzers"))
  end)

  it("knows a version in the project itself", function()
    write(
      "Api/Api.csproj",
      { '<Project><ItemGroup><PackageReference Include="Serilog" Version="2.10.0" /></ItemGroup></Project>' }
    )
    local api = dir .. "/Api/Api.csproj"
    assert.same({ kind = "project", file = api, ref_file = api }, solution.version_origin(api, "Serilog"))
  end)

  it("follows a Directory.Build.props that imports the one above it", function()
    write(
      "Directory.Build.props",
      { '<Project><ItemGroup><PackageReference Include="Root" Version="1.0.0" /></ItemGroup></Project>' }
    )
    write("src/Directory.Build.props", {
      "<Project>",
      '  <Import Project="$([MSBuild]::GetPathOfFileAbove('
        .. "'Directory.Build.props', '$(MSBuildThisFileDirectory)../'))\" />",
      "</Project>",
    })
    write("src/Api/Api.csproj", { "<Project />" })
    local origin = solution.version_origin(dir .. "/src/Api/Api.csproj", "Root")
    assert.equals("imported", origin.kind)
    assert.equals(dir .. "/Directory.Build.props", origin.file)
  end)
end)

describe("plan", function()
  local function pkg(origins)
    local projects = {}
    for path, origin in pairs(origins) do
      projects[path] = { requested = "1.0.0", resolved = "1.0.0", frameworks = { "net8.0" }, origin = origin }
    end
    return { id = "Pkg", projects = projects, transitive = {}, vulnerabilities = {}, vulnerable_in = {} }
  end

  local function kinds(steps)
    return vim.tbl_map(function(s)
      return s.kind .. ":" .. (s.project or s.file) .. (s.tag and (":" .. s.tag) or "")
    end, steps)
  end

  it("uses dotnet add per project for project versions and overrides", function()
    local p = pkg({
      ["/A.csproj"] = { kind = "project", file = "/A.csproj" },
      ["/B.csproj"] = { kind = "override", file = "/B.csproj" },
    })
    assert.same({ "add:/A.csproj", "add:/B.csproj" }, kinds(plan.set_version(p, "2.0.0", { "/A.csproj", "/B.csproj" })))
  end)

  it("updates a central version once, through a project that uses it", function()
    local p = pkg({
      ["/A.csproj"] = { kind = "central", file = "/D.props" },
      ["/B.csproj"] = { kind = "central", file = "/D.props" },
      ["/C.csproj"] = { kind = "override", file = "/C.csproj" },
    })
    local steps = plan.set_version(p, "2.0.0", { "/C.csproj", "/A.csproj", "/B.csproj" })
    -- The override is updated in its project, the central version through A, never through C
    assert.same({ "add:/C.csproj", "add:/A.csproj" }, kinds(steps))
    assert.same({ "/A.csproj", "/B.csproj" }, steps[2].shared_with)
  end)

  it("edits files dotnet will not touch", function()
    local p = pkg({
      ["/A.csproj"] = { kind = "imported", file = "/Directory.Build.props", ref_file = "/Directory.Build.props" },
      ["/B.csproj"] = { kind = "imported", file = "/Directory.Build.props", ref_file = "/Directory.Build.props" },
      ["/C.csproj"] = { kind = "global", file = "/Directory.Packages.props", ref_file = "/Directory.Packages.props" },
      ["/D.csproj"] = {
        kind = "imported_central",
        file = "/Directory.Packages.props",
        ref_file = "/Directory.Build.props",
      },
    })
    local steps = plan.set_version(p, "2.0.0", { "/A.csproj", "/B.csproj", "/C.csproj", "/D.csproj" })
    assert.same({
      "edit:/Directory.Build.props:PackageReference",
      "edit:/Directory.Packages.props:GlobalPackageReference",
      "edit:/Directory.Packages.props:PackageVersion",
    }, kinds(steps))
    assert.is_true(plan.needs_restore(steps))
  end)

  it("removes shared items from the file that declares them", function()
    local p = pkg({
      ["/A.csproj"] = {
        kind = "imported_central",
        file = "/Directory.Packages.props",
        ref_file = "/Directory.Build.props",
      },
      ["/B.csproj"] = { kind = "central", file = "/Directory.Packages.props", ref_file = "/B.csproj" },
    })
    assert.same(
      { "delete:/Directory.Build.props:PackageReference", "remove:/B.csproj" },
      kinds(plan.remove(p, { "/A.csproj", "/B.csproj" }))
    )
  end)

  it("names the projects a shared change also affects", function()
    local p = pkg({
      ["/A.csproj"] = { kind = "imported", file = "/Directory.Build.props", ref_file = "/Directory.Build.props" },
      ["/B.csproj"] = { kind = "imported", file = "/Directory.Build.props", ref_file = "/Directory.Build.props" },
    })
    local steps = plan.set_version(p, "2.0.0", { "/A.csproj" })
    assert.same({ "/B.csproj" }, plan.also_affected(steps, { "/A.csproj" }))
    assert.same(
      {},
      plan.also_affected(plan.set_version(p, "2.0.0", { "/A.csproj", "/B.csproj" }), { "/A.csproj", "/B.csproj" })
    )
  end)
end)
