local cli = require("nuget.cli")
local model = require("nuget.model")
local registry = require("nuget.registry")
local solution = require("nuget.solution")
local view = require("nuget.ui.view")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local icons = require("nuget").default_config.icons

local function fixture(name)
  return cli.decode(table.concat(vim.fn.readfile(root .. "/fixtures/" .. name), "\n"))
end

local function state(tab, extra)
  solution.clear_cache()
  local m = model.new()
  for kind, file in pairs({
    plain = "list_plain.json",
    outdated = "list_outdated.json",
    vulnerable = "list_vulnerable.json",
    deprecated = "list_deprecated.json",
  }) do
    model.apply(m, kind, fixture(file))
  end
  return vim.tbl_extend("force", {
    tab = tab,
    model = m,
    loading = {},
    filter = "",
    marks = {},
    search = { query = "", results = {}, loading = false, more = false, problems = {} },
    icons = icons,
  }, extra or {})
end

local function texts(lines)
  return vim.tbl_map(function(l)
    return l.text
  end, lines)
end

local function check_highlights(lines)
  for _, line in ipairs(lines) do
    for _, h in ipairs(line.hl) do
      assert.is_true(h[1] >= 0 and h[2] <= #line.text and h[1] < h[2], line.text)
    end
  end
end

describe("list view", function()
  it("shows installed packages with their versions, updates and badges", function()
    local lines = view.list(state("installed"), 100)
    check_highlights(lines)
    local t = texts(lines)
    assert.equals(3, #t)
    assert.matches("^Newtonsoft%.Json%s+13%.0%.1, 12%.0%.1 ↑ 13%.0%.4.*High.*≠", t[2])
    assert.matches("deprecated", t[1])
    assert.equals("Newtonsoft.Json", lines[2].item.package.id)
  end)

  it("puts a mark in front of updates", function()
    local s = state("updates", { marks = { serilog = true } })
    local t = texts(view.list(s, 100))
    assert.matches("^" .. icons.unmarked .. " Newtonsoft%.Json", t[1])
    assert.matches("^" .. icons.marked .. " Serilog.*2 projects", t[2])
  end)

  it("shows which project has which version when consolidating", function()
    local t = texts(view.list(state("consolidate"), 120))
    assert.matches("13%.0%.1 %(Lib%) · 12%.0%.1 %(Api%)", t[1])
  end)

  it("filters by id", function()
    local t = texts(view.list(state("installed", { filter = "seri" }), 100))
    assert.equals(1, #t)
    assert.matches("^Serilog", t[1])
  end)

  it("says when it is still checking for updates", function()
    local s = state("updates")
    s.model = model.new()
    s.loading = { outdated = true }
    assert.same({ "Checking for updates…" }, texts(view.list(s, 100)))
  end)

  it("lists search results and marks the installed ones", function()
    local data = fixture("search.json")
    local results = {}
    for _, source in ipairs(data.searchResult) do
      for _, p in ipairs(source.packages or {}) do
        table.insert(
          results,
          { id = p.id, version = p.latestVersion, downloads = p.totalDownloads, source = source.sourceName }
        )
      end
    end
    local s = state("browse", { search = { query = "Serilog", results = results, loading = false, more = true } })
    local lines = view.list(s, 100)
    check_highlights(lines)
    local t = texts(lines)
    assert.matches("^Serilog%s+4%.4%.0%s+3%.5B.*✓ 3%.0%.0, 2%.10%.0", t[1])
    assert.matches("press %]", t[#t])
  end)

  it("never makes a line wider than the pane", function()
    for _, tab in ipairs({ "installed", "updates", "consolidate" }) do
      for _, line in ipairs(view.list(state(tab), 60)) do
        -- Badges may run past; ids and versions are cut to fit
        assert.is_true(vim.fn.strdisplaywidth(line.item and line.item.package.id or "") <= 60)
      end
    end
  end)
end)

describe("details view", function()
  local meta = registry.from_catalog({
    id = "Newtonsoft.Json",
    version = "13.0.4",
    authors = "James Newton-King",
    licenseExpression = "MIT",
    projectUrl = "https://www.newtonsoft.com/json",
    tags = { "json" },
    published = "2025-09-16T00:00:00Z",
    description = "Json.NET is a popular high-performance JSON framework for .NET",
    dependencyGroups = {
      { targetFramework = ".NETFramework4.5" },
      { targetFramework = ".NETStandard2.0" },
      { targetFramework = "net8.0", dependencies = { { id = "Foo", range = "[1.0.0, )" } } },
      { targetFramework = "net6.0" },
    },
  })

  it("shows installs, vulnerabilities and metadata", function()
    local s = state("installed")
    local pkg = s.model.packages["newtonsoft.json"]
    local lines = view.details({ kind = "package", package = pkg }, { model = s.model, icons = icons, meta = meta }, 50)
    check_highlights(lines)
    local text = table.concat(texts(lines), "\n")
    assert.matches("Latest 13%.0%.4", text)
    assert.matches("Api%s+12%.0%.1%s+net8%.0", text)
    assert.matches("High%s+https://github%.com/advisories/GHSA%-5crp%-9r3c%-p9vr", text)
    assert.matches("License MIT", text)
    assert.matches("Version 13%.0%.4  2025%-09%-16", text)
  end)

  it("lists the dependencies of the frameworks in use first", function()
    local s = state("installed")
    local pkg = s.model.packages["newtonsoft.json"]
    local t =
      texts(view.details({ kind = "package", package = pkg }, { model = s.model, icons = icons, meta = meta }, 50))
    local deps
    for i, line in ipairs(t) do
      if line == "Dependencies" then
        deps = i
      end
    end
    assert.equals("  net8.0", t[deps + 1])
    assert.equals("    Foo [1.0.0, )", t[deps + 2])
    assert.matches("^  %+ net6%.0", t[#t])
  end)

  it("shows the deprecation and its alternative", function()
    local s = state("installed")
    local pkg = s.model.packages["microsoft.azure.storage.blob"]
    local text = table.concat(
      texts(view.details({ kind = "package", package = pkg }, { model = s.model, icons = icons }, 50)),
      "\n"
    )
    assert.matches("Deprecated%s+Legacy", text)
    assert.matches("Alternative: Azure%.Storage%.Blobs", text)
  end)

  it("describes the latest version, or the highest installed", function()
    local s = state("installed")
    assert.same(
      { "Newtonsoft.Json", "13.0.4" },
      { view.detail_version({ kind = "package", package = s.model.packages["newtonsoft.json"] }) }
    )
    assert.same(
      { "Microsoft.Azure.Storage.Blob", "11.2.3" },
      { view.detail_version({ kind = "package", package = s.model.packages["microsoft.azure.storage.blob"] }) }
    )
  end)
end)

describe("formatting", function()
  it("abbreviates download counts", function()
    assert.equals("3.5B", view.downloads(3521116863))
    assert.equals("12M", view.downloads(12345678))
    assert.equals("1.5K", view.downloads(1500))
    assert.equals("999", view.downloads(999))
  end)

  it("fits text to a width", function()
    assert.equals("abc  ", view.fit("abc", 5))
    assert.equals("abcd…", view.fit("abcdefgh", 5))
  end)
end)
