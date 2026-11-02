-- Finds what to manage: a solution, or the projects of a folder without one.
local M = {}

---@class NugetTarget
---@field kind "solution"|"projects"
---@field path string solution file, or the folder holding the projects
---@field name string
---@field projects string[]? project files, for kind = "projects"

---@param dir string
---@return string[]
local function glob(dir, pattern)
  return vim.fn.globpath(dir, pattern, false, true)
end

--- Solutions in `dir`, or in the closest parent that has one.
---@param dir string
---@return string[]
function M.find_solutions(dir)
  local current = vim.fs.normalize(dir)
  while current do
    local found = vim.list_extend(glob(current, "*.sln"), glob(current, "*.slnx"))
    if #found > 0 then
      table.sort(found)
      return found
    end
    local parent = vim.fs.dirname(current)
    if not parent or parent == current then
      break
    end
    current = parent
  end
  return {}
end

--- Project files under `dir`, skipping build output.
---@param dir string
---@return string[]
function M.find_projects(dir)
  local found = {}
  for _, ext in ipairs({ "csproj", "fsproj", "vbproj" }) do
    for _, path in
      ipairs(vim.fs.find(function(name)
        return name:match("%." .. ext .. "$") ~= nil
      end, { path = dir, type = "file", limit = math.huge }))
    do
      if not path:match("/bin/") and not path:match("/obj/") then
        table.insert(found, path)
      end
    end
  end
  table.sort(found)
  return found
end

--- Resolve the target to manage. `explicit` is a solution or project path from the config;
--- otherwise the solution next to `dir` (asking when there are several), or its projects.
---@param dir string
---@param explicit string?
---@param cb fun(target: NugetTarget?)
function M.resolve(dir, explicit, cb)
  if explicit and explicit ~= "" then
    local path = vim.fs.normalize(vim.fn.fnamemodify(explicit, ":p"))
    if path:match("%.slnx?$") then
      return cb({ kind = "solution", path = path, name = vim.fn.fnamemodify(path, ":t") })
    end
    return cb({
      kind = "projects",
      path = vim.fs.dirname(path),
      name = vim.fn.fnamemodify(path, ":t"),
      projects = { path },
    })
  end

  local solutions = M.find_solutions(dir)
  if #solutions == 1 then
    return cb({ kind = "solution", path = solutions[1], name = vim.fn.fnamemodify(solutions[1], ":t") })
  elseif #solutions > 1 then
    vim.ui.select(solutions, {
      prompt = "NuGet: solution",
      format_item = function(item)
        return vim.fn.fnamemodify(item, ":~:.")
      end,
    }, function(choice)
      cb(choice and { kind = "solution", path = choice, name = vim.fn.fnamemodify(choice, ":t") } or nil)
    end)
    return
  end

  local projects = M.find_projects(dir)
  if #projects == 0 then
    return cb(nil)
  end
  cb({ kind = "projects", path = dir, name = vim.fn.fnamemodify(dir, ":t"), projects = projects })
end

--- Short display name of a project file.
---@param path string
---@return string
function M.project_name(path)
  return (vim.fn.fnamemodify(path, ":t"):gsub("%.%w+proj$", ""))
end

---@type table<string, string|false>
local cpm_cache = {}

--- The Directory.Packages.props that manages a project's versions centrally, if any.
--- MSBuild picks the closest one above the project; it is central only when it turns
--- ManagePackageVersionsCentrally on.
---@param project string
---@return string?
function M.central_props(project)
  local dir = vim.fs.dirname(project)
  if cpm_cache[dir] ~= nil then
    return cpm_cache[dir] or nil
  end
  local props = vim.fs.find("Directory.Packages.props", { path = dir, upward = true, type = "file" })[1]
  local central = false
  if props then
    local ok, lines = pcall(vim.fn.readfile, props)
    if ok then
      local text = table.concat(lines, "\n")
      central = text:match("<ManagePackageVersionsCentrally>%s*[Tt]rue%s*</ManagePackageVersionsCentrally>") and props
        or false
    end
  end
  -- A project can opt out
  if central then
    local ok, lines = pcall(vim.fn.readfile, project)
    if ok and table.concat(lines, "\n"):match("<ManagePackageVersionsCentrally>%s*[Ff]alse") then
      central = false
    end
  end
  cpm_cache[dir] = central
  return central or nil
end

---@type table<string, string|false>
local text_cache = {}

---@param path string
---@return string?
local function read(path)
  if text_cache[path] == nil then
    text_cache[path] = require("nuget.xml").read(path) or false
  end
  return text_cache[path] or nil
end

--- Directory.Build.props above a project, nearest first, following the chain of files that
--- import the next one up (`GetPathOfFileAbove('Directory.Build.props', …)`), then the
--- nearest Directory.Build.targets.
---@param project string
---@return string[]
function M.build_files(project)
  local files = {}
  local dir = vim.fs.dirname(project)
  while dir do
    local props = vim.fs.find("Directory.Build.props", { path = dir, upward = true, type = "file" })[1]
    if not props then
      break
    end
    table.insert(files, props)
    local text = read(props) or ""
    if not text:find("GetPathOfFileAbove%(['\"]?Directory%.Build%.props") then
      break
    end
    local parent = vim.fs.dirname(vim.fs.dirname(props))
    if not parent or parent == vim.fs.dirname(props) then
      break
    end
    dir = parent
  end
  local targets =
    vim.fs.find("Directory.Build.targets", { path = vim.fs.dirname(project), upward = true, type = "file" })[1]
  if targets then
    table.insert(files, targets)
  end
  return files
end

---@alias NugetOriginKind
---| "project"          Version on the PackageReference in the project
---| "override"         VersionOverride in the project, over a central version
---| "central"          PackageVersion in Directory.Packages.props
---| "imported"         PackageReference with a Version in Directory.Build.props/targets
---| "imported_central" PackageReference in Directory.Build.props, version in Directory.Packages.props
---| "global"           GlobalPackageReference in Directory.Packages.props
---| "unknown"          none of the above (a property, a condition, an import we do not follow)

---@class NugetOrigin
---@field kind NugetOriginKind
---@field file string? the file holding the version
---@field ref_file string? the file holding the PackageReference (or GlobalPackageReference) item

--- Where the version of a package reference of a project is written. This decides how to
--- change it: `dotnet add` handles the project and central cases, but refuses items in
--- imported files.
---@param project string
---@param id string
---@return NugetOrigin
function M.version_origin(project, id)
  local xml = require("nuget.xml")
  local central = M.central_props(project)

  local text = read(project)
  if text then
    for _, item in ipairs(xml.find(text, "PackageReference", id)) do
      if xml.version_of(item, "versionoverride") then
        return { kind = "override", file = project, ref_file = project }
      elseif xml.version_of(item, "version") then
        return { kind = "project", file = project, ref_file = project }
      elseif central then
        return { kind = "central", file = central, ref_file = project }
      end
    end
  end

  for _, file in ipairs(M.build_files(project)) do
    local build = read(file)
    for _, item in ipairs(build and xml.find(build, "PackageReference", id) or {}) do
      if xml.version_of(item, "version") then
        return { kind = "imported", file = file, ref_file = file }
      elseif central then
        return { kind = "imported_central", file = central, ref_file = file }
      end
    end
  end

  if central then
    local props = read(central)
    if props and #xml.find(props, "GlobalPackageReference", id) > 0 then
      return { kind = "global", file = central, ref_file = central }
    end
    return { kind = "central", file = central }
  end
  return { kind = "unknown" }
end

--- Whether changing a version of this origin changes it for other projects too.
---@param origin NugetOrigin
---@return boolean
function M.is_shared(origin)
  return origin.kind == "central"
    or origin.kind == "imported"
    or origin.kind == "imported_central"
    or origin.kind == "global"
end

function M.clear_cache()
  cpm_cache = {}
  text_cache = {}
end

return M
