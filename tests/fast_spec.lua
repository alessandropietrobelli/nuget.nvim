local cli = require("nuget.cli")
local fast = require("nuget.fast")
local model = require("nuget.model")
local solution = require("nuget.solution")

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")

local function fixture(name)
  return cli.decode(table.concat(vim.fn.readfile(root .. "/fixtures/" .. name), "\n"))
end

local function plain_model()
  solution.clear_cache()
  local m = model.new()
  model.apply(m, "transitive", fixture("list_transitive.json"))
  return m
end

describe("quick checks", function()
  it("matches advisories against the resolved version", function()
    local db = {
      ["newtonsoft.json"] = {
        { url = "https://github.com/advisories/GHSA-5crp-9r3c-p9vr", severity = "High", versions = "(, 13.0.1)" },
      },
    }
    assert.equals(1, #fast.vulnerabilities_of(db, "Newtonsoft.Json", "12.0.1"))
    assert.equals(0, #fast.vulnerabilities_of(db, "Newtonsoft.Json", "13.0.1"))
    assert.equals(0, #fast.vulnerabilities_of(db, "Serilog", "2.10.0"))
  end)

  it("marks only the projects that resolve a vulnerable version", function()
    local m = plain_model()
    local db = {
      ["newtonsoft.json"] = { { url = "https://example.com/a", severity = "High", versions = "(, 13.0.1)" } },
    }
    for _, pkg in pairs(m.packages) do
      for _, r in ipairs(model.resolutions(pkg)) do
        model.add_vulnerabilities(m, pkg.id, r.project, fast.vulnerabilities_of(db, pkg.id, r.version))
      end
    end
    local json = m.packages["newtonsoft.json"]
    assert.is_true(json.vulnerable_in["/repo/A/Api/Api.csproj"])
    assert.is_nil(json.vulnerable_in["/repo/A/Lib/Lib.csproj"])
    assert.equals(1, #json.vulnerabilities)
  end)

  it("checks transitive packages too", function()
    local m = plain_model()
    local db = {
      ["microsoft.azure.storage.common"] = {
        { url = "https://example.com/t", severity = "Critical", versions = "[11.0.0, 12.0.0)" },
      },
    }
    for _, pkg in pairs(m.packages) do
      for _, r in ipairs(model.resolutions(pkg)) do
        model.add_vulnerabilities(m, pkg.id, r.project, fast.vulnerabilities_of(db, pkg.id, r.version))
      end
    end
    local ids = vim.tbl_map(function(p)
      return p.id
    end, model.transitive_vulnerable(m))
    assert.same({ "Microsoft.Azure.Storage.Common" }, ids)
  end)

  it("does not add the same advisory twice", function()
    local m = plain_model()
    local a = { { severity = "High", url = "https://example.com/a" } }
    model.add_vulnerabilities(m, "Newtonsoft.Json", "/repo/A/Api/Api.csproj", a)
    model.add_vulnerabilities(m, "Newtonsoft.Json", "/repo/A/Api/Api.csproj", a)
    assert.equals(1, #m.packages["newtonsoft.json"].vulnerabilities)
  end)

  it("shows hinted latest versions until the outdated report replaces them", function()
    local m = plain_model()
    model.hint_latest(m, "Serilog", "4.4.0")
    -- A guess for a package the report will consider up to date
    model.hint_latest(m, "Microsoft.Azure.Storage.Blob", "99.0.0")
    assert.is_true(model.has_update(m.packages["microsoft.azure.storage.blob"]))
    assert.equals("4.4.0", m.packages.serilog.latest)

    model.apply(m, "outdated", fixture("list_outdated.json"))
    assert.equals("4.4.0", m.packages.serilog.latest)
    assert.is_nil(m.packages["microsoft.azure.storage.blob"].latest)
    -- Once the report is in, later hints are ignored
    model.hint_latest(m, "Microsoft.Azure.Storage.Blob", "99.0.0")
    assert.is_nil(m.packages["microsoft.azure.storage.blob"].latest)
  end)

  it("keeps the hints when the outdated report had problems", function()
    local m = plain_model()
    model.hint_latest(m, "Microsoft.Azure.Storage.Blob", "99.0.0")
    model.hint_latest(m, "Serilog", "4.4.0")
    -- A feed failed: the report is empty and says so
    model.apply(m, "outdated", { projects = {}, problems = { "An error occurred while sending the request." } })
    assert.equals("99.0.0", m.packages["microsoft.azure.storage.blob"].latest)
    assert.equals("4.4.0", m.packages.serilog.latest)
  end)

  it("keeps a deprecation once known", function()
    local m = plain_model()
    model.set_deprecation(
      m,
      "Microsoft.Azure.Storage.Blob",
      { reasons = { "Legacy" }, alternative = "Azure.Storage.Blobs" }
    )
    assert.equals("Azure.Storage.Blobs", m.packages["microsoft.azure.storage.blob"].deprecation.alternative)
  end)

  it("lists every resolution of a package", function()
    local m = plain_model()
    local res = model.resolutions(m.packages["newtonsoft.json"])
    table.sort(res, function(a, b)
      return a.project < b.project
    end)
    assert.same({
      { project = "/repo/A/Api/Api.csproj", version = "12.0.1" },
      { project = "/repo/A/Lib/Lib.csproj", version = "13.0.1" },
    }, res)
  end)
end)

describe("each_limited", function()
  it("never runs more than the limit at once and finishes once", function()
    local running, peak, finished, done_calls = 0, 0, 0, 0
    local items = {}
    for i = 1, 20 do
      items[i] = i
    end
    fast.each_limited(items, 3, function(_, done)
      running = running + 1
      peak = math.max(peak, running)
      vim.defer_fn(function()
        running = running - 1
        finished = finished + 1
        done()
      end, 5)
    end, function()
      done_calls = done_calls + 1
    end)
    assert.is_true(vim.wait(2000, function()
      return done_calls == 1
    end, 5))
    assert.equals(20, finished)
    assert.equals(3, peak)
  end)

  it("finishes at once with nothing to do", function()
    local done = false
    fast.each_limited({}, 3, function() end, function()
      done = true
    end)
    assert.is_true(vim.wait(500, function()
      return done
    end, 5))
  end)
end)

describe("catalog metadata", function()
  it("reads the deprecation and its alternative", function()
    local meta = require("nuget.registry").from_catalog({
      id = "Microsoft.Azure.Storage.Blob",
      version = "11.2.3",
      deprecation = {
        reasons = { "Legacy" },
        alternatePackage = { id = "Azure.Storage.Blobs", range = "*" },
        message = "Please note, this package is obsolete",
      },
    })
    assert.same({ "Legacy" }, meta.deprecation.reasons)
    assert.equals("Azure.Storage.Blobs", meta.deprecation.alternative)
  end)
end)
