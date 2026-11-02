local cli = require("nuget.cli")
local model = require("nuget.model")
local solution = require("nuget.solution")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")

local function fixture(name)
  return cli.decode(table.concat(vim.fn.readfile(root .. "/fixtures/" .. name), "\n"))
end

--- A model of the fixture solution: Api (Newtonsoft.Json 12.0.1 vulnerable, Serilog 2.10.0,
--- Microsoft.Azure.Storage.Blob deprecated) and Lib (Newtonsoft.Json 13.0.1, Serilog 3.0.0).
local function solution_model()
  local m = model.new()
  for kind, file in pairs({
    plain = "list_plain.json",
    outdated = "list_outdated.json",
    vulnerable = "list_vulnerable.json",
    deprecated = "list_deprecated.json",
  }) do
    model.apply(m, kind, fixture(file))
  end
  return m
end

local function ids(list)
  return vim.tbl_map(function(pkg)
    return pkg.id
  end, list)
end

describe("model", function()
  before_each(function()
    solution.clear_cache()
  end)

  it("lists the projects by name", function()
    local m = solution_model()
    assert.same({ "Api", "Lib" }, vim.tbl_map(solution.project_name, m.projects))
  end)

  it("merges the direct references of every project", function()
    local m = solution_model()
    assert.same({ "Microsoft.Azure.Storage.Blob", "Newtonsoft.Json", "Serilog" }, ids(model.installed(m)))
    local json = m.packages["newtonsoft.json"]
    assert.same({ "13.0.1", "12.0.1" }, model.versions(json))
    assert.same({ "net8.0" }, json.projects["/repo/A/Api/Api.csproj"].frameworks)
  end)

  it("knows the latest version from the outdated report", function()
    local m = solution_model()
    assert.equals("13.0.4", m.packages["newtonsoft.json"].latest)
    assert.equals("4.4.0", m.packages["serilog"].latest)
    assert.is_nil(m.packages["microsoft.azure.storage.blob"].latest)
  end)

  it("finds the projects to update", function()
    local m = solution_model()
    local paths = model.projects_below(m.packages["newtonsoft.json"], "13.0.1")
    assert.same({ "/repo/A/Api/Api.csproj" }, paths)
  end)

  it("lists updates with vulnerable packages first", function()
    local m = solution_model()
    assert.same({ "Newtonsoft.Json", "Serilog" }, ids(model.updates(m)))
  end)

  it("records vulnerabilities and where they are", function()
    local m = solution_model()
    local json = m.packages["newtonsoft.json"]
    assert.equals(1, #json.vulnerabilities)
    assert.equals("High", json.vulnerabilities[1].severity)
    assert.matches("GHSA%-5crp%-9r3c%-p9vr", json.vulnerabilities[1].url)
    assert.is_true(json.vulnerable_in["/repo/A/Api/Api.csproj"])
    assert.is_nil(json.vulnerable_in["/repo/A/Lib/Lib.csproj"])
    local rank, severity = model.severity(json)
    assert.equals(3, rank)
    assert.equals("High", severity)
  end)

  it("records deprecations with their alternative", function()
    local m = solution_model()
    local blob = m.packages["microsoft.azure.storage.blob"]
    assert.same({ "Legacy" }, blob.deprecation.reasons)
    assert.equals("Azure.Storage.Blobs", blob.deprecation.alternative)
  end)

  it("finds packages referenced at different versions", function()
    local m = solution_model()
    assert.same({ "Newtonsoft.Json", "Serilog" }, ids(model.inconsistent(m)))
  end)

  it("keeps transitive packages apart from direct ones", function()
    local m = model.new()
    model.apply(m, "plain", fixture("list_plain.json"))
    model.apply(m, "transitive", fixture("list_transitive.json"))
    local storage = m.packages["microsoft.azure.storage.common"]
    assert.is_false(model.is_direct(storage))
    assert.equals("11.2.3", storage.transitive["/repo/A/Api/Api.csproj"])
    assert.is_false(vim.tbl_contains(ids(model.installed(m)), "Microsoft.Azure.Storage.Common"))
  end)

  it("lists vulnerable transitive packages, which need a direct reference to fix", function()
    local m = model.new()
    model.apply(m, "plain", fixture("list_plain.json"))
    model.apply(m, "vulnerable", {
      projects = {
        {
          path = "/repo/A/Lib/Lib.csproj",
          frameworks = {
            {
              framework = "net8.0",
              transitivePackages = {
                {
                  id = "System.Text.Json",
                  resolvedVersion = "8.0.0",
                  vulnerabilities = { { severity = "Critical", advisoryurl = "https://example.com/a" } },
                },
              },
            },
          },
        },
      },
    })
    assert.same({ "System.Text.Json" }, ids(model.transitive_vulnerable(m)))
    assert.same({}, ids(model.updates(m)))
  end)

  it("gives the same result whatever order the reports arrive in", function()
    local m = model.new()
    for _, pair in ipairs({
      { "deprecated", "list_deprecated.json" },
      { "outdated", "list_outdated.json" },
      { "vulnerable", "list_vulnerable.json" },
      { "plain", "list_plain.json" },
    }) do
      model.apply(m, pair[1], fixture(pair[2]))
    end
    local reference = solution_model()
    assert.same(ids(model.installed(reference)), ids(model.installed(m)))
    assert.same(ids(model.updates(reference)), ids(model.updates(m)))
    assert.equals(reference.packages["newtonsoft.json"].latest, m.packages["newtonsoft.json"].latest)
  end)
end)

describe("central package management", function()
  local dir

  before_each(function()
    solution.clear_cache()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir .. "/Web", "p")
    vim.fn.mkdir(dir .. "/Legacy", "p")
    vim.fn.writefile({
      "<Project>",
      "  <PropertyGroup><ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally></PropertyGroup>",
      "</Project>",
    }, dir .. "/Directory.Packages.props")
    vim.fn.writefile({ '<Project Sdk="Microsoft.NET.Sdk" />' }, dir .. "/Web/Web.csproj")
    vim.fn.writefile({
      '<Project Sdk="Microsoft.NET.Sdk">',
      "  <PropertyGroup><ManagePackageVersionsCentrally>false</ManagePackageVersionsCentrally></PropertyGroup>",
      "</Project>",
    }, dir .. "/Legacy/Legacy.csproj")
  end)

  after_each(function()
    vim.fn.delete(dir, "rf")
  end)

  it("finds the Directory.Packages.props above a project", function()
    assert.equals(
      vim.fs.normalize(dir .. "/Directory.Packages.props"),
      solution.central_props(dir .. "/Web/Web.csproj")
    )
  end)

  it("respects a project that opts out", function()
    assert.is_nil(solution.central_props(dir .. "/Legacy/Legacy.csproj"))
  end)

  it("records where each project takes its version from", function()
    local function report(paths)
      local projects = {}
      for _, path in ipairs(paths) do
        table.insert(projects, {
          path = path,
          frameworks = {
            { framework = "net8.0", topLevelPackages = { { id = "Serilog", requestedVersion = "4.4.0" } } },
          },
        })
      end
      return { projects = projects }
    end
    local m = model.new()
    model.apply(m, "plain", report({ dir .. "/Web/Web.csproj", dir .. "/Legacy/Legacy.csproj" }))
    local serilog = m.packages.serilog
    -- Web takes its version from Directory.Packages.props, Legacy opted out
    assert.equals("central", serilog.projects[dir .. "/Web/Web.csproj"].origin.kind)
    assert.equals("unknown", serilog.projects[dir .. "/Legacy/Legacy.csproj"].origin.kind)
    assert.equals(vim.fs.normalize(dir .. "/Directory.Packages.props"), serilog.central)
  end)
end)

describe("cli output", function()
  it("decodes JSON preceded by other output", function()
    local data =
      cli.decode('  Determining projects to restore...\nwarn : something\n{ "version": 1, "projects": [] }\n')
    assert.same({ version = 1, projects = {} }, data)
  end)

  it("returns nil when there is no JSON", function()
    assert.is_nil(cli.decode("error: something went wrong"))
  end)

  it("picks the error line from a failed command", function()
    local msg = cli.error_message(
      "",
      "Restoring...\nerror: NU1101: Unable to find package Nope. No packages exist with this id\n"
    )
    assert.matches("Unable to find package Nope", msg)
  end)
end)
