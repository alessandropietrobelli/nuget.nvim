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
  it("says the license is a file instead of showing nuget.org's placeholder URL", function()
    local registry = require("nuget.registry")
    local meta = registry.from_catalog({
      id = "Bogus",
      version = "35.6.5",
      licenseFile = "LICENSE",
      licenseUrl = "https://aka.ms/deprecateLicenseUrl",
    })
    assert.equals("file in the package (LICENSE)", meta.license)
    assert.is_nil(
      registry.from_catalog({ id = "X", version = "1", licenseUrl = "https://aka.ms/deprecateLicenseUrl" }).license
    )
    assert.equals("MIT", registry.from_catalog({ id = "X", version = "1", licenseExpression = "MIT" }).license)
  end)

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

describe("nuget.org requests", function()
  local system, calls

  --- Answer curl with `responses[url]`: {code = exit code, status = HTTP status, body = text}.
  local function serve(responses)
    calls = {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.system = function(cmd, _, on_exit)
      local url = cmd[#cmd]
      table.insert(calls, url)
      local r = responses[url] or { code = 6 }
      vim.defer_fn(function()
        on_exit({ code = r.code or 0, stdout = r.status and ((r.body or "") .. "\n" .. r.status) or "" })
      end, 20)
      return {}
    end
  end

  before_each(function()
    system = vim.system
    fast.clear_cache()
  end)

  after_each(function()
    vim.system = system
    fast.clear_cache()
  end)

  local function get(url)
    local out
    fast.get_json(url, function(data, err)
      out = { data = data, err = err }
    end)
    assert.is_true(vim.wait(1000, function()
      return out ~= nil
    end, 10))
    return out
  end

  it("tells a package nuget.org does not have from a request that failed", function()
    serve({
      ok = { status = "200", body = '{"versions":["1.0.0"]}' },
      missing = { status = "404", body = "<Error/>" },
      busy = { status = "429", body = "slow down" },
      broken = { status = "200", body = "<html>" },
    })
    assert.same({ "1.0.0" }, get("ok").data.versions)
    assert.equals("missing", get("missing").err)
    assert.equals("failed", get("busy").err)
    assert.equals("failed", get("broken").err)
    assert.equals("failed", get("offline").err, "curl could not connect")
  end)

  it("reports the packages it could not ask about apart from those nuget.org does not have", function()
    local base = fast.flat_container
    serve({
      [base .. "serilog/index.json"] = { status = "200", body = '{"versions":["4.4.0"]}' },
      [base .. "nope/index.json"] = { status = "404" },
    })
    local found, failed, done = {}, {}, false
    fast.latest({ "Serilog", "Nope", "Timeout" }, {
      prerelease = false,
      concurrency = 2,
      on_failed = function(id)
        table.insert(failed, id)
      end,
    }, function(id)
      table.insert(found, id)
    end, function()
      done = true
    end)
    assert.is_true(vim.wait(1000, function()
      return done
    end, 10))
    assert.same({ "Serilog" }, found)
    assert.same({ "Timeout" }, failed)
  end)

  it("downloads the vulnerability database once for callers asking together, and again after a failure", function()
    local index = fast.vulnerability_index
    serve({ [index] = { status = "503" } })
    local answers = {}
    for _ = 1, 3 do
      fast.advisories(function(db)
        table.insert(answers, db or false)
      end)
    end
    assert.is_true(vim.wait(1000, function()
      return #answers == 3
    end, 10))
    assert.same({ false, false, false }, answers)
    assert.equals(1, #calls)
    serve({
      [index] = { status = "200", body = '[{"@id":"base"}]' },
      base = { status = "200", body = '{"Newtonsoft.Json":[{"url":"u","severity":2,"versions":"(, 13.0.1)"}]}' },
    })
    local db
    fast.advisories(function(d)
      db = d
    end)
    assert.is_true(vim.wait(1000, function()
      return db ~= nil
    end, 10))
    assert.equals("High", db["newtonsoft.json"][1].severity)
  end)

  it("asks again for metadata whose request failed, not for a version nuget.org does not have", function()
    local registry = require("nuget.registry")
    registry.clear_cache()
    local leaf = registry.base .. "serilog/4.4.0.json"
    local function fetch(id, version)
      local out
      registry.fetch(id, version, function(meta, failed)
        out = { meta = meta, failed = failed }
      end)
      assert.is_true(vim.wait(1000, function()
        return out ~= nil
      end, 10))
      return out
    end
    serve({ [registry.base .. "nope/1.0.0.json"] = { status = "404" } })
    local r = fetch("Serilog", "4.4.0")
    assert.is_true(r.failed)
    assert.is_falsy(fetch("Nope", "1.0.0").failed)
    serve({
      [leaf] = {
        status = "200",
        body = '{"catalogEntry":{"id":"Serilog","version":"4.4.0","deprecation":{"reasons":["Legacy"]}}}',
      },
    })
    assert.same({ "Legacy" }, fetch("Serilog", "4.4.0").meta.deprecation.reasons)
    calls = {}
    fetch("Nope", "1.0.0")
    assert.same({}, calls, "the missing version is remembered")
    registry.clear_cache()
  end)
end)
