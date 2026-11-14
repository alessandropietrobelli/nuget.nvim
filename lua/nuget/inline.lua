-- The latest version, vulnerabilities and deprecation of each package, shown at the end of its
-- line inside project files and Directory.*.props, and actions on the package under the cursor.
--
-- Only nuget.org's quick answers are used (fast.lua, registry.lua), kept for the session:
-- opening a file never runs `dotnet list package`. Versions are changed in the buffer itself,
-- where they are written, so the change can be undone and is saved with the rest of the file.
local fast = require("nuget.fast")
local model = require("nuget.model")
local registry = require("nuget.registry")
local semver = require("nuget.semver")
local solution = require("nuget.solution")
local xml = require("nuget.xml")

require("nuget.highlights")

local M = {}

M.ns = vim.api.nvim_create_namespace("nuget_inline")

M.patterns = {
  "*.csproj",
  "*.fsproj",
  "*.vbproj",
  "Directory.Packages.props",
  "Directory.Build.props",
  "Directory.Build.targets",
}

local TAGS = { "PackageReference", "PackageVersion", "GlobalPackageReference" }
local AUGROUP = "nuget_inline"
local DEBOUNCE_MS = 300

---@class NugetInlineEntry
---@field id string
---@field tag string
---@field row integer 0-based line the text goes on: the version's, or the item's without one
---@field first integer 0-based first line of the item
---@field last integer 0-based last line of the item
---@field attr "version"|"versionoverride"|nil where the item writes its version
---@field version {value: string, start: integer, stop: integer}? byte positions in the text

---@type table<string, {versions: string[]}|false> by lower-case id; false: not on nuget.org
local versions_cache = {}
---@type table<string, fun()[]>
local waiting = {}
---@type table<string, {reasons: string[], alternative: string?}|false> by id@version, lower-case
local deprecations = {}
---@type NugetAdvisoryDb|false|nil false once it failed to download
local advisories
---@type table<integer, uv.uv_timer_t>
local timers = {}

local function config()
  return require("nuget").config
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "NuGet" })
end

--- 0-based line of each byte position of `text`, through a table of line starts.
---@param text string
---@return fun(pos: integer): integer, integer line and 0-based column
local function locator(text)
  local starts = { 1 }
  for nl in text:gmatch("()\n") do
    table.insert(starts, nl + 1)
  end
  return function(pos)
    local lo, hi = 1, #starts
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if starts[mid] <= pos then
        lo = mid
      else
        hi = mid - 1
      end
    end
    return lo - 1, pos - starts[lo]
  end
end

--- The package items of a file's text that name one package: an Include or Update with a `;`
--- list or a wildcard is left out, as are items in comments.
---@param text string
---@return NugetInlineEntry[]
function M.entries(text)
  local at = locator(text)
  local out = {}
  for _, item in ipairs(xml.items(text, TAGS)) do
    local include = item.attrs.include or item.attrs.update
    local id = include and vim.trim(include.value)
    if id and id ~= "" and not id:find("[;*$]") then
      local attr = xml.version_of(item, "versionoverride") and "versionoverride"
        or xml.version_of(item, "version") and "version"
        or nil
      local version = attr and xml.version_of(item, attr) or nil
      local first = at(item.start)
      table.insert(out, {
        id = id,
        tag = item.tag,
        row = version and (at(version.start)) or first,
        first = first,
        last = (at(item.stop)),
        attr = attr,
        version = version,
      })
    end
  end
  return out
end

--- The central version of a package for a project or props file, from the
--- Directory.Packages.props that manages it. Nil without one.
---@param path string
---@param id string
---@return string? version, string? file
local function central_version(path, id)
  local central = solution.central_props(path)
  local text = central and xml.read(central)
  if not text then
    return nil
  end
  for _, item in ipairs(xml.find(text, "PackageVersion", id)) do
    local v = xml.version_of(item, "version")
    if v then
      return v.value, central
    end
  end
  return nil, central
end

--- Fetch from nuget.org the versions of the packages not asked about yet; `done` once all are
--- in. A package nuget.org does not have is remembered as such.
---@param ids string[]
---@param done fun()
local function fetch_versions(ids, done)
  local missing = {}
  for _, id in ipairs(ids) do
    local key = id:lower()
    if versions_cache[key] == nil and not waiting[key] then
      waiting[key] = {}
      table.insert(missing, id)
    end
  end
  if #missing == 0 then
    return vim.schedule(done)
  end
  fast.latest(missing, { prerelease = true, concurrency = config().fast_concurrency }, function(id, _, versions)
    versions_cache[id:lower()] = { versions = versions }
  end, function()
    for _, id in ipairs(missing) do
      local key = id:lower()
      if versions_cache[key] == nil then
        versions_cache[key] = false
      end
      local cbs = waiting[key] or {}
      waiting[key] = nil
      for _, cb in ipairs(cbs) do
        cb()
      end
    end
    done()
  end)
end

--- Whether a version is written as one exact version (not a range, a floating `1.*`, a property).
---@param v string
---@return boolean
local function exact(v)
  return v:match("^%d[%w%.%-+]*$") ~= nil and semver.parse(v) ~= nil
end

--- What the end of an entry's line says: the update with its kind and the same-major choice,
--- vulnerabilities, deprecation. Empty when there is nothing to say, or nothing known yet.
---@param entry NugetInlineEntry
---@param path string the file
---@return {[1]: string, [2]: string?}[]
function M.chunks(entry, path)
  local cfg = config()
  local icons = cfg.icons
  local written, central
  if entry.version then
    written = entry.version.value
  elseif entry.tag == "PackageReference" then
    written = central_version(path, entry.id)
    central = written ~= nil
  end
  if not written or written:find("$(", 1, true) then
    return {}
  end
  local known = versions_cache[entry.id:lower()]
  if not known then
    return {}
  end
  local view = require("nuget.ui.view")
  local out = {}
  if exact(written) then
    local include_prerelease = cfg.prerelease or semver.is_prerelease(written)
    local pkg = {
      id = entry.id,
      latest = semver.max(known.versions, include_prerelease),
      available = known.versions,
      projects = { [path] = { requested = written, frameworks = {} } },
      transitive = {},
      vulnerabilities = {},
      vulnerable_in = {},
    }
    if advisories then
      pkg.vulnerabilities = fast.vulnerabilities_of(advisories, entry.id, written)
    end
    pkg.deprecation = deprecations[(entry.id .. "@" .. written):lower()] or nil
    if pkg.latest and model.has_update(pkg) then
      vim.list_extend(out, view.update_chunks(pkg, icons, include_prerelease))
    end
    vim.list_extend(out, view.badges(pkg, icons, false))
  elseif written:match("^[%[%(]") then
    -- A range: whether the latest version is outside it, without judging the jump
    local latest = semver.max(known.versions, cfg.prerelease)
    if latest and not semver.in_range(latest, written) then
      table.insert(out, { " " .. icons.update .. " " .. latest, "NugetUpdate" })
    end
  end
  if central and #out > 0 then
    table.insert(out, { " " .. icons.central, "NugetMuted" })
  end
  return out
end

---@param buf integer
---@return boolean
local function attached(buf)
  return vim.api.nvim_buf_is_valid(buf) and vim.b[buf].nuget_inline == true
end

--- Draw what is known now for every entry of the buffer.
---@param buf integer
function M.render(buf)
  if not attached(buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  local path = vim.api.nvim_buf_get_name(buf)
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  for _, entry in ipairs(M.entries(text)) do
    local chunks = M.chunks(entry, path)
    if #chunks > 0 then
      local virt = vim.tbl_map(function(c)
        return { c[1], c[2] or "Normal" }
      end, chunks)
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, entry.row, 0, {
        virt_text = virt,
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
    end
  end
end

--- Fetch what the buffer's packages need, drawing as answers come in.
---@param buf integer
function M.refresh(buf)
  if not attached(buf) then
    return
  end
  M.render(buf)
  if not fast.enabled(config()) then
    return
  end
  local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local path = vim.api.nvim_buf_get_name(buf)
  local entries = M.entries(text)
  local ids = vim.tbl_map(function(e)
    return e.id
  end, entries)
  local function redraw()
    if attached(buf) then
      M.render(buf)
    end
  end
  fetch_versions(ids, redraw)
  if advisories == nil then
    fast.advisories(function(db)
      if advisories == nil then
        advisories = db or false
      end
      redraw()
    end)
  end
  -- Deprecation is per version: one request pair for each exact version written here
  for _, entry in ipairs(entries) do
    local written = entry.version and entry.version.value
    if not written and entry.tag == "PackageReference" then
      written = central_version(path, entry.id)
    end
    local key = written and (entry.id .. "@" .. written):lower()
    if key and exact(written) and deprecations[key] == nil then
      deprecations[key] = false
      registry.fetch(entry.id, written, function(meta)
        if meta and meta.deprecation then
          deprecations[key] = meta.deprecation
          redraw()
        end
      end)
    end
  end
end

---@param buf integer
local function schedule_render(buf)
  local timer = timers[buf]
  if not timer then
    timer = (vim.uv or vim.loop).new_timer()
    timers[buf] = timer
  end
  timer:stop()
  timer:start(
    DEBOUNCE_MS,
    0,
    vim.schedule_wrap(function()
      M.refresh(buf)
    end)
  )
end

---@param buf integer
local function set_keys(buf)
  local keys = config().inline.keys or {}
  if keys.update then
    vim.keymap.set("n", keys.update, M.update, { buffer = buf, desc = "NuGet: update the package under the cursor" })
  end
  if keys.version then
    vim.keymap.set("n", keys.version, M.version, { buffer = buf, desc = "NuGet: pick a version of the package" })
  end
end

--- Show the versions in `buf`, and keep them up to date as it changes.
---@param buf integer
function M.attach(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if not vim.b[buf].nuget_inline then
    vim.b[buf].nuget_inline = true
    set_keys(buf)
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = AUGROUP,
      buffer = buf,
      callback = function()
        schedule_render(buf)
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = AUGROUP,
      buffer = buf,
      callback = function()
        local timer = timers[buf]
        if timer then
          timer:stop()
          timer:close()
          timers[buf] = nil
        end
      end,
    })
  end
  M.refresh(buf)
end

---@param name string
---@return boolean
local function is_package_file(name)
  local tail = vim.fn.fnamemodify(name, ":t")
  return tail:match("%.[cfv][sb]?proj$") ~= nil
    or tail == "Directory.Packages.props"
    or tail == "Directory.Build.props"
    or tail == "Directory.Build.targets"
end

function M.is_enabled()
  return vim.fn.exists("#" .. AUGROUP .. "#BufReadPost") == 1
end

--- Show versions in the project files open now and in those opened later.
function M.enable()
  vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = AUGROUP,
    pattern = M.patterns,
    callback = function(ev)
      M.attach(ev.buf)
    end,
  })
  -- The window changed some packages: the files it rewrote are read again, the others still
  -- show what was true before
  vim.api.nvim_create_autocmd("User", {
    group = AUGROUP,
    pattern = "NugetPackagesChanged",
    callback = function()
      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if attached(buf) then
          M.refresh(buf)
        end
      end
    end,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and is_package_file(vim.api.nvim_buf_get_name(buf)) then
      M.attach(buf)
    end
  end
end

--- Stop showing versions, and take away what is shown.
function M.disable()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].nuget_inline then
      vim.b[buf].nuget_inline = nil
      vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
      local keys = config().inline.keys or {}
      for _, lhs in pairs(keys) do
        pcall(vim.keymap.del, "n", lhs, { buffer = buf })
      end
    end
  end
  for buf, timer in pairs(timers) do
    timer:stop()
    timer:close()
    timers[buf] = nil
  end
end

function M.toggle()
  if M.is_enabled() then
    M.disable()
    notify("Versions in project files: off")
  else
    M.enable()
    notify("Versions in project files: on")
  end
end

--- Forget what nuget.org said, so the next refresh asks again.
function M.clear_cache()
  versions_cache, waiting, advisories, deprecations = {}, {}, nil, {}
end

---------------------------------------------------------------------------
-- Actions on the package under the cursor
---------------------------------------------------------------------------

---@param buf integer
---@return string
local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

--- The entry the cursor is on, anywhere between the first and the last line of its item.
---@param buf integer
---@param row integer 0-based
---@return NugetInlineEntry?
function M.entry_at(buf, row)
  for _, entry in ipairs(M.entries(buffer_text(buf))) do
    if row >= entry.first and row <= entry.last then
      return entry
    end
  end
  return nil
end

--- Every version of a package: nuget.org's, or else what the feeds answer to
--- `dotnet package search`, from the file's folder so its nuget.config applies.
---@param id string
---@param path string
---@param cb fun(versions: string[])
local function versions_of(id, path, cb)
  local function from_feeds()
    notify("Fetching versions of " .. id .. "…")
    require("nuget.cli").versions(
      id,
      { prerelease = config().prerelease, sources = config().sources, cwd = vim.fs.dirname(path) },
      function(versions, problems)
        if #versions == 0 then
          notify(
            ("No versions found for %s%s"):format(id, #problems > 0 and (": " .. problems[1]) or ""),
            vim.log.levels.WARN
          )
          return
        end
        cb(versions)
      end
    )
  end
  if not fast.enabled(config()) then
    return from_feeds()
  end
  fetch_versions({ id }, function()
    local known = versions_cache[id:lower()]
    if known and #known.versions > 0 then
      cb(semver.sort_desc(known.versions))
    else
      from_feeds()
    end
  end)
end

--- Write `version` into the buffer where the entry's version is, finding the entry again in the
--- text as it is now (it may have changed while the versions were fetched).
---@param buf integer
---@param entry NugetInlineEntry
---@param version string
local function write_version(buf, entry, version)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local text = buffer_text(buf)
  local best
  for _, e in ipairs(M.entries(text)) do
    if e.id:lower() == entry.id:lower() and e.tag == entry.tag and e.attr == entry.attr and e.version then
      if not best or math.abs(e.row - entry.row) < math.abs(best.row - entry.row) then
        best = e
      end
    end
  end
  if not best then
    return notify(("%s is no longer in the file"):format(entry.id), vim.log.levels.WARN)
  end
  local at = locator(text)
  local srow, scol = at(best.version.start)
  local erow, ecol = at(best.version.stop + 1)
  vim.api.nvim_buf_set_text(buf, srow, scol, erow, ecol, { version })
  local file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
  local shared = not file:match("proj$")
  notify(
    ("%s → %s in %s%s: save to apply"):format(
      entry.id,
      version,
      file,
      shared and ", for every project that uses it" or ""
    )
  )
  M.render(buf)
end

--- The entry under the cursor, when its version can be changed here. Otherwise says why, and
--- for a version kept in Directory.Packages.props goes there.
---@return integer? buf, NugetInlineEntry?
local function editable_entry()
  local buf = vim.api.nvim_get_current_buf()
  local entry = M.entry_at(buf, vim.api.nvim_win_get_cursor(0)[1] - 1)
  if not entry then
    notify("No package under the cursor", vim.log.levels.WARN)
    return nil
  end
  if not entry.version then
    local path = vim.api.nvim_buf_get_name(buf)
    local version, central = central_version(path, entry.id)
    if not version then
      notify(("%s has no version here"):format(entry.id), vim.log.levels.WARN)
      return nil
    end
    vim.cmd.edit(vim.fn.fnameescape(central))
    local target = vim.tbl_filter(function(e)
      return e.id:lower() == entry.id:lower() and e.tag == "PackageVersion"
    end, M.entries(buffer_text(0)))[1]
    if target then
      vim.api.nvim_win_set_cursor(0, { target.row + 1, 0 })
    end
    notify(("The version of %s is in %s"):format(entry.id, vim.fn.fnamemodify(central, ":t")))
    return nil
  end
  if entry.version.value:find("$(", 1, true) then
    local msg = "The version of %s is the MSBuild property %s: edit that property by hand"
    notify(msg:format(entry.id, entry.version.value), vim.log.levels.WARN)
    return nil
  end
  return buf, entry
end

--- Pick a version of the package under the cursor; the latest, the highest on the same major
--- and the one written are labelled.
function M.version()
  local buf, entry = editable_entry()
  if not entry then
    return
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local written = entry.version.value
  versions_of(entry.id, path, function(versions)
    local include_prerelease = config().prerelease or semver.is_prerelease(written)
    versions = vim.tbl_filter(function(v)
      return include_prerelease or v == written or not semver.is_prerelease(v)
    end, versions)
    local latest = semver.max(versions, include_prerelease)
    local same_major = exact(written)
      and semver.bump(written, latest or "") == "major"
      and semver.highest_within(versions, written, "minor", include_prerelease)
    vim.ui.select(versions, {
      prompt = entry.id .. " version",
      format_item = function(v)
        local tags = {}
        if v == latest then
          table.insert(tags, "latest")
        end
        if v == same_major then
          table.insert(tags, "same major")
        end
        if v == written then
          table.insert(tags, "installed")
        end
        if semver.is_prerelease(v) then
          table.insert(tags, "prerelease")
        end
        return #tags > 0 and (v .. "  (" .. table.concat(tags, ", ") .. ")") or v
      end,
    }, function(choice)
      if choice and choice ~= written then
        write_version(buf, entry, choice)
      end
    end)
  end)
end

--- Update the package under the cursor to its latest version. For a major update, ask between
--- it and the highest on the same major.
function M.update()
  local buf, entry = editable_entry()
  if not entry then
    return
  end
  local path = vim.api.nvim_buf_get_name(buf)
  local written = entry.version.value
  versions_of(entry.id, path, function(versions)
    local include_prerelease = config().prerelease or semver.is_prerelease(written)
    local latest = semver.max(versions, include_prerelease)
    if not latest then
      return notify("No versions found for " .. entry.id, vim.log.levels.WARN)
    end
    if not exact(written) then
      -- A range or a floating version: replace it, as the window does, after asking
      local label = ("Replace %s with %s"):format(written, latest)
      return vim.ui.select({ label, "Cancel" }, { prompt = entry.id }, function(choice)
        if choice == label then
          write_version(buf, entry, latest)
        end
      end)
    end
    local bump = semver.bump(written, latest)
    if not bump then
      return notify(("%s is up to date (%s)"):format(entry.id, written))
    end
    local same_major = bump == "major" and semver.highest_within(versions, written, "minor", include_prerelease)
    if bump ~= "major" then
      return write_version(buf, entry, latest)
    end
    local entries = { { ("Update to %s (major)"):format(latest), latest } }
    if same_major then
      table.insert(entries, { ("Update to %s (same major)"):format(same_major), same_major })
    end
    table.insert(entries, { "Choose version…" })
    vim.ui.select(entries, {
      prompt = entry.id,
      format_item = function(e)
        return e[1]
      end,
    }, function(choice)
      if not choice then
        return
      elseif choice[2] then
        write_version(buf, entry, choice[2])
      else
        M.version()
      end
    end)
  end)
end

return M
