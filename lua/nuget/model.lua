-- Merges the `dotnet list package` reports into one view per package.
local semver = require("nuget.semver")
local solution = require("nuget.solution")

local M = {}

---@class NugetVulnerability
---@field severity string Low|Moderate|High|Critical
---@field url string

---@class NugetProjectRef
---@field requested string? as written in the project or Directory.Packages.props
---@field resolved string?
---@field frameworks string[]
---@field origin NugetOrigin? where the version is written

---@class NugetPackage
---@field id string
---@field projects table<string, NugetProjectRef> direct references, by project path
---@field transitive table<string, string> transitive only: project path -> resolved version
---@field latest string? from the outdated report
---@field vulnerabilities NugetVulnerability[]
---@field vulnerable_in table<string, true> projects whose resolved version is vulnerable
---@field deprecation {reasons: string[], alternative: string?}?
---@field central string? the shared file (Directory.Packages.props / Directory.Build.props) holding its version

---@class NugetModel
---@field packages table<string, NugetPackage> by lower-case id
---@field projects string[] every project of the target, sorted by name
---@field loaded table<NugetListKind, boolean>

local SEVERITY_RANK = { low = 1, moderate = 2, high = 3, critical = 4 }

---@return NugetModel
function M.new()
  return { packages = {}, projects = {}, loaded = {} }
end

---@param model NugetModel
---@param id string
---@return NugetPackage
local function package(model, id)
  local key = id:lower()
  local pkg = model.packages[key]
  if not pkg then
    pkg = { id = id, projects = {}, transitive = {}, vulnerabilities = {}, vulnerable_in = {} }
    model.packages[key] = pkg
  end
  return pkg
end

--- Iterate (project path, framework, package entry, is_transitive) over a report.
local function each_entry(report, fn)
  for _, project in ipairs(report.projects or {}) do
    for _, fw in ipairs(project.frameworks or {}) do
      for _, entry in ipairs(fw.topLevelPackages or {}) do
        fn(project.path, fw.framework, entry, false)
      end
      for _, entry in ipairs(fw.transitivePackages or {}) do
        fn(project.path, fw.framework, entry, true)
      end
    end
  end
end

--- Fold one report into the model.
---@param model NugetModel
---@param kind NugetListKind
---@param report {projects: table[]}
function M.apply(model, kind, report)
  model.loaded[kind] = true

  -- Reports arrive in any order; a refresh starts from a new model instead of resetting here
  if kind == "plain" or kind == "transitive" then
    local seen = {}
    model.projects = {}
    for _, project in ipairs(report.projects or {}) do
      if project.path and not seen[project.path] then
        seen[project.path] = true
        table.insert(model.projects, project.path)
      end
    end
    table.sort(model.projects, function(a, b)
      return solution.project_name(a):lower() < solution.project_name(b):lower()
    end)
  end

  -- A complete outdated report is authoritative: it drops the quick nuget.org guesses, including
  -- those for packages it does not list (they are up to date as far as the feeds are concerned).
  -- A report with problems (a feed that could not be reached) may be missing packages, so the
  -- guesses stay and the report only adds to them.
  if kind == "outdated" and #(report.problems or {}) == 0 then
    for _, pkg in pairs(model.packages) do
      if pkg.latest_hint then
        pkg.latest, pkg.latest_hint = nil, nil
      end
    end
  end

  each_entry(report, function(path, framework, entry, transitive)
    if not entry.id then
      return
    end
    local pkg = package(model, entry.id)
    if transitive then
      if not pkg.projects[path] then
        pkg.transitive[path] = entry.resolvedVersion
      end
    elseif kind == "plain" or kind == "transitive" then
      local ref = pkg.projects[path] or { frameworks = {} }
      ref.requested = entry.requestedVersion or ref.requested
      ref.resolved = entry.resolvedVersion or ref.resolved
      if not vim.tbl_contains(ref.frameworks, framework) then
        table.insert(ref.frameworks, framework)
      end
      pkg.projects[path] = ref
      pkg.transitive[path] = nil
    end

    if kind == "outdated" and entry.latestVersion and not transitive then
      if pkg.latest_hint then
        pkg.latest, pkg.latest_hint = nil, nil
      end
      if not pkg.latest or semver.compare(entry.latestVersion, pkg.latest) > 0 then
        pkg.latest = entry.latestVersion
      end
    elseif kind == "vulnerable" and entry.vulnerabilities then
      pkg.vulnerable_in[path] = true
      for _, v in ipairs(entry.vulnerabilities) do
        local known = vim.iter(pkg.vulnerabilities):any(function(x)
          return x.url == v.advisoryurl
        end)
        if not known then
          table.insert(pkg.vulnerabilities, { severity = v.severity or "Unknown", url = v.advisoryurl })
        end
      end
    elseif kind == "deprecated" and entry.deprecationReasons then
      pkg.deprecation = {
        reasons = entry.deprecationReasons,
        alternative = entry.alternativePackage and entry.alternativePackage.id,
      }
    end
  end)

  if kind == "plain" or kind == "transitive" then
    for _, pkg in pairs(model.packages) do
      -- Where each project's version is written decides how to change it
      local shared
      for path, ref in pairs(pkg.projects) do
        ref.origin = solution.version_origin(path, pkg.id)
        if ref.origin.kind ~= "project" and ref.origin.kind ~= "override" and ref.origin.kind ~= "unknown" then
          shared = shared or ref.origin.file
        end
      end
      -- The file to point at when the version is not in the projects themselves
      pkg.central = shared
    end
  end
end

--- A latest version learned from nuget.org before the outdated report; the report replaces it.
---@param model NugetModel
---@param id string
---@param latest string
function M.hint_latest(model, id, latest)
  local pkg = model.packages[id:lower()]
  if not pkg or model.loaded.outdated then
    return
  end
  pkg.latest, pkg.latest_hint = latest, true
end

--- Advisories found for the version a project resolves. Merged with what the vulnerable report
--- says, so it does not matter which arrives first.
---@param model NugetModel
---@param id string
---@param project string
---@param advisories {severity: string, url: string}[]
function M.add_vulnerabilities(model, id, project, advisories)
  if #advisories == 0 then
    return
  end
  local pkg = model.packages[id:lower()]
  if not pkg then
    return
  end
  pkg.vulnerable_in[project] = true
  for _, a in ipairs(advisories) do
    local known = vim.iter(pkg.vulnerabilities):any(function(x)
      return x.url == a.url
    end)
    if not known then
      table.insert(pkg.vulnerabilities, { severity = a.severity, url = a.url })
    end
  end
end

---@param model NugetModel
---@param id string
---@param deprecation {reasons: string[], alternative: string?}
function M.set_deprecation(model, id, deprecation)
  local pkg = model.packages[id:lower()]
  if pkg and not pkg.deprecation then
    pkg.deprecation = { reasons = deprecation.reasons, alternative = deprecation.alternative }
  end
end

--- Every (project, version) a package resolves to, direct and transitive.
---@param pkg NugetPackage
---@return {project: string, version: string}[]
function M.resolutions(pkg)
  local out = {}
  for path, ref in pairs(pkg.projects) do
    local v = ref.resolved or semver.effective(ref.requested, ref.resolved)
    if v then
      table.insert(out, { project = path, version = v })
    end
  end
  for path, v in pairs(pkg.transitive) do
    if v then
      table.insert(out, { project = path, version = v })
    end
  end
  return out
end

--- Versions a package is referenced at, one per distinct version, highest first.
---@param pkg NugetPackage
---@return string[]
function M.versions(pkg)
  local seen, list = {}, {}
  for _, ref in pairs(pkg.projects) do
    local v = semver.effective(ref.requested, ref.resolved)
    if v and not seen[v] then
      seen[v] = true
      table.insert(list, v)
    end
  end
  return semver.sort_desc(list)
end

--- Projects referencing the package directly, sorted by name.
---@param pkg NugetPackage
---@return string[]
function M.project_paths(pkg)
  local paths = vim.tbl_keys(pkg.projects)
  table.sort(paths, function(a, b)
    return solution.project_name(a):lower() < solution.project_name(b):lower()
  end)
  return paths
end

---@param pkg NugetPackage
---@return boolean
function M.is_direct(pkg)
  return next(pkg.projects) ~= nil
end

--- Projects whose version is below `version`.
---@param pkg NugetPackage
---@param version string
---@return string[]
function M.projects_below(pkg, version)
  local out = {}
  for _, path in ipairs(M.project_paths(pkg)) do
    local ref = pkg.projects[path]
    local current = semver.effective(ref.requested, ref.resolved)
    if not current or semver.compare(current, version) < 0 then
      table.insert(out, path)
    end
  end
  return out
end

---@param pkg NugetPackage
---@return boolean
function M.has_update(pkg)
  return pkg.latest ~= nil and #M.projects_below(pkg, pkg.latest) > 0
end

---@param pkg NugetPackage
---@return boolean
function M.is_inconsistent(pkg)
  return #M.versions(pkg) > 1
end

--- Highest severity among the advisories, as a rank (0 when not vulnerable).
---@param pkg NugetPackage
---@return integer, string?
function M.severity(pkg)
  local rank, name = 0, nil
  for _, v in ipairs(pkg.vulnerabilities) do
    local r = SEVERITY_RANK[(v.severity or ""):lower()] or 1
    if r > rank then
      rank, name = r, v.severity
    end
  end
  return rank, name
end

---@param model NugetModel
---@param filter fun(pkg: NugetPackage): boolean
---@return NugetPackage[]
local function select(model, filter)
  local out = {}
  for _, pkg in pairs(model.packages) do
    if filter(pkg) then
      table.insert(out, pkg)
    end
  end
  table.sort(out, function(a, b)
    return a.id:lower() < b.id:lower()
  end)
  return out
end

--- Packages referenced directly by at least one project.
function M.installed(model)
  return select(model, M.is_direct)
end

--- Packages that only come in transitively but are vulnerable: the fix is a direct reference.
function M.transitive_vulnerable(model)
  return select(model, function(pkg)
    return not M.is_direct(pkg) and #pkg.vulnerabilities > 0
  end)
end

--- Direct packages with a newer version, vulnerable ones first.
function M.updates(model)
  local list = select(model, function(pkg)
    return M.is_direct(pkg) and M.has_update(pkg)
  end)
  table.sort(list, function(a, b)
    local ra, rb = M.severity(a), M.severity(b)
    if ra ~= rb then
      return ra > rb
    end
    return a.id:lower() < b.id:lower()
  end)
  return list
end

--- Direct packages referenced at different versions across projects.
function M.inconsistent(model)
  return select(model, function(pkg)
    return M.is_direct(pkg) and M.is_inconsistent(pkg)
  end)
end

return M
