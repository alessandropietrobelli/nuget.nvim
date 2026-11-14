-- Quick answers from nuget.org while `dotnet list package` takes its time.
--
-- On a large solution `--outdated` and `--deprecated` take minutes: they ask every feed about
-- every package of every project. nuget.org answers the same questions in seconds: the flat
-- container lists a package's versions, the vulnerability index is what NuGet audit itself uses,
-- and a version's catalog entry says whether it is deprecated. The dotnet reports still run and
-- override these answers when they arrive; they are the only source for private feeds.
local semver = require("nuget.semver")

local M = {}

M.flat_container = "https://api.nuget.org/v3-flatcontainer/"
M.vulnerability_index = "https://api.nuget.org/v3/vulnerabilities/index.json"

local SEVERITY = { [0] = "Low", [1] = "Moderate", [2] = "High", [3] = "Critical" }

--- GET a JSON document. On failure `err` says why: "missing" when the server answered 404 (the
--- package or version is not there), "failed" for anything else (no network, a timeout, a server
--- error, a body that is not JSON), which is worth asking again later.
---@param url string
---@param cb fun(data: table?, err: "missing"|"failed"|nil)
local function get_json(url, cb)
  local cmd = { "curl", "-sL", "--compressed", "--max-time", "20", "-w", "\n%{http_code}", url }
  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      local body, status = (result.stdout or ""):match("^(.*)\n(%d%d%d)$")
      if result.code ~= 0 or not status then
        return cb(nil, "failed")
      elseif status == "404" then
        return cb(nil, "missing")
      elseif not status:match("^2") then
        return cb(nil, "failed")
      end
      local ok, data = pcall(vim.json.decode, body, { luanil = { object = true, array = true } })
      if ok and type(data) == "table" then
        cb(data)
      else
        cb(nil, "failed")
      end
    end)
  end)
end
M.get_json = get_json

--- Why nuget.org cannot answer the quick checks, or nil when it can: they must be on, curl must
--- be there, and nuget.org must be one of the sources.
---@param config NugetConfig
---@return string?
function M.why_disabled(config)
  if not config.fast then
    return "`fast` is off"
  elseif vim.fn.executable("curl") ~= 1 then
    return "curl is not installed"
  elseif
    config.sources
    and not vim.iter(config.sources):any(function(s)
      return s:lower():find("nuget.org", 1, true) ~= nil
    end)
  then
    return "nuget.org is not among `sources`"
  end
  return nil
end

--- Whether nuget.org can answer the quick checks (see why_disabled).
---@param config NugetConfig
---@return boolean
function M.enabled(config)
  return M.why_disabled(config) == nil
end

--- Run `fn(item, done)` over items with at most `limit` in flight; `on_done` after the last.
---@param items any[]
---@param limit integer
---@param fn fun(item: any, done: fun())
---@param on_done fun()
---@return {cancel: fun()}
function M.each_limited(items, limit, fn, on_done)
  local next_index, running, finished, cancelled = 1, 0, 0, false
  local function pump()
    while not cancelled and running < limit and next_index <= #items do
      local item = items[next_index]
      next_index = next_index + 1
      running = running + 1
      fn(item, function()
        running = running - 1
        finished = finished + 1
        if cancelled then
          return
        end
        if finished == #items then
          on_done()
        else
          pump()
        end
      end)
    end
  end
  if #items == 0 then
    vim.schedule(on_done)
  else
    pump()
  end
  return {
    cancel = function()
      cancelled = true
    end,
  }
end

--- Latest version of each package on nuget.org, with every version it lists. Packages it does
--- not know are skipped; those it could not be asked about go to `opts.on_failed`.
---@param ids string[]
---@param opts {prerelease: boolean, concurrency: integer, on_failed: fun(id: string)?}
---@param on_result fun(id: string, latest: string, versions: string[])
---@param on_done fun()
---@return {cancel: fun()}
function M.latest(ids, opts, on_result, on_done)
  return M.each_limited(ids, opts.concurrency, function(id, done)
    get_json(M.flat_container .. id:lower() .. "/index.json", function(data, err)
      local latest = data and data.versions and semver.max(data.versions, opts.prerelease)
      if latest then
        on_result(id, latest, data.versions)
      elseif err == "failed" and opts.on_failed then
        opts.on_failed(id)
      end
      done()
    end)
  end, on_done)
end

---@alias NugetAdvisoryDb table<string, {url: string, severity: string, versions: string}[]>

---@type NugetAdvisoryDb?
local db_cache
---@type fun(db: NugetAdvisoryDb?)[]? callers waiting for the download under way
local db_waiting

--- The nuget.org vulnerability database: the base file plus the latest update, merged. It is
--- downloaded once for every caller asking meanwhile, and kept only when complete: nil after a
--- failure, so the next call tries again.
---@param cb fun(db: NugetAdvisoryDb?)
function M.advisories(cb)
  if db_cache then
    return cb(db_cache)
  end
  if db_waiting then
    table.insert(db_waiting, cb)
    return
  end
  db_waiting = { cb }
  local function finish(db)
    db_cache = db
    local cbs = db_waiting or {}
    db_waiting = nil
    for _, fn in ipairs(cbs) do
      fn(db)
    end
  end
  get_json(M.vulnerability_index, function(index)
    if not index then
      return finish(nil)
    end
    local files = {}
    for _, entry in ipairs(index) do
      if entry["@id"] then
        table.insert(files, entry["@id"])
      end
    end
    local db, pending = {}, #files
    if pending == 0 then
      return finish(nil)
    end
    local failed = false
    for _, url in ipairs(files) do
      get_json(url, function(data)
        if not data then
          failed = true
        end
        for id, advisories in pairs(data or {}) do
          local list = db[id:lower()] or {}
          for _, a in ipairs(advisories) do
            local known = vim.iter(list):any(function(x)
              return x.url == a.url
            end)
            if not known then
              table.insert(list, { url = a.url, severity = SEVERITY[a.severity] or "Unknown", versions = a.versions })
            end
          end
          db[id:lower()] = list
        end
        pending = pending - 1
        if pending == 0 then
          finish(not failed and db or nil)
        end
      end)
    end
  end)
end

--- Advisories that apply to one version of a package.
---@param db NugetAdvisoryDb
---@param id string
---@param version string
---@return {severity: string, url: string}[]
function M.vulnerabilities_of(db, id, version)
  local out = {}
  for _, a in ipairs(db[id:lower()] or {}) do
    if semver.in_range(version, a.versions) then
      table.insert(out, { severity = a.severity, url = a.url })
    end
  end
  return out
end

function M.clear_cache()
  db_cache = nil
end

return M
