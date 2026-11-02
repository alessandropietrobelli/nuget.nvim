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

---@param url string
---@param cb fun(data: table?)
local function get_json(url, cb)
  vim.system({ "curl", "-sfL", "--compressed", "--max-time", "20", url }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        return cb(nil)
      end
      local ok, data = pcall(vim.json.decode, result.stdout or "", { luanil = { object = true, array = true } })
      cb(ok and type(data) == "table" and data or nil)
    end)
  end)
end
M.get_json = get_json

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

--- Latest version of each package on nuget.org; packages it does not know are skipped.
---@param ids string[]
---@param opts {prerelease: boolean, concurrency: integer}
---@param on_result fun(id: string, latest: string)
---@param on_done fun()
---@return {cancel: fun()}
function M.latest(ids, opts, on_result, on_done)
  return M.each_limited(ids, opts.concurrency, function(id, done)
    get_json(M.flat_container .. id:lower() .. "/index.json", function(data)
      local latest = data and data.versions and semver.max(data.versions, opts.prerelease)
      if latest then
        on_result(id, latest)
      end
      done()
    end)
  end, on_done)
end

---@alias NugetAdvisoryDb table<string, {url: string, severity: string, versions: string}[]>

---@type NugetAdvisoryDb?
local db_cache

--- The nuget.org vulnerability database: the base file plus the latest update, merged.
---@param cb fun(db: NugetAdvisoryDb?)
function M.advisories(cb)
  if db_cache then
    return cb(db_cache)
  end
  get_json(M.vulnerability_index, function(index)
    if not index then
      return cb(nil)
    end
    local files = {}
    for _, entry in ipairs(index) do
      if entry["@id"] then
        table.insert(files, entry["@id"])
      end
    end
    local db, pending = {}, #files
    if pending == 0 then
      return cb(nil)
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
          db_cache = not failed and db or nil
          cb(db_cache)
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
