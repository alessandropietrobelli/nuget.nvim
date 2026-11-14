-- The latest version, vulnerabilities and deprecation of each package, shown at the end of its
-- line inside project files and Directory.*.props, and actions on the package under the cursor.
--
-- Only nuget.org's quick answers are used (fast.lua, registry.lua), kept for the session:
-- opening a file never runs `dotnet list package`. What nuget.org could not be asked (no
-- network, a timeout) is not kept, so the next change or save of the file asks again. Versions
-- are changed in the buffer itself, where they are written, so the change can be undone and is
-- saved with the rest of the file.
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

--- By lower-case id: the versions nuget.org lists, or false when it answered that it does not
--- have the package. A package it could not be asked about has no entry.
---@type table<string, {versions: string[]}|false>
local versions_cache = {}
--- By lower-case id, while its versions are being fetched: who waits for them.
---@type table<string, fun()[]>
local waiting = {}
--- By lower-case id@version: the deprecation, false when the version is not deprecated (or not
--- on nuget.org), true while it is being asked. A failed request leaves no entry.
---@type table<string, {reasons: string[], alternative: string?}|boolean>
local deprecations = {}
---@type NugetAdvisoryDb?
local advisories
--- Problems already reported, so a file edited while offline does not warn at every change.
---@type table<string, boolean>
local warned = {}
---@type table<integer, uv.uv_timer_t>
local timers = {}

local function config()
  return require("nuget").config
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "NuGet" })
end

--- Report a problem the first time it happens; once it goes away it is reported again.
---@param key string
---@param msg string?
local function problem(key, msg)
  if msg and not warned[key] then
    notify(msg, vim.log.levels.WARN)
  end
  warned[key] = msg ~= nil or nil
end

local UNREACHABLE = "Could not reach nuget.org: some updates or deprecations in project files are not "
  .. "shown. They are asked again when the file changes or is saved."
local NO_ADVISORIES = "Could not download the nuget.org vulnerability database: vulnerable packages "
  .. "are not marked in project files. It is asked again when the file changes or is saved."

---@param buf integer
---@return string
local function buffer_text(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
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

--- The package items of a file's text that name one package, in file order. An Include or
--- Update with a `;` list, a wildcard or an MSBuild property is left out, as are items in
--- comments. The version is the VersionOverride when there is one, else the Version.
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

---@alias NugetCentralVersions {file: string?, versions: table<string, string>}

--- The central versions that apply to a project or props file, read once from the
--- Directory.Packages.props that manages it: lower-case id → version. Empty without one.
---@param path string
---@return NugetCentralVersions
local function central_versions(path)
  local file = path ~= "" and solution.central_props(path) or nil
  local text = file and xml.read(file)
  local versions = {}
  for _, item in ipairs(text and xml.items(text, { "PackageVersion" }) or {}) do
    local include = item.attrs.include or item.attrs.update
    local v = xml.version_of(item, "version")
    if include and v then
      for part in include.value:gmatch("[^;]+") do
        local key = vim.trim(part):lower()
        versions[key] = versions[key] or v.value
      end
    end
  end
  return { file = file, versions = versions }
end

--- The version an entry asks for: its own, or for a PackageReference without one the central
--- version (then `central` is true). Nil when neither says.
---@param entry NugetInlineEntry
---@param central NugetCentralVersions
---@return string? version, boolean central
local function written_of(entry, central)
  if entry.version then
    return entry.version.value, false
  elseif entry.tag == "PackageReference" then
    local v = central.versions[entry.id:lower()]
    return v, v ~= nil
  end
  return nil, false
end

--- Fetch from nuget.org the versions of the packages not known yet, `done` once they are all
--- in: those already being fetched for another buffer are waited for, not asked twice.
---@param ids string[]
---@param done fun()
local function fetch_versions(ids, done)
  local pending = 1
  local function one_done()
    pending = pending - 1
    if pending == 0 then
      done()
    end
  end
  local cache, queue = versions_cache, waiting
  local missing, seen = {}, {}
  for _, id in ipairs(ids) do
    local key = id:lower()
    if cache[key] == nil and not seen[key] then
      seen[key] = true
      pending = pending + 1
      if not queue[key] then
        queue[key] = {}
        table.insert(missing, id)
      end
      table.insert(queue[key], one_done)
    end
  end
  if #missing > 0 then
    local failed = {}
    fast.latest(missing, {
      prerelease = true,
      concurrency = config().fast_concurrency,
      on_failed = function(id)
        failed[id:lower()] = true
      end,
    }, function(id, _, versions)
      cache[id:lower()] = { versions = versions }
    end, function()
      for _, id in ipairs(missing) do
        local key = id:lower()
        if cache[key] == nil and not failed[key] then
          cache[key] = false
        end
        local cbs = queue[key] or {}
        queue[key] = nil
        for _, cb in ipairs(cbs) do
          cb()
        end
      end
      problem("network", next(failed) and UNREACHABLE or nil)
    end)
  end
  -- Always answered later, never before the caller returns
  vim.schedule(one_done)
end

--- Whether a version is written as one exact version (not a range, a floating `1.*`, a property).
---@param v string
---@return boolean
local function exact(v)
  return v:match("^%d[%w%.%-+]*$") ~= nil and semver.parse(v) ~= nil
end

--- What the end of an entry's line says, from what is known now: for an exact version the update
--- with its kind and the same-major choice, vulnerabilities and deprecation; for a range the
--- latest version when it is outside it. Then the central icon when the version is central.
--- Empty when there is nothing to say (up to date, not vulnerable, not deprecated), for a
--- floating version or a property, and before nuget.org answers.
---@param entry NugetInlineEntry
---@param path string the file
---@param central NugetCentralVersions? read from disk when not given
---@return {[1]: string, [2]: string?}[]
function M.chunks(entry, path, central)
  local cfg = config()
  local icons = cfg.icons
  local written, is_central = written_of(entry, central or central_versions(path))
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
    local deprecation = deprecations[(entry.id .. "@" .. written):lower()]
    local pkg = {
      id = entry.id,
      latest = semver.max(known.versions, include_prerelease),
      available = known.versions,
      projects = { [path] = { requested = written, frameworks = {} } },
      transitive = {},
      vulnerabilities = advisories and fast.vulnerabilities_of(advisories, entry.id, written) or {},
      vulnerable_in = {},
      deprecation = type(deprecation) == "table" and deprecation or nil,
    }
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
  if is_central and #out > 0 then
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
  local central = central_versions(path)
  for _, entry in ipairs(M.entries(buffer_text(buf))) do
    local chunks = M.chunks(entry, path, central)
    if #chunks > 0 then
      local virt = vim.tbl_map(function(c)
        return { c[1], c[2] or "Normal" }
      end, chunks)
      vim.api.nvim_buf_set_extmark(buf, M.ns, entry.row, 0, {
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
  local path = vim.api.nvim_buf_get_name(buf)
  local central = central_versions(path)
  local entries = M.entries(buffer_text(buf))
  local function redraw()
    if attached(buf) then
      M.render(buf)
    end
  end
  fetch_versions(
    vim.tbl_map(function(e)
      return e.id
    end, entries),
    redraw
  )
  if not advisories then
    fast.advisories(function(db)
      advisories = advisories or db
      problem("advisories", not db and NO_ADVISORIES or nil)
      redraw()
    end)
  end
  -- Deprecation is per version: one request pair for each exact version written here
  local wanted = {}
  for _, entry in ipairs(entries) do
    local written = written_of(entry, central)
    local key = written and exact(written) and (entry.id .. "@" .. written):lower()
    if key and deprecations[key] == nil then
      deprecations[key] = true
      table.insert(wanted, { id = entry.id, version = written, key = key })
    end
  end
  if #wanted == 0 then
    return
  end
  local store, failed = deprecations, false
  fast.each_limited(wanted, config().fast_concurrency, function(w, done)
    registry.fetch(w.id, w.version, function(meta, err)
      if err then
        store[w.key] = nil
        failed = true
      else
        store[w.key] = meta and meta.deprecation or false
        if meta and meta.deprecation then
          redraw()
        end
      end
      done()
    end)
  end, function()
    problem("network", failed and UNREACHABLE or nil)
  end)
end

--- Refresh every buffer showing versions.
function M.refresh_all()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if attached(buf) then
      M.refresh(buf)
    end
  end
end

---@param buf integer
local function schedule_refresh(buf)
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
local function stop_timer(buf)
  local timer = timers[buf]
  if timer then
    timer:stop()
    timer:close()
    timers[buf] = nil
  end
end

--- Map `inline.keys` in the buffer, after removing those mapped there before (the config may
--- have changed since). The keys mapped are remembered in the buffer, for `disable`.
---@param buf integer
local function set_keys(buf)
  for _, lhs in ipairs(vim.b[buf].nuget_inline_keys or {}) do
    pcall(vim.keymap.del, "n", lhs, { buffer = buf })
  end
  local keys = config().inline.keys or {}
  local mapped = {}
  if keys.update then
    vim.keymap.set("n", keys.update, M.update, { buffer = buf, desc = "NuGet: update the package under the cursor" })
    table.insert(mapped, keys.update)
  end
  if keys.version then
    vim.keymap.set("n", keys.version, M.version, { buffer = buf, desc = "NuGet: pick a version of the package" })
    table.insert(mapped, keys.version)
  end
  vim.b[buf].nuget_inline_keys = mapped
end

---@param buf integer
---@return string
local function buffer_group(buf)
  return AUGROUP .. "_" .. buf
end

--- Show the versions in `buf`, and keep them up to date as it changes.
---@param buf integer
function M.attach(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  set_keys(buf)
  if not vim.b[buf].nuget_inline then
    vim.b[buf].nuget_inline = true
    -- A group of its own, so enabling again (a second setup) leaves it alone, and attaching
    -- again replaces what an earlier attach left
    local group = vim.api.nvim_create_augroup(buffer_group(buf), { clear = true })
    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      group = group,
      buffer = buf,
      callback = function()
        schedule_refresh(buf)
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      buffer = buf,
      callback = function()
        stop_timer(buf)
        vim.schedule(function()
          pcall(vim.api.nvim_del_augroup_by_name, buffer_group(buf))
        end)
      end,
    })
  end
  M.refresh(buf)
end

---@param name string
---@return boolean
local function is_package_file(name)
  local tail = vim.fn.fnamemodify(name, ":t")
  return tail:match("%.[cfv][sb]proj$") ~= nil
    or tail == "Directory.Packages.props"
    or tail == "Directory.Build.props"
    or tail == "Directory.Build.targets"
end

function M.is_enabled()
  return vim.fn.exists("#" .. AUGROUP .. "#BufReadPost") == 1
end

--- Show versions in the project files open now and in those opened later, asking nuget.org
--- again about everything.
function M.enable()
  M.clear_cache()
  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
    group = group,
    pattern = M.patterns,
    callback = function(ev)
      M.attach(ev.buf)
      -- The projects it manages read their central versions from the saved file
      if ev.event == "BufWritePost" and vim.fn.fnamemodify(ev.file, ":t") == "Directory.Packages.props" then
        M.refresh_all()
      end
    end,
  })
  -- After the window changed packages: a file it rewrote is read again and attached by
  -- BufReadPost; the others are drawn again, for the central versions they show
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "NugetPackagesChanged",
    callback = M.refresh_all,
  })
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and is_package_file(vim.api.nvim_buf_get_name(buf)) then
      M.attach(buf)
    end
  end
end

--- Stop showing versions, and take away what is shown and the keys mapped.
function M.disable()
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.b[buf].nuget_inline then
      vim.b[buf].nuget_inline = nil
      pcall(vim.api.nvim_del_augroup_by_name, buffer_group(buf))
      vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
      for _, lhs in ipairs(vim.b[buf].nuget_inline_keys or {}) do
        pcall(vim.keymap.del, "n", lhs, { buffer = buf })
      end
      vim.b[buf].nuget_inline_keys = nil
    end
  end
  for buf in pairs(timers) do
    stop_timer(buf)
  end
end

--- `:Nuget inline`. Turning it on asks nuget.org again, so it also retries after a failure.
function M.toggle()
  if M.is_enabled() then
    M.disable()
    return notify("Versions in project files: off")
  end
  M.enable()
  local why = fast.why_disabled(config())
  if why then
    notify("Versions in project files: on, but nuget.org cannot be asked: " .. why, vim.log.levels.WARN)
  else
    notify("Versions in project files: on")
  end
end

--- Forget what nuget.org said, so the next refresh asks again. Answers still on the way are
--- kept by the tables they were asked for, not by the new ones.
function M.clear_cache()
  versions_cache, waiting, advisories, deprecations, warned = {}, {}, nil, {}, {}
end

---------------------------------------------------------------------------
-- Actions on the package under the cursor
---------------------------------------------------------------------------

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

--- Every version of a package: nuget.org's, or else (a package only on private feeds, or
--- nuget.org not answering) what the feeds answer to `dotnet package search`, from the file's
--- folder so its nuget.config applies.
---@param id string
---@param path string
---@param include_prerelease boolean
---@param cb fun(versions: string[])
local function versions_of(id, path, include_prerelease, cb)
  local function from_feeds()
    notify("Fetching versions of " .. id .. "…")
    require("nuget.cli").versions(
      id,
      { prerelease = include_prerelease, sources = config().sources, cwd = vim.fs.dirname(path) },
      function(versions, problems)
        local why = #problems > 0 and (": " .. table.concat(problems, "; ")) or ""
        if #versions == 0 then
          return notify(("No versions found for %s%s"):format(id, why), vim.log.levels.WARN)
        elseif why ~= "" then
          notify(("Some feeds did not answer for %s%s"):format(id, why), vim.log.levels.WARN)
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
--- text as it is now (lines may have moved while the versions were fetched). Nothing is written
--- when the version there is no longer `expected`, the one the choice was made from.
---@param buf integer
---@param entry NugetInlineEntry
---@param expected string
---@param version string
local function write_version(buf, entry, expected, version)
  if not vim.api.nvim_buf_is_valid(buf) then
    return notify(("%s: the file was closed, nothing was changed"):format(entry.id), vim.log.levels.WARN)
  end
  local file = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":t")
  if not vim.bo[buf].modifiable then
    return notify(("%s cannot be changed (not modifiable)"):format(file), vim.log.levels.WARN)
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
  if best.version.value ~= expected then
    local msg = "The version of %s changed to %s meanwhile: nothing was changed"
    return notify(msg:format(entry.id, best.version.value), vim.log.levels.WARN)
  end
  local at = locator(text)
  local srow, scol = at(best.version.start)
  local erow, ecol = at(best.version.stop + 1)
  vim.api.nvim_buf_set_text(buf, srow, scol, erow, ecol, { version })
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
  local path = vim.api.nvim_buf_get_name(buf)
  if path == "" then
    notify("Save the file first: its folder says which feeds and central versions apply", vim.log.levels.WARN)
    return nil
  end
  local entry = M.entry_at(buf, vim.api.nvim_win_get_cursor(0)[1] - 1)
  if not entry then
    notify("No package under the cursor", vim.log.levels.WARN)
    return nil
  end
  if not entry.version then
    local central = central_versions(path)
    local version = written_of(entry, central)
    if not version or not central.file then
      notify(("%s has no version here"):format(entry.id), vim.log.levels.WARN)
      return nil
    end
    vim.cmd.edit(vim.fn.fnameescape(central.file))
    local target = vim.tbl_filter(function(e)
      return e.id:lower() == entry.id:lower() and e.tag == "PackageVersion"
    end, M.entries(buffer_text(0)))[1]
    if target then
      vim.api.nvim_win_set_cursor(0, { target.row + 1, 0 })
    end
    notify(("The version of %s is in %s"):format(entry.id, vim.fn.fnamemodify(central.file, ":t")))
    return nil
  end
  if entry.version.value:find("$(", 1, true) then
    local msg = "The version of %s is the MSBuild property %s: edit that property by hand"
    notify(msg:format(entry.id, entry.version.value), vim.log.levels.WARN)
    return nil
  end
  if not vim.bo[buf].modifiable then
    notify("This file cannot be changed (not modifiable)", vim.log.levels.WARN)
    return nil
  end
  return buf, entry
end

--- Prereleases are offered when `prerelease` is on, or when the version written is one.
---@param written string
---@return boolean
local function wants_prerelease(written)
  return config().prerelease or semver.is_prerelease(written)
end

--- Pick one of `versions` for the entry; the latest, the highest on the same major and the one
--- written are labelled.
---@param buf integer
---@param entry NugetInlineEntry
---@param versions string[] newest first
local function pick_version(buf, entry, versions)
  local written = entry.version.value
  local include_prerelease = wants_prerelease(written)
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
      write_version(buf, entry, written, choice)
    end
  end)
end

--- `:Nuget version`: pick a version of the package under the cursor, from every version listed.
function M.version()
  local buf, entry = editable_entry()
  if not buf or not entry then
    return
  end
  local written = entry.version.value
  versions_of(entry.id, vim.api.nvim_buf_get_name(buf), wants_prerelease(written), function(versions)
    pick_version(buf, entry, versions)
  end)
end

--- `:Nuget update`: update the package under the cursor to its latest version. For a major
--- update, ask between it, the highest on the same major and the full list; for a range or a
--- floating version, ask before replacing it with the latest version.
function M.update()
  local buf, entry = editable_entry()
  if not buf or not entry then
    return
  end
  local written = entry.version.value
  local include_prerelease = wants_prerelease(written)
  versions_of(entry.id, vim.api.nvim_buf_get_name(buf), include_prerelease, function(versions)
    local latest = semver.max(versions, include_prerelease)
    if not latest then
      return notify("No versions found for " .. entry.id, vim.log.levels.WARN)
    end
    if not exact(written) then
      -- A range or a floating version: replace it, as the window does, after asking
      local label = ("Replace %s with %s"):format(written, latest)
      return vim.ui.select({ label, "Cancel" }, { prompt = entry.id }, function(choice)
        if choice == label then
          write_version(buf, entry, written, latest)
        end
      end)
    end
    local bump = semver.bump(written, latest)
    if not bump then
      return notify(("%s is up to date (%s)"):format(entry.id, written))
    end
    if bump ~= "major" then
      return write_version(buf, entry, written, latest)
    end
    local same_major = semver.highest_within(versions, written, "minor", include_prerelease)
    local choices = { { ("Update to %s (major)"):format(latest), latest } }
    if same_major then
      table.insert(choices, { ("Update to %s (same major)"):format(same_major), same_major })
    end
    table.insert(choices, { "Choose version…" })
    vim.ui.select(choices, {
      prompt = entry.id,
      format_item = function(c)
        return c[1]
      end,
    }, function(choice)
      if not choice then
        return
      elseif choice[2] then
        write_version(buf, entry, written, choice[2])
      else
        pick_version(buf, entry, semver.sort_desc(versions))
      end
    end)
  end)
end

return M
