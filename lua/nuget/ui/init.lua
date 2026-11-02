-- The package manager window: state, rendering, keymaps and actions.
local checklist = require("nuget.ui.checklist")
local cli = require("nuget.cli")
local fast = require("nuget.fast")
local layout = require("nuget.ui.layout")
local model = require("nuget.model")
local plan = require("nuget.plan")
local registry = require("nuget.registry")
local semver = require("nuget.semver")
local solution = require("nuget.solution")
local view = require("nuget.ui.view")
local xml = require("nuget.xml")

local M = {}

local TABS = { "browse", "installed", "updates", "consolidate" }
local TAB_TITLES = { browse = "Browse", installed = "Installed", updates = "Updates", consolidate = "Consolidate" }
local SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

---@class NugetSearchState
---@field query string
---@field results NugetSearchResult[]
---@field loading boolean
---@field more boolean
---@field skip integer
---@field job NugetJob?

---@class NugetUiState
---@field config table
---@field target NugetTarget
---@field layout NugetLayout
---@field model NugetModel
---@field tab string
---@field loading table<string, boolean>
---@field jobs NugetJob[]
---@field filters table<string, string>
---@field marks table<string, true>
---@field search NugetSearchState
---@field prerelease boolean
---@field rows NugetLine[]
---@field meta NugetMetadata?
---@field meta_key string?
---@field busy string?
---@field restore_id string?
---@field hint_project string?
---@field augroup integer
---@field timer uv.uv_timer_t?
---@field debounce uv.uv_timer_t?
---@field problems_seen table<string, true>
local S

local uv = vim.uv or vim.loop

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "NuGet" })
end

local function is_open()
  return S ~= nil and layout.is_valid(S.layout)
end

--- Warn about problems once per session. A failing feed reports a different URL (with the query
--- in it) on every search, so its problems are keyed by the source name alone.
local function report_problems(problems)
  for _, p in ipairs(problems or {}) do
    local source = p:match("^([^:]+): Failed to retrieve")
    local key = source or p
    if not S.problems_seen[key] then
      S.problems_seen[key] = true
      notify(
        source and (source .. ": the feed could not be searched (credentials or network?)") or p,
        vim.log.levels.WARN
      )
    end
  end
end

--- Still waiting for a first answer about newer versions.
local function checking_updates()
  return S.loading.fast_latest or (S.loading.outdated and not S.model.loaded.fast_latest)
end

local function any_activity()
  return S.busy ~= nil or S.search.loading or next(S.loading) ~= nil
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function spinner()
  return SPINNER[math.floor(uv.hrtime() / 1e8) % #SPINNER + 1]
end

local HINTS = {
  browse = "/ search · ⏎ install · v version · ] more · o nuget.org · p prerelease · ? help · q close",
  installed = "/ filter · ⏎ actions · u update · v version · i add to projects · d remove · ? help · q close",
  updates = "␣ mark · u update · U update marked/all · v version · p prerelease · ? help · q close",
  consolidate = "⏎ consolidate · v pick version · / filter · ? help · q close",
}

local function render_header()
  local width = vim.api.nvim_win_get_width(S.layout.header.win)
  local b = view.builder()
  local m = S.model
  local counts = {
    browse = nil,
    installed = m.loaded.plain and #model.installed(m) or nil,
    updates = (m.loaded.outdated or m.loaded.fast_latest) and #model.updates(m) or nil,
    consolidate = m.loaded.plain and #model.inconsistent(m) or nil,
  }
  local chunks = { { " 󰏖 NuGet ", "NugetTitle" } }
  for i, tab in ipairs(TABS) do
    local count = counts[tab]
    local label = (" %d %s"):format(i, TAB_TITLES[tab])
    if count then
      label = label .. " " .. count
    elseif tab == "updates" and checking_updates() then
      label = label .. " " .. spinner()
    end
    label = label .. " "
    table.insert(
      chunks,
      { tab == S.tab and ("[" .. vim.trim(label) .. "]") or label, tab == S.tab and "NugetTabActive" or "NugetTab" }
    )
    table.insert(chunks, { " " })
  end

  local status
  if S.busy then
    status = { spinner() .. " " .. S.busy, "NugetBusy" }
  elseif S.loading.plain then
    status = { spinner() .. " loading packages", "NugetBusy" }
  elseif next(S.loading) then
    local what = {}
    if checking_updates() then
      table.insert(what, "updates")
    end
    if S.loading.fast_vulnerable or S.loading.vulnerable then
      table.insert(what, "vulnerabilities")
    end
    if S.loading.fast_deprecated or S.loading.deprecated then
      table.insert(what, "deprecations")
    end
    if #what > 0 then
      status = { spinner() .. " checking " .. table.concat(what, ", "), "NugetBusy" }
    else
      -- Only the dotnet report is left: it adds private feeds and confirms the rest
      status = { spinner() .. " verifying versions with dotnet", "NugetMuted" }
    end
  end
  local used = 0
  for _, c in ipairs(chunks) do
    used = used + vim.fn.strdisplaywidth(c[1])
  end
  -- The status gets what is left between the tabs and the solution name, cut to fit
  local fixed = vim.fn.strdisplaywidth(S.target.name .. (S.prerelease and "  +prerelease" or "") .. " ")
  if status then
    local room = width - used - fixed - 3
    if room < 8 then
      status = nil
    elseif vim.fn.strdisplaywidth(status[1]) > room then
      status[1] = view.fit(status[1], room)
    end
  end
  local right = (status and (status[1] .. "  ") or "")
    .. S.target.name
    .. (S.prerelease and "  +prerelease" or "")
    .. " "
  table.insert(chunks, { string.rep(" ", math.max(width - used - vim.fn.strdisplaywidth(right), 1)) })
  if status then
    table.insert(chunks, { status[1] .. "  ", status[2] })
  end
  table.insert(chunks, { S.target.name, "NugetMuted" })
  if S.prerelease then
    table.insert(chunks, { "  +prerelease", "NugetUpdate" })
  end
  b:add(chunks)
  b:add({ { " " .. HINTS[S.tab], "NugetMuted" } })
  layout.set(S.layout.header.buf, b.lines)
end

local function current_item()
  local row = vim.api.nvim_win_get_cursor(S.layout.list.win)[1]
  local line = S.rows[row]
  return line and line.item
end

local function render_details()
  if not is_open() then
    return
  end
  local item = current_item()
  local id, version = view.detail_version(item)
  local key = id and version and (id .. "@" .. version):lower()
  if key ~= S.meta_key then
    S.meta_key = key
    S.meta = nil
    if key and S.config.details.fetch then
      registry.fetch(id, version, function(meta)
        if is_open() and S.meta_key == key then
          S.meta = meta or false
          render_details()
        end
      end)
    end
  end
  local width = vim.api.nvim_win_get_width(S.layout.details.win) - 1
  local lines = view.details(item, {
    model = S.model,
    icons = S.config.icons,
    meta = S.meta or nil,
    meta_loading = S.meta == nil and key ~= nil and S.config.details.fetch,
  }, width)
  layout.set(S.layout.details.buf, lines)
end

local function render_list()
  local win = S.layout.list.win
  local width = vim.api.nvim_win_get_width(win)
  local previous = current_item()
  local previous_id = S.restore_id
    or (previous and (previous.kind == "search" and previous.result.id or previous.package.id))
  S.rows = view.list({
    tab = S.tab,
    model = S.model,
    loading = S.loading,
    filter = S.filters[S.tab] or "",
    marks = S.marks,
    search = S.search,
    icons = S.config.icons,
  }, width)
  layout.set(S.layout.list.buf, S.rows)

  -- Keep the cursor on the same package across re-renders
  local target_row
  if previous_id then
    for i, line in ipairs(S.rows) do
      local item = line.item
      local id = item and (item.kind == "search" and item.result.id or item.package.id)
      if id and id:lower() == previous_id:lower() then
        target_row = i
        break
      end
    end
  end
  local row = target_row or math.min(vim.api.nvim_win_get_cursor(win)[1], #S.rows)
  vim.api.nvim_win_set_cursor(win, { math.max(row, 1), 0 })
  if target_row then
    S.restore_id = nil
  end
end

local function render()
  if not is_open() then
    return
  end
  render_header()
  render_list()
  render_details()
  layout.set_title(S.layout.input.win, S.tab == "browse" and "Search" or "Filter")
end

local function sync_timer()
  if any_activity() and not S.timer then
    S.timer = uv.new_timer()
    S.timer:start(
      100,
      100,
      vim.schedule_wrap(function()
        if is_open() then
          render_header()
        end
      end)
    )
  elseif not any_activity() and S.timer then
    S.timer:stop()
    S.timer:close()
    S.timer = nil
  end
end

---------------------------------------------------------------------------
-- Loading
---------------------------------------------------------------------------

local function kill_jobs()
  for _, job in ipairs(S.jobs) do
    job.kill()
  end
  for _, c in ipairs(S.cancels or {}) do
    c.cancel()
  end
  S.jobs = {}
  S.cancels = {}
end

--- (Re)load everything: the plain list first (fast, fills the tabs), then the network
--- checks in parallel.
--- Whether nuget.org can answer the quick checks: curl is there and nuget.org is a source.
local function fast_enabled()
  if not S.config.fast or vim.fn.executable("curl") ~= 1 then
    return false
  end
  local sources = S.config.sources
  if not sources then
    return true
  end
  return vim.iter(sources):any(function(s)
    return s:lower():find("nuget.org", 1, true) ~= nil
  end)
end

--- Throttled render, for the many small results of the quick checks.
local pending_render = false
local function render_soon()
  if pending_render then
    return
  end
  pending_render = true
  vim.defer_fn(function()
    pending_render = false
    if is_open() then
      render()
    end
  end, 150)
end

--- nuget.org quick checks over the packages of the plain report: latest versions,
--- vulnerabilities of every resolved version (direct and transitive), deprecations.
---@param generation integer
---@param m NugetModel the model being filled
---@param on_complete fun() once all three checks are in
local function quick_checks(generation, m, on_complete)
  local function current()
    return is_open() and S.generation == generation
  end
  local pending = 3
  local function finish_one()
    pending = pending - 1
    if pending == 0 then
      on_complete()
    end
  end
  local direct = model.installed(m)
  local ids = vim.tbl_map(function(pkg)
    return pkg.id
  end, direct)
  local concurrency = S.config.fast_concurrency

  S.loading.fast_latest = true
  table.insert(
    S.cancels,
    fast.latest(ids, { prerelease = S.prerelease, concurrency = concurrency }, function(id, latest)
      if current() then
        model.hint_latest(m, id, latest)
        render_soon()
      end
    end, function()
      if current() then
        m.loaded.fast_latest = true
        S.loading.fast_latest = nil
        finish_one()
        sync_timer()
        render()
      end
    end)
  )

  S.loading.fast_vulnerable = true
  fast.advisories(function(db)
    if not current() then
      return
    end
    if db then
      for _, pkg in pairs(m.packages) do
        for _, r in ipairs(model.resolutions(pkg)) do
          model.add_vulnerabilities(m, pkg.id, r.project, fast.vulnerabilities_of(db, pkg.id, r.version))
        end
      end
      m.loaded.vulnerable = true
    else
      report_problems({ "Could not download the nuget.org vulnerability database" })
    end
    S.loading.fast_vulnerable = nil
    finish_one()
    sync_timer()
    render()
  end)

  -- One request pair per distinct installed version
  local versions = {}
  for _, pkg in ipairs(direct) do
    for _, v in ipairs(model.versions(pkg)) do
      table.insert(versions, { id = pkg.id, version = v })
    end
  end
  S.loading.fast_deprecated = true
  table.insert(
    S.cancels,
    fast.each_limited(versions, concurrency, function(entry, done)
      registry.fetch(entry.id, entry.version, function(meta)
        if current() and meta and meta.deprecation then
          model.set_deprecation(m, entry.id, meta.deprecation)
          render_soon()
        end
        done()
      end)
    end, function()
      if current() then
        m.loaded.deprecated = true
        S.loading.fast_deprecated = nil
        finish_one()
        sync_timer()
        render()
      end
    end)
  )
end

--- (Re)load everything. The package list comes first (with transitive packages, which costs
--- little and lets vulnerabilities be checked everywhere); quick nuget.org checks follow it,
--- while the slow dotnet reports run in the background and have the last word.
local function load()
  kill_jobs()
  solution.clear_cache()
  S.generation = (S.generation or 0) + 1
  local generation = S.generation
  -- The new model is filled on the side: until its package list is in, the window keeps
  -- showing the previous one instead of going blank for the seconds a reload takes
  local fresh = model.new()
  S.stale = true
  local fast_ok = fast_enabled()
  -- Without the quick checks, the dotnet reports are the only source
  local verify = vim.tbl_extend("force", {}, S.config.verify)
  if not fast_ok then
    verify = { outdated = true, vulnerable = true, deprecated = true }
  end
  S.loading = { plain = true }
  for kind, on in pairs(verify) do
    if on then
      S.loading[kind] = true
    end
  end
  sync_timer()
  render()
  local opts = { prerelease = S.prerelease, sources = S.config.sources }
  local function done(kind, then_fn)
    return function(report)
      if not is_open() or S.generation ~= generation then
        return
      end
      model.apply(fresh, kind == "plain" and "transitive" or kind, report)
      if kind == "plain" then
        fresh.loaded.plain = true
      end
      S.loading[kind] = nil
      report_problems(report.problems)
      if then_fn then
        then_fn()
      end
      sync_timer()
      render()
    end
  end
  -- The dotnet reports start only once the package list is in: running them alongside it
  -- slows the list down tenfold on a large solution, and the list is what fills the window.
  table.insert(
    S.jobs,
    cli.list(
      S.target,
      "transitive",
      opts,
      done("plain", function()
        -- Show the new model once it knows as much as the one on screen: with the quick checks,
        -- after them, or the Updates tab would empty for a moment and lose the cursor
        if fast_ok then
          quick_checks(generation, fresh, function()
            S.model, S.stale = fresh, false
            render()
          end)
        else
          S.model, S.stale = fresh, false
        end
        for _, kind in ipairs({ "outdated", "vulnerable", "deprecated" }) do
          if verify[kind] then
            table.insert(S.jobs, cli.list(S.target, kind, opts, done(kind)))
          end
        end
      end)
    )
  )
end

local function search(append)
  local query = vim.trim(S.search.query)
  if S.search.job then
    S.search.job.kill()
    S.search.job = nil
  end
  if not append then
    S.search.results = {}
    S.search.skip = 0
    S.search.more = false
  end
  if query == "" then
    S.search.loading = false
    sync_timer()
    render()
    return
  end
  S.search.loading = true
  sync_timer()
  render()
  local take = S.config.search.take
  S.search.job = cli.search(query, {
    take = take,
    skip = S.search.skip,
    prerelease = S.prerelease,
    sources = S.config.sources,
    cwd = vim.fs.dirname(S.target.path),
  }, function(results, problems)
    if not is_open() then
      return
    end
    S.search.job = nil
    S.search.loading = false
    vim.list_extend(S.search.results, results)
    S.search.skip = S.search.skip + take
    S.search.more = #results >= take
    report_problems(problems)
    sync_timer()
    render()
  end)
end

---------------------------------------------------------------------------
-- Operations
---------------------------------------------------------------------------

---@class NugetOp
---@field label string
---@field run fun(cb: fun(ok: boolean, message: string))

--- Run write operations one at a time, then reload.
---@param ops NugetOp[]
---@param summary string
local function run_ops(ops, summary)
  if #ops == 0 then
    return
  end
  local failures = {}
  local i = 0
  local function step()
    i = i + 1
    local op = ops[i]
    if not op then
      S.busy = nil
      sync_timer()
      -- dotnet rewrote project and props files: buffers showing them should show the new text
      pcall(vim.cmd.checktime)
      if #failures == 0 then
        notify(summary)
      else
        notify(table.concat(failures, "\n"), vim.log.levels.ERROR)
      end
      if is_open() then
        load()
      end
      return
    end
    S.busy = #ops > 1 and ("%s (%d/%d)"):format(op.label, i, #ops) or op.label
    if is_open() then
      render_header()
    end
    op.run(function(ok, message)
      if not ok then
        table.insert(failures, op.label .. ": " .. message)
      end
      step()
    end)
  end
  sync_timer()
  step()
end

local function busy_guard()
  if S.busy then
    notify("Wait for the current operation to finish", vim.log.levels.WARN)
    return true
  end
  -- During a reload the list still shows the previous state; acting on it could use stale versions
  if S.stale and S.model.loaded.plain then
    notify("Wait for the package list to reload", vim.log.levels.WARN)
    return true
  end
  return false
end

--- Edit a shared file in place (what `dotnet add` / `remove` refuse to do).
---@param step NugetStep
---@param cb fun(ok: boolean, message: string)
local function edit_file(step, cb)
  local text = xml.read(step.file)
  if not text then
    return cb(false, "cannot read " .. step.file)
  end
  local new, err
  if step.kind == "edit" then
    new, err = xml.set_version(text, step.tag, step.id, step.attr, step.version)
  else
    new, err = xml.remove(text, step.tag, step.id)
  end
  if not new then
    return cb(false, err)
  end
  local ok, werr = xml.write(step.file, new)
  cb(ok, ok and "" or tostring(werr))
end

--- Operations for planned steps, plus a restore when a shared file was edited by hand, so the
--- reload that follows sees the new versions.
---@param steps NugetStep[]
---@return NugetOp[]
local function step_ops(steps)
  local ops = {}
  for _, step in ipairs(steps) do
    table.insert(ops, {
      label = step.label,
      run = function(cb)
        if step.kind == "add" then
          cli.add(step.project, step.id, step.version, cb)
        elseif step.kind == "remove" then
          cli.remove(step.project, step.id, cb)
        else
          edit_file(step, cb)
        end
      end,
    })
  end
  if plan.needs_restore(steps) then
    local paths = S.target.kind == "solution" and { S.target.path } or S.target.projects or {}
    for _, path in ipairs(paths) do
      table.insert(ops, {
        label = "Restoring " .. vim.fn.fnamemodify(path, ":t"),
        run = function(cb)
          cli.restore(path, cb)
        end,
      })
    end
  end
  return ops
end

--- Run the steps, asking first when they change projects that were not picked: a version in
--- Directory.Build.props or Directory.Packages.props applies to every project using it.
---@param steps NugetStep[]
---@param picked string[]
---@param summary string
local function run_steps(steps, picked, summary)
  if #steps == 0 then
    return
  end
  local also = plan.also_affected(steps, picked)
  if #also == 0 then
    return run_ops(step_ops(steps), summary)
  end
  local names = vim.tbl_map(solution.project_name, also)
  local shown = #names > 6 and (table.concat(vim.list_slice(names, 1, 6), ", ") .. (", and %d more"):format(#names - 6))
    or table.concat(names, ", ")
  local yes = "Change all of them"
  vim.ui.select({ yes, "Cancel" }, {
    prompt = ("The version is shared: this also changes %s"):format(shown),
  }, function(choice)
    if choice == yes then
      run_ops(step_ops(steps), summary)
    end
  end)
end

local function versions_of(id, cb)
  notify("Fetching versions of " .. id .. "…")
  cli.versions(
    id,
    { prerelease = S.prerelease, sources = S.config.sources, cwd = vim.fs.dirname(S.target.path) },
    function(versions, problems)
      report_problems(problems)
      if #versions == 0 then
        notify("No versions found for " .. id, vim.log.levels.WARN)
        return
      end
      cb(versions)
    end
  )
end

--- Ask for a version of `id`; installed and latest ones are labelled.
local function pick_version(id, cb)
  versions_of(id, function(versions)
    local pkg = S.model.packages[id:lower()]
    local installed = pkg and model.versions(pkg) or {}
    local latest = semver.max(versions, S.prerelease)
    vim.ui.select(versions, {
      prompt = id .. " version",
      format_item = function(v)
        local tags = {}
        if v == latest then
          table.insert(tags, "latest")
        end
        if vim.tbl_contains(installed, v) then
          table.insert(tags, "installed")
        end
        if semver.is_prerelease(v) then
          table.insert(tags, "prerelease")
        end
        return #tags > 0 and (v .. "  (" .. table.concat(tags, ", ") .. ")") or v
      end,
    }, function(choice)
      if choice then
        cb(choice)
      end
    end)
  end)
end

local function pick_projects(title, preselect, current, cb)
  local items = {}
  for _, path in ipairs(S.model.projects) do
    table.insert(items, {
      label = solution.project_name(path),
      detail = current and current[path] or nil,
      checked = preselect[path] == true,
      value = path,
    })
  end
  if #items == 0 then
    notify("No projects found", vim.log.levels.WARN)
    return
  end
  checklist.open(title, items, function(values)
    if values and #values > 0 then
      cb(values)
    end
  end, { border = S.config.window.border })
end

local function install(id, version)
  local pkg = S.model.packages[id:lower()]
  local current, preselect = {}, {}
  if pkg then
    for path, ref in pairs(pkg.projects) do
      current[path] = semver.effective(ref.requested, ref.resolved)
    end
    -- A vulnerable transitive package is fixed in the projects that pull it in
    for path in pairs(pkg.transitive) do
      preselect[path] = true
      current[path] = (current[path] or pkg.transitive[path]) .. " transitive"
    end
  end
  if S.hint_project then
    preselect[S.hint_project] = true
  end
  pick_projects(("Install %s %s"):format(id, version), preselect, current, function(projects)
    local ops = {}
    for _, project in ipairs(projects) do
      table.insert(ops, {
        label = ("Installing %s %s in %s"):format(id, version, solution.project_name(project)),
        run = function(cb)
          cli.add(project, id, version, cb)
        end,
      })
    end
    S.restore_id = id
    run_ops(ops, ("Installed %s %s in %d project%s"):format(id, version, #projects, #projects == 1 and "" or "s"))
  end)
end

--- Install the newest version. Transitive packages have no `latest` from the outdated report,
--- and their resolved version is the vulnerable one, so ask the feeds.
local function install_latest(id)
  local pkg = S.model.packages[id:lower()]
  if pkg and pkg.latest then
    return install(id, pkg.latest)
  end
  versions_of(id, function(versions)
    local latest = semver.max(versions, S.prerelease) or versions[1]
    install(id, latest)
  end)
end

local function update(pkg, version)
  local projects = model.projects_below(pkg, version)
  if #projects == 0 then
    notify(pkg.id .. " is already at " .. version .. " or newer everywhere")
    return
  end
  S.restore_id = pkg.id
  run_steps(plan.set_version(pkg, version, projects), projects, ("Updated %s to %s"):format(pkg.id, version))
end

--- Where a project's version is written, for the checklists: nothing for the project itself.
---@param ref NugetProjectRef
---@return string
local function origin_note(ref)
  local o = ref.origin
  if not o or o.kind == "project" or o.kind == "unknown" then
    return ""
  elseif o.kind == "override" then
    return "  VersionOverride"
  end
  return "  " .. vim.fn.fnamemodify(o.file or "", ":t") .. (o.kind == "global" and " (global)" or "")
end

--- Checklist of the projects referencing `pkg`, with their version and where it is written.
local function pick_referencing(title, pkg, preselect, cb)
  local items = {}
  for _, path in ipairs(model.project_paths(pkg)) do
    local ref = pkg.projects[path]
    table.insert(items, {
      label = solution.project_name(path),
      detail = (semver.effective(ref.requested, ref.resolved) or "?") .. origin_note(ref),
      checked = preselect(path, ref),
      value = path,
    })
  end
  checklist.open(title, items, function(projects)
    if projects and #projects > 0 then
      cb(projects)
    end
  end, { border = S.config.window.border })
end

--- Set `pkg` to exactly `version` in the chosen projects (up or down).
local function set_version(pkg, version)
  pick_referencing(("%s → %s"):format(pkg.id, version), pkg, function(_, ref)
    return semver.effective(ref.requested, ref.resolved) ~= version
  end, function(projects)
    S.restore_id = pkg.id
    run_steps(plan.set_version(pkg, version, projects), projects, ("Set %s to %s"):format(pkg.id, version))
  end)
end

local function remove(pkg)
  pick_referencing("Remove " .. pkg.id .. " from", pkg, function()
    return true
  end, function(projects)
    run_steps(
      plan.remove(pkg, projects),
      projects,
      ("Removed %s from %d project%s"):format(pkg.id, #projects, #projects == 1 and "" or "s")
    )
  end)
end

local function consolidate(pkg, version)
  local function apply(v)
    local projects = {}
    for _, path in ipairs(model.project_paths(pkg)) do
      local ref = pkg.projects[path]
      if semver.effective(ref.requested, ref.resolved) ~= v then
        table.insert(projects, path)
      end
    end
    S.restore_id = pkg.id
    run_steps(plan.set_version(pkg, v, projects), projects, ("Consolidated %s on %s"):format(pkg.id, v))
  end
  if version then
    return apply(version)
  end
  local choices = model.versions(pkg)
  if pkg.latest and not vim.tbl_contains(choices, pkg.latest) then
    table.insert(choices, 1, pkg.latest)
  end
  vim.ui.select(choices, {
    prompt = "Consolidate " .. pkg.id .. " on",
    format_item = function(v)
      return v == pkg.latest and (v .. "  (latest)") or v
    end,
  }, function(choice)
    if choice then
      apply(choice)
    end
  end)
end

---------------------------------------------------------------------------
-- Keymap handlers
---------------------------------------------------------------------------

local actions = {}

function actions.switch(tab)
  return function()
    S.tab = tab
    vim.bo[S.layout.input.buf].modifiable = true
    local text = tab == "browse" and S.search.query or (S.filters[tab] or "")
    vim.api.nvim_buf_set_lines(S.layout.input.buf, 0, -1, false, { text })
    -- A new tab starts at its top. Without forgetting the old rows, the render would keep the
    -- cursor on the package it was on in the previous tab, and the next key would act there.
    S.rows = {}
    S.restore_id = nil
    vim.api.nvim_win_set_cursor(S.layout.list.win, { 1, 0 })
    render()
  end
end

function actions.cycle(step)
  return function()
    local index = 1
    for i, tab in ipairs(TABS) do
      if tab == S.tab then
        index = i
      end
    end
    actions.switch(TABS[(index - 1 + step) % #TABS + 1])()
  end
end

function actions.focus_input()
  vim.api.nvim_set_current_win(S.layout.input.win)
  vim.cmd("startinsert!")
end

function actions.primary()
  if busy_guard() then
    return
  end
  local item = current_item()
  if not item then
    return
  end
  if item.kind == "search" then
    return install(item.result.id, item.result.version)
  end
  local pkg = item.package
  if not model.is_direct(pkg) then
    return install_latest(pkg.id)
  end
  if S.tab == "updates" then
    return update(pkg, pkg.latest)
  elseif S.tab == "consolidate" then
    return consolidate(pkg)
  end
  -- Installed: offer what makes sense for this package
  local menu = {}
  if pkg.latest and model.has_update(pkg) then
    table.insert(menu, {
      "Update to " .. pkg.latest,
      function()
        update(pkg, pkg.latest)
      end,
    })
  end
  table.insert(menu, { "Choose version…", actions.version })
  if model.is_inconsistent(pkg) then
    table.insert(menu, {
      "Consolidate versions…",
      function()
        consolidate(pkg)
      end,
    })
  end
  table.insert(menu, {
    "Install in more projects…",
    function()
      install(pkg.id, model.versions(pkg)[1])
    end,
  })
  table.insert(menu, {
    "Remove…",
    function()
      remove(pkg)
    end,
  })
  table.insert(menu, { "Open on nuget.org", actions.open_gallery })
  if #pkg.vulnerabilities > 0 then
    table.insert(menu, { "Open advisory", actions.open_advisory })
  end
  vim.ui.select(menu, {
    prompt = pkg.id,
    format_item = function(entry)
      return entry[1]
    end,
  }, function(choice)
    if choice then
      choice[2]()
    end
  end)
end

function actions.update()
  if busy_guard() then
    return
  end
  local item = current_item()
  if not item or item.kind ~= "package" or not model.is_direct(item.package) then
    return
  end
  local pkg = item.package
  if not pkg.latest then
    notify(checking_updates() and "Still checking for updates…" or (pkg.id .. " is up to date"))
    return
  end
  update(pkg, pkg.latest)
end

function actions.update_all()
  if busy_guard() then
    return
  end
  local list = model.updates(S.model)
  local marked = vim.tbl_filter(function(pkg)
    return S.marks[pkg.id:lower()]
  end, list)
  local targets = #marked > 0 and marked or list
  if #targets == 0 then
    notify(checking_updates() and "Still checking for updates…" or "Everything is up to date")
    return
  end
  local label = ("Update %d package%s"):format(#targets, #targets == 1 and "" or "s")
  vim.ui.select({ label, "Cancel" }, {
    prompt = table.concat(
      vim.tbl_map(function(p)
        return p.id .. " → " .. p.latest
      end, targets),
      ", "
    ),
  }, function(choice)
    if choice ~= label then
      return
    end
    -- One combined list, so a restore after shared-file edits happens once at the end
    local steps = {}
    for _, pkg in ipairs(targets) do
      vim.list_extend(steps, plan.set_version(pkg, pkg.latest, model.projects_below(pkg, pkg.latest)))
    end
    S.marks = {}
    run_ops(step_ops(steps), ("Updated %d package%s"):format(#targets, #targets == 1 and "" or "s"))
  end)
end

function actions.version()
  if busy_guard() then
    return
  end
  local item = current_item()
  if not item then
    return
  end
  if item.kind == "search" then
    return pick_version(item.result.id, function(v)
      install(item.result.id, v)
    end)
  end
  local pkg = item.package
  pick_version(pkg.id, function(v)
    if model.is_direct(pkg) then
      if S.tab == "consolidate" then
        consolidate(pkg, v)
      else
        set_version(pkg, v)
      end
    else
      install(pkg.id, v)
    end
  end)
end

function actions.install()
  if busy_guard() then
    return
  end
  local item = current_item()
  if not item then
    return
  end
  if item.kind == "search" then
    return install(item.result.id, item.result.version)
  end
  local pkg = item.package
  if model.is_direct(pkg) then
    -- Adding to more projects: keep the version the others already use
    return install(pkg.id, model.versions(pkg)[1])
  end
  install_latest(pkg.id)
end

function actions.remove()
  if busy_guard() then
    return
  end
  local item = current_item()
  if item and item.kind == "package" and model.is_direct(item.package) then
    remove(item.package)
  end
end

function actions.mark()
  local item = current_item()
  if S.tab ~= "updates" or not item or item.kind ~= "package" then
    return
  end
  local key = item.package.id:lower()
  S.marks[key] = not S.marks[key] or nil
  render_list()
  local row = vim.api.nvim_win_get_cursor(S.layout.list.win)[1]
  if row < #S.rows then
    vim.api.nvim_win_set_cursor(S.layout.list.win, { row + 1, 0 })
  end
end

function actions.prerelease()
  S.prerelease = not S.prerelease
  notify("Prerelease versions " .. (S.prerelease and "included" or "excluded"))
  load()
  if S.search.query ~= "" then
    search(false)
  end
end

function actions.refresh()
  registry.clear_cache()
  load()
end

function actions.more()
  if S.tab == "browse" and S.search.more and not S.search.loading then
    search(true)
  end
end

local function item_id()
  local item = current_item()
  return item and (item.kind == "search" and item.result.id or item.package.id)
end

function actions.open_gallery()
  local id = item_id()
  if id then
    vim.ui.open(registry.gallery_url(id))
  end
end

function actions.open_project()
  local item = current_item()
  local url = (S.meta and S.meta.project_url) or (item and item.kind == "search" and item.result.project_url)
  if url then
    vim.ui.open(url)
  else
    notify("No project URL for this package", vim.log.levels.WARN)
  end
end

function actions.open_advisory()
  local item = current_item()
  local pkg = item and (item.kind == "search" and S.model.packages[item.result.id:lower()] or item.package)
  if pkg and #pkg.vulnerabilities > 0 then
    vim.ui.open(pkg.vulnerabilities[1].url)
  else
    notify("No known vulnerabilities", vim.log.levels.INFO)
  end
end

function actions.help()
  local lines = {
    "Tabs        1-4 · <Tab> / <S-Tab>",
    "Search      /   (Browse: search NuGet, other tabs: filter)",
    "",
    "⏎           install / actions / update / consolidate",
    "i           install in projects (Browse, or add to more projects)",
    "u           update to the latest version",
    "U           update the marked packages, or all of them (Updates)",
    "␣           mark for U (Updates)",
    "v           pick a version",
    "d           remove from projects",
    "",
    "]           load more search results",
    "p           include / exclude prerelease versions",
    "r           refresh",
    "o / O / a   open on nuget.org / project site / advisory",
    "J / K       scroll the details down / up",
    "q / <Esc>   close",
  }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - #lines) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width + 2,
    height = #lines,
    border = S.config.window.border,
    style = "minimal",
    title = " NuGet keys ",
    title_pos = "center",
    zindex = 70,
  })
  for _, lhs in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", lhs, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true })
  end
end

--- Scroll the details pane by half its height without leaving the list.
function actions.scroll_details(direction)
  return function()
    local win = S.layout.details.win
    local lines = math.max(math.floor(vim.api.nvim_win_get_height(win) / 2), 1)
    vim.api.nvim_win_call(win, function()
      -- <C-e> / <C-y>
      vim.cmd("normal! " .. lines .. (direction > 0 and "\5" or "\25"))
    end)
  end
end

---------------------------------------------------------------------------
-- Window lifecycle
---------------------------------------------------------------------------

function M.close()
  if not S then
    return
  end
  local state = S
  S = nil
  for _, job in ipairs(state.jobs) do
    job.kill()
  end
  if state.search.job then
    state.search.job.kill()
  end
  for _, t in ipairs({ state.timer, state.debounce }) do
    if t then
      t:stop()
      t:close()
    end
  end
  pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  layout.close(state.layout)
end

local function set_keymaps()
  local function map(bufs, lhs, fn)
    for _, buf in ipairs(bufs) do
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
    end
  end
  local main = { S.layout.list.buf, S.layout.details.buf, S.layout.header.buf }
  for i, tab in ipairs(TABS) do
    map(main, tostring(i), actions.switch(tab))
  end
  map(main, "<Tab>", actions.cycle(1))
  map(main, "<S-Tab>", actions.cycle(-1))
  map(main, "q", M.close)
  map(main, "<Esc>", M.close)
  map(main, "?", actions.help)
  map(main, "/", actions.focus_input)
  map(main, "r", actions.refresh)
  map(main, "p", actions.prerelease)

  local list = { S.layout.list.buf }
  map(list, "<CR>", actions.primary)
  map(list, "i", actions.install)
  map(list, "u", actions.update)
  map(list, "U", actions.update_all)
  map(list, "v", actions.version)
  map(list, "d", actions.remove)
  map(list, "<Space>", actions.mark)
  map(list, "]", actions.more)
  map(list, "o", actions.open_gallery)
  map(list, "O", actions.open_project)
  map(list, "a", actions.open_advisory)
  map(list, "J", actions.scroll_details(1))
  map(list, "K", actions.scroll_details(-1))

  -- The input line: typing searches (Browse) or filters (other tabs)
  local input = S.layout.input.buf
  local function leave_input()
    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(S.layout.list.win)
  end
  for _, mode in ipairs({ "i", "n" }) do
    vim.keymap.set(mode, "<CR>", leave_input, { buffer = input })
    vim.keymap.set(mode, "<Down>", leave_input, { buffer = input })
    vim.keymap.set(mode, "<C-n>", leave_input, { buffer = input })
  end
  vim.keymap.set("i", "<Esc>", leave_input, { buffer = input })
  vim.keymap.set("n", "<Esc>", leave_input, { buffer = input })
  vim.keymap.set("n", "q", M.close, { buffer = input })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = S.augroup,
    buffer = input,
    callback = function()
      local text = vim.trim(table.concat(vim.api.nvim_buf_get_lines(input, 0, -1, false), " "))
      if S.tab ~= "browse" then
        S.filters[S.tab] = text
        render_list()
        render_details()
        return
      end
      if text == S.search.query then
        return
      end
      S.search.query = text
      S.debounce = S.debounce or uv.new_timer()
      S.debounce:stop()
      S.debounce:start(
        S.config.search.debounce,
        0,
        vim.schedule_wrap(function()
          if is_open() then
            search(false)
          end
        end)
      )
    end,
  })
end

local function set_autocmds()
  local wins = {}
  for _, name in ipairs({ "header", "input", "list", "details" }) do
    wins[tostring(S.layout[name].win)] = true
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    group = S.augroup,
    callback = function(ev)
      if wins[ev.match] then
        vim.schedule(M.close)
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = S.augroup,
    callback = function()
      if is_open() then
        layout.resize(S.layout, S.config.window)
        render()
      end
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = S.augroup,
    buffer = S.layout.list.buf,
    callback = render_details,
  })
  -- Focus wandering into the header goes to the list instead
  vim.api.nvim_create_autocmd("WinEnter", {
    group = S.augroup,
    callback = function()
      if is_open() and vim.api.nvim_get_current_win() == S.layout.header.win then
        vim.api.nvim_set_current_win(S.layout.list.win)
      end
    end,
  })
end

---@param config table
---@param target NugetTarget
---@param opts {tab: string?, query: string?, project: string?}
function M.open(config, target, opts)
  if is_open() then
    if S.target.path == target.path then
      vim.api.nvim_set_current_win(S.layout.list.win)
      if opts.tab then
        actions.switch(opts.tab)()
      end
      if opts.query then
        M.set_query(opts.query)
      end
      return
    end
    M.close()
  end

  S = {
    config = config,
    target = target,
    layout = layout.open(config.window),
    model = model.new(),
    tab = opts.tab or config.default_tab,
    loading = {},
    jobs = {},
    cancels = {},
    filters = {},
    marks = {},
    search = { query = "", results = {}, loading = false, more = false, skip = 0 },
    prerelease = config.prerelease,
    rows = {},
    hint_project = opts.project and vim.fs.normalize(vim.fn.fnamemodify(opts.project, ":p")) or nil,
    augroup = vim.api.nvim_create_augroup("nuget_ui", { clear = true }),
    problems_seen = {},
  }
  set_keymaps()
  set_autocmds()
  actions.switch(S.tab)()
  load()
  if opts.query and opts.query ~= "" then
    M.set_query(opts.query)
  end
end

--- Search NuGet from the Browse tab, as if `query` had been typed.
---@param query string
function M.set_query(query)
  if not is_open() then
    return
  end
  if S.tab ~= "browse" then
    actions.switch("browse")()
  end
  S.search.query = query
  vim.api.nvim_buf_set_lines(S.layout.input.buf, 0, -1, false, { query })
  search(false)
end

--- For tests and integrations: the live state, nil when closed.
function M.state()
  return S
end

M.actions = actions

return M
