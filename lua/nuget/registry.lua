-- Package metadata from nuget.org (description, license, dependencies…), which the dotnet CLI
-- does not expose. Two requests per version: the registration leaf, then its catalog entry.
-- Packages from other feeds simply have no metadata here.
local M = {}

M.base = "https://api.nuget.org/v3/registration5-gz-semver2/"

---@class NugetMetadata
---@field id string
---@field version string
---@field title string?
---@field description string?
---@field authors string?
---@field license string?
---@field project_url string?
---@field tags string[]
---@field published string? date, YYYY-MM-DD
---@field dependencies {framework: string, packages: string[]}[]
---@field deprecation {reasons: string[], alternative: string?, message: string?}?

---@type table<string, NugetMetadata|false>
local cache = {}
---@type table<string, fun(meta: NugetMetadata?)[]>
local waiting = {}

---@param url string
---@param cb fun(data: table?)
local function get(url, cb)
  vim.system({ "curl", "-sfL", "--compressed", "--max-time", "15", url }, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        return cb(nil)
      end
      local ok, data = pcall(vim.json.decode, result.stdout or "", { luanil = { object = true, array = true } })
      cb(ok and type(data) == "table" and data or nil)
    end)
  end)
end

---@param entry table catalog entry
---@return NugetMetadata
function M.from_catalog(entry)
  local tags = entry.tags
  if type(tags) == "string" then
    tags = vim.split(tags, "[%s,]+", { trimempty = true })
  end
  local deps = {}
  for _, group in ipairs(entry.dependencyGroups or {}) do
    local packages = {}
    for _, d in ipairs(group.dependencies or {}) do
      table.insert(packages, d.range and (d.id .. " " .. d.range) or d.id)
    end
    table.insert(deps, { framework = group.targetFramework or "any", packages = packages })
  end
  local license = entry.licenseExpression
  if not license or license == "" then
    -- Packages that ship their license as a file get this placeholder URL from nuget.org
    if entry.licenseFile and entry.licenseFile ~= "" then
      license = "file in the package (" .. entry.licenseFile .. ")"
    elseif
      entry.licenseUrl
      and entry.licenseUrl ~= ""
      and not entry.licenseUrl:find("aka.ms/deprecateLicenseUrl", 1, true)
    then
      license = entry.licenseUrl
    end
  end
  return {
    id = entry.id,
    version = entry.version,
    title = entry.title ~= "" and entry.title or nil,
    description = entry.description,
    authors = entry.authors,
    license = license,
    project_url = entry.projectUrl ~= "" and entry.projectUrl or nil,
    tags = tags or {},
    published = type(entry.published) == "string" and entry.published:sub(1, 10) or nil,
    dependencies = deps,
    deprecation = type(entry.deprecation) == "table" and {
      reasons = entry.deprecation.reasons or {},
      alternative = type(entry.deprecation.alternatePackage) == "table" and entry.deprecation.alternatePackage.id
        or nil,
      message = entry.deprecation.message,
    } or nil,
  }
end

--- Metadata of one version; nil when the package is not on nuget.org or the request fails.
---@param id string
---@param version string
---@param cb fun(meta: NugetMetadata?)
function M.fetch(id, version, cb)
  local key = (id .. "@" .. version):lower()
  if cache[key] ~= nil then
    return cb(cache[key] or nil)
  end
  if waiting[key] then
    table.insert(waiting[key], cb)
    return
  end
  waiting[key] = { cb }
  local function done(meta)
    cache[key] = meta or false
    local cbs = waiting[key]
    waiting[key] = nil
    for _, fn in ipairs(cbs) do
      fn(meta)
    end
  end
  get(M.base .. id:lower() .. "/" .. version:lower() .. ".json", function(leaf)
    if not leaf or not leaf.catalogEntry then
      return done(nil)
    end
    if type(leaf.catalogEntry) == "table" then
      return done(M.from_catalog(leaf.catalogEntry))
    end
    get(leaf.catalogEntry, function(entry)
      done(entry and M.from_catalog(entry) or nil)
    end)
  end)
end

---@param id string
---@param version string?
---@return string
function M.gallery_url(id, version)
  return "https://www.nuget.org/packages/" .. id .. (version and ("/" .. version) or "")
end

function M.clear_cache()
  cache = {}
end

return M
