-- Turns "set this package to this version in these projects" into concrete steps, one per
-- place the version is written. Pure: decides, does not run anything.
--
--   project / override / unknown  `dotnet add` in each project (it updates Version or VersionOverride)
--   central                       one `dotnet add`, which rewrites Directory.Packages.props
--   imported                      edit the PackageReference in Directory.Build.props (dotnet refuses)
--   imported_central              edit the PackageVersion in Directory.Packages.props
--   global                        edit the GlobalPackageReference in Directory.Packages.props
local solution = require("nuget.solution")

local M = {}

---@class NugetStep
---@field kind "add"|"remove"|"edit"|"delete"
---@field id string
---@field version string?
---@field project string? for add / remove
---@field file string? for edit / delete
---@field tag string? item to edit or delete
---@field attr string? "version" | "versionoverride"
---@field label string
---@field shared_with string[]? projects a shared edit also changes

---@param path string
local function short(path)
  return vim.fn.fnamemodify(path, ":t")
end

--- Projects whose version comes from the same shared file as `origin`.
---@param pkg NugetPackage
---@param origin NugetOrigin
---@return string[]
local function sharing(pkg, origin)
  local out = {}
  for path, ref in pairs(pkg.projects) do
    if ref.origin and ref.origin.kind == origin.kind and ref.origin.file == origin.file then
      table.insert(out, path)
    end
  end
  table.sort(out)
  return out
end

--- Steps that bring `pkg` to `version` in `projects`.
---@param pkg NugetPackage
---@param version string
---@param projects string[]
---@return NugetStep[]
function M.set_version(pkg, version, projects)
  local steps, seen = {}, {}
  for _, path in ipairs(projects) do
    local ref = pkg.projects[path]
    local origin = ref and ref.origin or { kind = "unknown" }
    local kind = origin.kind
    if kind == "project" or kind == "override" or kind == "unknown" then
      table.insert(steps, {
        kind = "add",
        id = pkg.id,
        version = version,
        project = path,
        label = ("Updating %s to %s in %s%s"):format(
          pkg.id,
          version,
          solution.project_name(path),
          kind == "override" and " (VersionOverride)" or ""
        ),
      })
    else
      local key = kind .. "\0" .. (origin.file or "")
      if not seen[key] then
        seen[key] = true
        local step = {
          id = pkg.id,
          version = version,
          shared_with = sharing(pkg, origin),
          label = ("Updating %s to %s in %s"):format(pkg.id, version, short(origin.file or "?")),
        }
        if kind == "central" then
          -- dotnet add on any project using the central version rewrites it for all of them
          step.kind, step.project = "add", path
        else
          step.kind, step.file, step.attr = "edit", origin.file, "version"
          step.tag = kind == "imported" and "PackageReference"
            or kind == "imported_central" and "PackageVersion"
            or "GlobalPackageReference"
        end
        table.insert(steps, step)
      end
    end
  end
  return steps
end

--- Steps that remove `pkg` from `projects`. Items in shared files can only go for everyone.
---@param pkg NugetPackage
---@param projects string[]
---@return NugetStep[]
function M.remove(pkg, projects)
  local steps, seen = {}, {}
  for _, path in ipairs(projects) do
    local ref = pkg.projects[path]
    local origin = ref and ref.origin or { kind = "unknown" }
    local kind = origin.kind
    if kind == "imported" or kind == "imported_central" or kind == "global" then
      local key = origin.ref_file or ""
      if not seen[key] then
        seen[key] = true
        table.insert(steps, {
          kind = "delete",
          id = pkg.id,
          file = origin.ref_file,
          tag = kind == "global" and "GlobalPackageReference" or "PackageReference",
          shared_with = sharing(pkg, origin),
          label = ("Removing %s from %s"):format(pkg.id, short(origin.ref_file or "?")),
        })
      end
    else
      table.insert(steps, {
        kind = "remove",
        id = pkg.id,
        project = path,
        label = ("Removing %s from %s"):format(pkg.id, solution.project_name(path)),
      })
    end
  end
  return steps
end

--- Whether any step edits a shared file directly, which needs a restore afterwards.
---@param steps NugetStep[]
---@return boolean
function M.needs_restore(steps)
  return vim.iter(steps):any(function(s)
    return s.kind == "edit" or s.kind == "delete"
  end)
end

--- Projects a step changes besides the ones that were picked, for a confirmation.
---@param steps NugetStep[]
---@param picked string[]
---@return string[]
function M.also_affected(steps, picked)
  local set = {}
  for _, p in ipairs(picked) do
    set[p] = true
  end
  local out = {}
  for _, step in ipairs(steps) do
    for _, p in ipairs(step.shared_with or {}) do
      if not set[p] then
        set[p] = true
        table.insert(out, p)
      end
    end
  end
  table.sort(out)
  return out
end

return M
