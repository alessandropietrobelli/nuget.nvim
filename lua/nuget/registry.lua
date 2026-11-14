-- Package metadata from nuget.org (description, license, dependencies…), which the dotnet CLI
-- does not expose. Two requests per version: the registration leaf, then its catalog entry.
-- Packages from other feeds simply have no metadata here.
local fast = require("nuget.fast")

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
---@field listed boolean false when the author unlisted the version
---@field dependencies {framework: string, packages: string[]}[]
---@field deprecation {reasons: string[], alternative: string?, message: string?}?

---@type table<string, NugetMetadata|false>
local cache = {}
---@type table<string, fun(meta: NugetMetadata?)[]>
local waiting = {}

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
    listed = entry.listed ~= false,
    dependencies = deps,
    deprecation = type(entry.deprecation) == "table" and {
      reasons = entry.deprecation.reasons or {},
      alternative = type(entry.deprecation.alternatePackage) == "table" and entry.deprecation.alternatePackage.id
        or nil,
      message = entry.deprecation.message,
    } or nil,
  }
end

--- Metadata of one version; nil when the package is not on nuget.org or the request fails, and
--- then `failed` tells the two apart. A failure is not remembered, so the next call asks again.
---@param id string
---@param version string
---@param cb fun(meta: NugetMetadata?, failed: boolean?)
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
  local function done(meta, failed)
    if not failed then
      cache[key] = meta or false
    end
    local cbs = waiting[key] or {}
    waiting[key] = nil
    for _, fn in ipairs(cbs) do
      fn(meta, failed)
    end
  end
  fast.get_json(M.base .. id:lower() .. "/" .. version:lower() .. ".json", function(leaf, err)
    if not leaf or not leaf.catalogEntry then
      return done(nil, err ~= "missing")
    end
    -- The registration leaf says whether the version is listed now; its catalog entry may be older
    local function from(entry)
      local meta = M.from_catalog(entry)
      if type(leaf.listed) == "boolean" then
        meta.listed = leaf.listed
      end
      return meta
    end
    if type(leaf.catalogEntry) == "table" then
      return done(from(leaf.catalogEntry))
    end
    fast.get_json(leaf.catalogEntry, function(entry)
      done(entry and from(entry) or nil, entry == nil)
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
