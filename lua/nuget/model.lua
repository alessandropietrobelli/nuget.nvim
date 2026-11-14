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
---@field available string[]? every version a feed lists: nuget.org's flat container (unlisted ones
--- included) from the quick checks, or `dotnet package search` when `U` needed them
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
--- The versions nuget.org lists are kept either way: the outdated report names only the latest
--- one, and an update kept within a limit needs the others.
---@param model NugetModel
---@param id string
---@param latest string
---@param versions string[]?
function M.hint_latest(model, id, latest, versions)
  local pkg = model.packages[id:lower()]
  if not pkg then
    return
  end
  pkg.available = versions or pkg.available
  if model.loaded.outdated then
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

--- The version a project references, when it can be compared: nil for a `$(Property)` or a
--- range that did not resolve.
---@param ref NugetProjectRef
---@return string?
local function readable_version(ref)
  local v = semver.effective(ref.requested, ref.resolved)
  return v and semver.parse(v) and v or nil
end

--- The version an update starts from: the lowest one among the projects it would change, so
--- that projects at different versions are judged by the biggest jump. Projects whose version
--- cannot be read are left out; nil without an update or when none can be read.
---@param pkg NugetPackage
---@return string?
function M.update_base(pkg)
  if not pkg.latest then
    return nil
  end
  local base
  for _, path in ipairs(M.projects_below(pkg, pkg.latest)) do
    local v = readable_version(pkg.projects[path])
    if v and (not base or semver.compare(v, base) < 0) then
      base = v
    end
  end
  return base
end

--- What kind of update the latest version is: patch, minor or major. Nil without an update, or
--- when no project's version can be read.
---@param pkg NugetPackage
---@return NugetBump?
function M.bump(pkg)
  local base = M.update_base(pkg)
  return base and semver.bump(base, pkg.latest) or nil
end

---@class NugetUpdateGroup
---@field version string what these projects go to
---@field bump NugetBump? the biggest jump among the projects whose version can be read
---@field unreadable boolean? some of them are at a version that cannot be read
---@field projects string[]

---@alias NugetUpdateMissing "versions"|"unreadable"

--- How an update kept within `max_bump` changes `pkg`, decided project by project from the
--- version each one is at: to the latest version when that is within the limit, otherwise to the
--- highest the limit allows from there. Projects are grouped by the version they go to; one with
--- no version within the limit is left as it is.
---
--- A project whose version cannot be read goes to the latest version when there is no limit, and
--- is left out under one. Nothing is planned when the answer is unknown, and the second value
--- says why: "versions" when they were never listed (a private feed, before they are fetched),
--- "unreadable" when no project's version can be read under a limit.
---@param pkg NugetPackage
---@param max_bump NugetBump
---@param include_prerelease boolean?
---@return NugetUpdateGroup[], NugetUpdateMissing?
function M.update_plan(pkg, max_bump, include_prerelease)
  if not M.has_update(pkg) then
    return {}, nil
  end
  local groups, by_version = {}, {}
  local function add(version, bump, path)
    local g = by_version[version]
    if not g then
      g = { version = version, projects = {} }
      by_version[version] = g
      table.insert(groups, g)
    end
    if not bump then
      g.unreadable = true
    elseif not g.bump or not semver.within(bump, g.bump) then
      g.bump = bump
    end
    table.insert(g.projects, path)
  end
  local readable, unreadable = 0, {}
  for _, path in ipairs(M.projects_below(pkg, pkg.latest)) do
    local v = readable_version(pkg.projects[path])
    local bump = v and semver.bump(v, pkg.latest)
    if not bump then
      table.insert(unreadable, path)
    else
      readable = readable + 1
      if semver.within(bump, max_bump) then
        add(pkg.latest, bump, path)
      elseif not pkg.available then
        return {}, "versions"
      else
        local target = semver.highest_within(pkg.available, v, max_bump, include_prerelease)
        if target then
          add(target, semver.bump(v, target), path)
        end
      end
    end
  end
  if max_bump == "major" then
    for _, path in ipairs(unreadable) do
      add(pkg.latest, nil, path)
    end
  elseif readable == 0 then
    return {}, "unreadable"
  end
  table.sort(groups, function(a, b)
    return semver.compare(a.version, b.version) < 0
  end)
  return groups, nil
end

--- The biggest jump of a plan: what it is labelled with. Nil when it is empty, or "major" when
--- it moves a project whose version cannot be read, judged as the biggest jump there can be.
---@param groups NugetUpdateGroup[]
---@return NugetBump?
function M.plan_bump(groups)
  local biggest
  for _, g in ipairs(groups) do
    local bump = g.unreadable and "major" or g.bump
    if not biggest or not semver.within(bump, biggest) then
      biggest = bump
    end
  end
  return biggest
end

--- For a package whose latest version is a major update, the highest update that stays on the
--- same major as the lowest project it would change: the safe choice offered next to it. Nil
--- otherwise, or when the versions were never listed.
---@param pkg NugetPackage
---@param include_prerelease boolean?
---@return string?
function M.safe_update(pkg, include_prerelease)
  if M.bump(pkg) ~= "major" or not pkg.available then
    return nil
  end
  return semver.highest_within(pkg.available, M.update_base(pkg), "minor", include_prerelease)
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
