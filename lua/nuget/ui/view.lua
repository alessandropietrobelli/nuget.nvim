-- Builds the text of the list and details panes. Pure: takes state, returns lines.
local model = require("nuget.model")
local semver = require("nuget.semver")
local solution = require("nuget.solution")

local M = {}

---@class NugetLine
---@field text string
---@field hl {[1]: integer, [2]: integer, [3]: string}[] byte ranges (0-based, end exclusive)
---@field item any? what the line stands for (a package, a search result…)

---@class NugetBuilder
---@field lines NugetLine[]
local Builder = {}
Builder.__index = Builder

function M.builder()
  return setmetatable({ lines = {} }, Builder)
end

--- Append a line made of {text, hl_group?} chunks.
---@param chunks {[1]: string, [2]: string?}[]
---@param item any?
function Builder:add(chunks, item)
  local text, hl = "", {}
  for _, chunk in ipairs(chunks) do
    if chunk[1] ~= "" then
      if chunk[2] then
        table.insert(hl, { #text, #text + #chunk[1], chunk[2] })
      end
      text = text .. chunk[1]
    end
  end
  table.insert(self.lines, { text = text, hl = hl, item = item })
end

function Builder:blank()
  self:add({})
end

---@param text string
---@param width integer
---@param group string?
function Builder:wrap(text, width, group)
  for _, para in ipairs(vim.split(text or "", "\n", { plain = true })) do
    local line = ""
    for word in para:gmatch("%S+") do
      if line ~= "" and vim.fn.strdisplaywidth(line .. " " .. word) > width then
        self:add({ { line, group } })
        line = word
      else
        line = line == "" and word or (line .. " " .. word)
      end
    end
    if line ~= "" then
      self:add({ { line, group } })
    end
  end
end

---@param s string
---@param width integer
---@return string
local function fit(s, width)
  if width <= 0 then
    return ""
  end
  local w = vim.fn.strdisplaywidth(s)
  if w > width then
    return vim.fn.strcharpart(s, 0, math.max(width - 1, 0)) .. "…"
  end
  return s .. string.rep(" ", width - w)
end
M.fit = fit

---@param n number?
---@return string
function M.downloads(n)
  if not n then
    return ""
  end
  for _, unit in ipairs({ { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
    if n >= unit[1] then
      local v = n / unit[1]
      return (v < 10 and "%.1f%s" or "%.0f%s"):format(v, unit[2])
    end
  end
  return tostring(n)
end

local SEVERITY_HL = {
  low = "NugetSeverityLow",
  moderate = "NugetSeverityModerate",
  high = "NugetSeverityHigh",
  critical = "NugetSeverityHigh",
}

---@param severity string?
---@return string
function M.severity_hl(severity)
  return SEVERITY_HL[(severity or ""):lower()] or "NugetSeverityModerate"
end

--- Badge chunks for a package: vulnerable, deprecated, inconsistent, central.
---@param pkg NugetPackage
---@param icons table
---@return {[1]: string, [2]: string?}[]
local function badges(pkg, icons)
  local out = {}
  local rank, severity = model.severity(pkg)
  if rank > 0 then
    table.insert(out, { " " .. icons.vulnerable .. " " .. severity, M.severity_hl(severity) })
  end
  if pkg.deprecation then
    table.insert(out, { " " .. icons.deprecated .. " deprecated", "NugetDeprecated" })
  end
  if model.is_direct(pkg) and model.is_inconsistent(pkg) then
    table.insert(out, { " " .. icons.inconsistent, "NugetInconsistent" })
  end
  if pkg.central then
    table.insert(out, { " " .. icons.central, "NugetMuted" })
  end
  return out
end

---@param ids string[]
---@param width integer
---@return integer
local function id_width(ids, width)
  local w = 10
  for _, id in ipairs(ids) do
    w = math.max(w, vim.fn.strdisplaywidth(id))
  end
  return math.min(w, math.floor(width * 0.45))
end

---@param query string
---@param text string
---@return boolean
local function matches(query, text)
  return query == "" or text:lower():find(query:lower(), 1, true) ~= nil
end

---@class NugetViewState
---@field tab "browse"|"installed"|"updates"|"consolidate"
---@field model NugetModel
---@field loading table<string, boolean>
---@field filter string
---@field marks table<string, true> lower-case ids
---@field search {results: NugetSearchResult[], loading: boolean, query: string, more: boolean, problems: string[]}
---@field icons table

--- Rows of the list pane for the current tab.
---@param s NugetViewState
---@param width integer
---@return NugetLine[]
function M.list(s, width)
  local b = M.builder()
  local icons = s.icons

  if s.tab == "browse" then
    local results = s.search.results
    if s.search.query == "" then
      b:add({ { "Type / to search NuGet", "NugetMuted" } })
      return b.lines
    end
    if #results == 0 then
      b:add({ { s.search.loading and "Searching…" or "No packages found", "NugetMuted" } })
      return b.lines
    end
    local idw = id_width(
      vim.tbl_map(function(r)
        return r.id
      end, results),
      width
    )
    for _, r in ipairs(results) do
      local pkg = s.model.packages[r.id:lower()]
      local installed = pkg and model.is_direct(pkg) and model.versions(pkg)
      local chunks = {
        { fit(r.id, idw), "NugetId" },
        { " " },
        { fit(r.version or "", 16), "NugetVersion" },
        { fit(M.downloads(r.downloads), 7), "NugetMuted" },
      }
      if installed then
        table.insert(chunks, { " " .. icons.installed .. " " .. table.concat(installed, ", "), "NugetInstalled" })
      end
      if r.source ~= "nuget.org" then
        table.insert(chunks, { " [" .. r.source .. "]", "NugetSource" })
      end
      b:add(chunks, { kind = "search", result = r })
    end
    if s.search.more then
      b:add({ { s.search.loading and "Loading more…" or "— more results: press ] —", "NugetMuted" } })
    end
    return b.lines
  end

  local list
  if s.tab == "installed" then
    list = model.installed(s.model)
  elseif s.tab == "updates" then
    list = model.updates(s.model)
  else
    list = model.inconsistent(s.model)
  end
  list = vim.tbl_filter(function(pkg)
    return matches(s.filter, pkg.id)
  end, list)

  local waiting = s.loading.plain
  if s.tab == "updates" then
    waiting = waiting or s.loading.fast_latest or (s.loading.outdated and not s.model.loaded.fast_latest)
  end
  if #list == 0 then
    local empty = {
      installed = "No packages",
      updates = "Everything is up to date",
      consolidate = "Every package has a single version",
    }
    if waiting then
      b:add({ { s.tab == "updates" and "Checking for updates…" or "Loading packages…", "NugetMuted" } })
    elseif s.filter ~= "" then
      b:add({ { "Nothing matches “" .. s.filter .. "”", "NugetMuted" } })
    else
      b:add({ { empty[s.tab], "NugetMuted" } })
    end
  end

  local idw = id_width(
    vim.tbl_map(function(p)
      return p.id
    end, list),
    width
  )
  for _, pkg in ipairs(list) do
    local versions = model.versions(pkg)
    local chunks = {}
    if s.tab == "updates" then
      local marked = s.marks[pkg.id:lower()]
      table.insert(
        chunks,
        { (marked and icons.marked or icons.unmarked) .. " ", marked and "NugetMarked" or "NugetMuted" }
      )
    end
    table.insert(chunks, { fit(pkg.id, idw), "NugetId" })
    table.insert(chunks, { " " })
    if s.tab == "consolidate" then
      local parts = {}
      for _, v in ipairs(versions) do
        local names = {}
        for path, ref in pairs(pkg.projects) do
          if semver.effective(ref.requested, ref.resolved) == v then
            table.insert(names, solution.project_name(path))
          end
        end
        table.sort(names)
        table.insert(parts, v .. " (" .. table.concat(names, ", ") .. ")")
      end
      table.insert(chunks, { table.concat(parts, " · "), "NugetVersion" })
    else
      table.insert(chunks, { table.concat(versions, ", "), "NugetVersion" })
      if pkg.latest and model.has_update(pkg) then
        table.insert(chunks, { " " .. icons.update .. " " .. pkg.latest, "NugetUpdate" })
      end
      if s.tab == "updates" then
        local n = #model.projects_below(pkg, pkg.latest)
        table.insert(chunks, { ("  %d project%s"):format(n, n == 1 and "" or "s"), "NugetMuted" })
      end
    end
    vim.list_extend(chunks, badges(pkg, icons))
    b:add(chunks, { kind = "package", package = pkg })
  end

  if s.tab == "installed" then
    local transitive = vim.tbl_filter(function(pkg)
      return matches(s.filter, pkg.id)
    end, model.transitive_vulnerable(s.model))
    if #transitive > 0 then
      b:blank()
      b:add({ { "Vulnerable transitive packages", "NugetSection" } })
      for _, pkg in ipairs(transitive) do
        local versions = {}
        for _, v in pairs(pkg.transitive) do
          if not vim.tbl_contains(versions, v) then
            table.insert(versions, v)
          end
        end
        local chunks = {
          { fit(icons.transitive .. " " .. pkg.id, idw), "NugetId" },
          { " " },
          { table.concat(semver.sort_desc(versions), ", "), "NugetVersion" },
        }
        vim.list_extend(chunks, badges(pkg, icons))
        b:add(chunks, { kind = "package", package = pkg })
      end
    end
  end

  return b.lines
end

--- Details pane for a list item.
---@param item table?
---@param s {model: NugetModel, icons: table, meta: NugetMetadata?, meta_loading: boolean}
---@param width integer
---@return NugetLine[]
function M.details(item, s, width)
  local b = M.builder()
  if not item then
    return b.lines
  end
  local pkg, result
  if item.kind == "search" then
    result = item.result
    pkg = s.model.packages[result.id:lower()]
  else
    pkg = item.package
  end
  local id = (pkg and pkg.id) or result.id
  local meta = s.meta

  b:add({ { id, "NugetTitle" } })
  local latest = (pkg and pkg.latest) or (result and result.version)
  if latest then
    b:add({ { "Latest ", "NugetLabel" }, { latest, "NugetLatest" } })
  end
  if result and result.source and result.source ~= "nuget.org" then
    b:add({ { "Source ", "NugetLabel" }, { result.source, "NugetSource" } })
  end

  if pkg and model.is_direct(pkg) then
    b:blank()
    b:add({ { "Installed", "NugetSection" } })
    local namew = 0
    for path in pairs(pkg.projects) do
      namew = math.max(namew, vim.fn.strdisplaywidth(solution.project_name(path)))
    end
    for _, path in ipairs(model.project_paths(pkg)) do
      local ref = pkg.projects[path]
      local version = semver.effective(ref.requested, ref.resolved) or "?"
      local chunks = {
        { "  " .. fit(solution.project_name(path), namew) .. "  ", "NugetLabel" },
        { version, "NugetVersion" },
        { "  " .. table.concat(ref.frameworks, ", "), "NugetMuted" },
      }
      if ref.requested and ref.requested ~= version then
        table.insert(chunks, { "  (" .. ref.requested .. ")", "NugetMuted" })
      end
      if pkg.vulnerable_in[path] then
        table.insert(chunks, { " " .. s.icons.vulnerable, M.severity_hl(select(2, model.severity(pkg))) })
      end
      local origin = ref.origin
      if origin and origin.kind == "override" then
        table.insert(chunks, { "  VersionOverride", "NugetInconsistent" })
      end
      b:add(chunks)
    end
    -- Shared files, each once: changing the version there changes it for every project above
    local files = {}
    for _, path in ipairs(model.project_paths(pkg)) do
      local origin = pkg.projects[path].origin
      if origin and origin.file and origin.kind ~= "project" and origin.kind ~= "override" then
        local label = vim.fn.fnamemodify(origin.file, ":~:.")
          .. (origin.kind == "global" and " (GlobalPackageReference)" or "")
        if not vim.tbl_contains(files, label) then
          table.insert(files, label)
        end
      end
    end
    for _, label in ipairs(files) do
      b:add({ { "  " .. s.icons.central .. " version in " .. label, "NugetMuted" } })
    end
  elseif pkg and next(pkg.transitive) then
    b:blank()
    b:add({ { "Transitive", "NugetSection" } })
    for path, version in pairs(pkg.transitive) do
      b:add({ { "  " .. solution.project_name(path) .. "  ", "NugetLabel" }, { version or "?", "NugetVersion" } })
    end
    b:add({ { "  Add a direct reference to a fixed version to override it (i)", "NugetMuted" } })
  end

  if pkg and #pkg.vulnerabilities > 0 then
    b:blank()
    b:add({ { "Vulnerabilities", "NugetSection" } })
    for _, v in ipairs(pkg.vulnerabilities) do
      b:add({
        { "  " .. s.icons.vulnerable .. " " .. fit(v.severity, 9), M.severity_hl(v.severity) },
        { v.url, "NugetUrl" },
      })
    end
  end
  if pkg and pkg.deprecation then
    b:blank()
    b:add({
      { "Deprecated", "NugetDeprecated" },
      { "  " .. table.concat(pkg.deprecation.reasons or {}, ", "), "NugetMuted" },
    })
    if pkg.deprecation.alternative then
      b:add({ { "  Alternative: ", "NugetLabel" }, { pkg.deprecation.alternative, "NugetId" } })
    end
  end

  b:blank()
  if meta then
    b:add({
      { "Version ", "NugetLabel" },
      { meta.version, "NugetVersion" },
      { meta.published and ("  " .. meta.published) or "", "NugetMuted" },
    })
    if meta.authors and meta.authors ~= "" then
      b:add({ { "Authors ", "NugetLabel" }, { meta.authors } })
    end
    if meta.license then
      b:add({ { "License ", "NugetLabel" }, { meta.license } })
    end
  end
  local owners = result and result.owners
  if owners and owners ~= "" then
    b:add({ { "Owners  ", "NugetLabel" }, { owners } })
  end
  if result and result.downloads then
    b:add({ { "Downloads ", "NugetLabel" }, { M.downloads(result.downloads) } })
  end
  local url = (meta and meta.project_url) or (result and result.project_url)
  if url then
    b:add({ { "Project ", "NugetLabel" }, { url, "NugetUrl" } })
  end
  if meta and #meta.tags > 0 then
    b:add({ { "Tags    ", "NugetLabel" }, { table.concat(meta.tags, ", "), "NugetMuted" } })
  end

  local description = (meta and meta.description) or (result and result.description)
  if description and description ~= "" then
    b:blank()
    b:wrap(description, width)
  elseif s.meta_loading then
    b:blank()
    b:add({ { "Loading details…", "NugetMuted" } })
  end

  if meta and #meta.dependencies > 0 then
    b:blank()
    b:add({ { "Dependencies", "NugetSection" } })
    -- The frameworks the solution targets come first; the rest is summarised
    local used = {}
    for _, ref in pairs(pkg and pkg.projects or {}) do
      for _, fw in ipairs(ref.frameworks) do
        used[fw:lower()] = true
      end
    end
    local groups = {}
    for _, group in ipairs(meta.dependencies) do
      table.insert(used[group.framework:lower()] and groups or {}, group)
    end
    for _, group in ipairs(meta.dependencies) do
      if not used[group.framework:lower()] then
        table.insert(groups, group)
      end
    end
    local shown = math.min(#groups, 3)
    for i = 1, shown do
      local group = groups[i]
      b:add({ { "  " .. group.framework, "NugetLabel" } })
      if #group.packages == 0 then
        b:add({ { "    none", "NugetMuted" } })
      end
      for _, dep in ipairs(group.packages) do
        b:add({ { "    " .. dep, "NugetMuted" } })
      end
    end
    if #groups > shown then
      local rest = {}
      for i = shown + 1, #groups do
        table.insert(rest, groups[i].framework)
      end
      b:add({ { "  + " .. table.concat(rest, ", "), "NugetMuted" } })
    end
  end

  return b.lines
end

--- The version the details pane describes: the latest one, or the highest installed.
---@param item table?
---@return string?, string?
function M.detail_version(item)
  if not item then
    return nil
  end
  if item.kind == "search" then
    return item.result.id, item.result.version
  end
  local pkg = item.package
  local version = pkg.latest or model.versions(pkg)[1]
  if not version then
    for _, v in pairs(pkg.transitive) do
      version = v
    end
  end
  return pkg.id, version
end

return M
