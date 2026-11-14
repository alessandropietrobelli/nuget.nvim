-- Opens the real window against a fake dotnet that replays the fixtures.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")

local function fake_dotnet(dir)
  local script = dir .. "/dotnet"
  local fixtures = root .. "/fixtures"
  vim.fn.writefile({
    "#!/bin/sh",
    'case "$*" in',
    '  *--outdated*) cat "' .. fixtures .. '/list_outdated.json" ;;',
    '  *--vulnerable*) cat "' .. fixtures .. '/list_vulnerable.json" ;;',
    '  *--deprecated*) cat "' .. fixtures .. '/list_deprecated.json" ;;',
    '  "list "*) cat "' .. fixtures .. '/list_plain.json" ;;',
    '  "package search"*)',
    '    [ -f "' .. dir .. '/search_slow" ] && sleep 2',
    '    [ -f "' .. dir .. '/search_fails" ] && exit 1',
    '    cat "' .. fixtures .. '/search.json" ;;',
    '  "add "*) echo "$*" >> "' .. dir .. '/calls.log" ;;',
    "  *) exit 1 ;;",
    "esac",
  }, script)
  vim.fn.setfperm(script, "rwxr-xr-x")
  return script
end

describe("window", function()
  local dir, ui

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({}, dir .. "/A.sln")
    require("nuget.cli").cmd = fake_dotnet(dir)
    vim.o.columns, vim.o.lines = 140, 40
    require("nuget").setup({ solution = dir .. "/A.sln", details = { fetch = false }, fast = false })
    ui = require("nuget.ui")
  end)

  after_each(function()
    ui.close()
    vim.fn.delete(dir, "rf")
  end)

  local function wait_loaded()
    assert.is_true(vim.wait(10000, function()
      local s = ui.state()
      return s ~= nil and next(s.loading) == nil
    end, 20))
    return ui.state()
  end

  it("opens four windows that fit the editor and do not overlap", function()
    require("nuget").open()
    local s = wait_loaded()
    local boxes = {}
    for _, name in ipairs({ "header", "input", "list", "details" }) do
      local win = s.layout[name].win
      assert.is_true(vim.api.nvim_win_is_valid(win))
      local pos = vim.api.nvim_win_get_position(win)
      local box = {
        top = pos[1],
        left = pos[2],
        bottom = pos[1] + vim.api.nvim_win_get_height(win) + 1,
        right = pos[2] + vim.api.nvim_win_get_width(win) + 1,
      }
      assert.is_true(box.right < vim.o.columns and box.bottom < vim.o.lines, name)
      boxes[name] = box
    end
    for a, ba in pairs(boxes) do
      for b, bb in pairs(boxes) do
        if a < b then
          local overlap = ba.left <= bb.right and bb.left <= ba.right and ba.top <= bb.bottom and bb.top <= ba.bottom
          -- Borders may touch, contents may not
          if overlap then
            assert.is_true(
              ba.bottom == bb.top - 1 or bb.bottom == ba.top - 1 or ba.right == bb.left - 1 or bb.right == ba.left - 1,
              a .. "/" .. b
            )
          end
        end
      end
    end
  end)

  it("fills the tabs from the reports", function()
    require("nuget").open()
    local s = wait_loaded()
    local header = vim.api.nvim_buf_get_lines(s.layout.header.buf, 0, 1, false)[1]
    assert.matches("%[2 Installed 3%]", header)
    assert.matches("3 Updates 2", header)
    assert.matches("4 Consolidate 2", header)
    assert.equals(3, #vim.tbl_filter(function(l)
      return l.item ~= nil
    end, s.rows))
  end)

  it("switches tabs and closes all windows together", function()
    require("nuget").open()
    local s = wait_loaded()
    ui.actions.switch("updates")()
    assert.matches("^○ Newtonsoft%.Json", vim.api.nvim_buf_get_lines(s.layout.list.buf, 0, 1, false)[1])
    local wins = { s.layout.header.win, s.layout.list.win, s.layout.details.win, s.layout.input.win }
    vim.api.nvim_win_close(s.layout.details.win, true)
    vim.wait(500, function()
      return ui.state() == nil
    end, 10)
    for _, win in ipairs(wins) do
      assert.is_false(vim.api.nvim_win_is_valid(win))
    end
  end)

  it("starts a tab at its top, not on the package the previous tab was on", function()
    require("nuget").open()
    local s = wait_loaded()
    -- Serilog is the last installed package and the second update
    vim.api.nvim_win_set_cursor(s.layout.list.win, { 3, 0 })
    ui.actions.switch("updates")()
    assert.equals(1, vim.api.nvim_win_get_cursor(s.layout.list.win)[1])
    assert.matches("Newtonsoft%.Json", vim.api.nvim_get_current_line())
  end)

  it("keeps showing the packages while it reloads", function()
    require("nuget").open()
    local s = wait_loaded()
    local before = vim.api.nvim_buf_get_lines(s.layout.list.buf, 0, -1, false)
    ui.actions.refresh()
    -- The reload has started but its list is not in yet
    assert.is_true(s.loading.plain)
    assert.same(before, vim.api.nvim_buf_get_lines(s.layout.list.buf, 0, -1, false))
    wait_loaded()
    assert.same(before, vim.api.nvim_buf_get_lines(s.layout.list.buf, 0, -1, false))
  end)

  local function current_id(s)
    local row = vim.api.nvim_win_get_cursor(s.layout.list.win)[1]
    local item = s.rows[row] and s.rows[row].item
    return item and item.package and item.package.id
  end

  it("opens on a package", function()
    require("nuget").open({ package = "Serilog" })
    local s = wait_loaded()
    assert.equals("installed", s.tab)
    assert.equals("Serilog", current_id(s))
  end)

  it("moves to a package and takes the project hint when it is already open", function()
    require("nuget").open()
    local s = wait_loaded()
    require("nuget").open({ package = "Microsoft.Azure.Storage.Blob", project = dir .. "/Api/Api.csproj" })
    assert.equals("Microsoft.Azure.Storage.Blob", current_id(s))
    assert.equals(vim.fs.normalize(dir .. "/Api/Api.csproj"), s.hint_project)
  end)

  it("tells other plugins when packages changed", function()
    local events = {}
    local au = vim.api.nvim_create_autocmd("User", {
      pattern = "NugetPackagesChanged",
      callback = function(ev)
        table.insert(events, ev.data)
      end,
    })
    require("nuget").open({ package = "Serilog" })
    local s = wait_loaded()
    ui.actions.update()
    assert.is_true(vim.wait(5000, function()
      return #events > 0
    end, 20))
    vim.api.nvim_del_autocmd(au)
    assert.equals(s.target.path, events[1].target)
    -- Serilog is at 2.10.0 in Api and 3.0.0 in Lib: both are updated to the latest
    local calls = vim.fn.readfile(dir .. "/calls.log")
    assert.equals(2, #calls)
    assert.matches("package Serilog %-%-version 4%.4%.0", calls[1])
  end)

  -- U under a limit. The fake dotnet lists only 4.4.0 for any package, so Serilog, whose
  -- versions the window never had, is fetched and then skipped.
  local function limited(max_bump)
    require("nuget").setup({
      solution = dir .. "/A.sln",
      details = { fetch = false },
      fast = false,
      updates = { max_bump = max_bump },
    })
    require("nuget").open({ tab = "updates" })
    local s = wait_loaded()
    s.model.packages["newtonsoft.json"].available = { "12.0.1", "12.0.3", "13.0.1", "13.0.4" }
    return s
  end

  --- Answer every vim.ui.select with `pick` (an index, or a function of the items) and collect
  --- what was asked; messages are collected too.
  local function answering(pick)
    local asked, messages = {}, {}
    local select, notify = vim.ui.select, vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, opts, on_choice)
      local labels = vim.tbl_map(function(item)
        return opts.format_item and opts.format_item(item) or item
      end, items)
      table.insert(asked, { prompt = opts.prompt, items = labels })
      local i = type(pick) == "function" and pick(labels) or pick
      on_choice(i and items[i])
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      table.insert(messages, { msg = msg, level = level })
    end
    return asked, messages, function()
      vim.ui.select, vim.notify = select, notify
    end
  end

  local function calls(n)
    vim.wait(5000, function()
      return vim.fn.filereadable(dir .. "/calls.log") == 1 and #vim.fn.readfile(dir .. "/calls.log") >= n
    end, 20)
    return vim.fn.filereadable(dir .. "/calls.log") == 1 and vim.fn.readfile(dir .. "/calls.log") or {}
  end

  local function said(messages, pattern)
    return vim.iter(messages):any(function(m)
      return m.msg:find(pattern) ~= nil
    end)
  end

  it("limits U to updates within the major version, project by project, and says what it skips", function()
    limited("minor")
    local asked, _, restore = answering(1)
    ui.actions.update_all()
    local log = calls(2)
    restore()
    assert.equals("1 patch: Newtonsoft.Json → 12.0.3/13.0.4 · skipped, ≤ minor: Serilog", asked[1].prompt)
    table.sort(log)
    assert.equals(2, #log)
    -- Api stays on 12.x; Lib, already on 13.0.1, gets its patch
    assert.matches("Api%.csproj package Newtonsoft%.Json %-%-version 12%.0%.3", log[1])
    assert.matches("Lib%.csproj package Newtonsoft%.Json %-%-version 13%.0%.4", log[2])
  end)

  it("limits only the marked packages when some are marked", function()
    local s = limited("minor")
    s.marks = { serilog = true }
    local asked, messages, restore = answering(1)
    ui.actions.update_all()
    vim.wait(5000, function()
      return #messages > 1
    end, 20)
    restore()
    assert.equals(0, #asked)
    assert.is_true(said(messages, "^Nothing to update: 1 package skipped, ≤ minor$"))
  end)

  it("updates what the limit allows once the versions are fetched", function()
    local s = limited("minor")
    -- Serilog at 2.10.0 in Api and 4.3.0 in Lib: Lib's minor update needs no list, Api's major does
    for path, ref in pairs(s.model.packages["serilog"].projects) do
      if path:match("Lib") then
        ref.requested, ref.resolved = "4.3.0", "4.3.0"
      end
    end
    local asked, _, restore = answering(2)
    ui.actions.update_all()
    vim.wait(5000, function()
      return #asked > 0
    end, 20)
    restore()
    assert.equals("1 patch: Newtonsoft.Json → 12.0.3/13.0.4 · 1 minor: Serilog → 4.4.0", asked[1].prompt)
    assert.same({ "4.4.0" }, s.model.packages["serilog"].available)
  end)

  it("reports the packages whose versions could not be fetched, instead of skipping them", function()
    limited("minor")
    vim.fn.writefile({}, dir .. "/search_fails")
    local asked, messages, restore = answering(2)
    ui.actions.update_all()
    vim.wait(5000, function()
      return #asked > 0
    end, 20)
    restore()
    assert.matches("not checked, the versions could not be fetched: Serilog", asked[1].prompt)
    assert.is_true(said(messages, "Could not fetch the versions of Serilog: press r"))
    assert.is_nil(ui.state().model.packages["serilog"].available, "fetched again next time")
  end)

  it("does not ask twice, nor act, while U is fetching", function()
    limited("minor")
    vim.fn.writefile({}, dir .. "/search_slow")
    local asked, messages, restore = answering(2)
    ui.actions.update_all()
    ui.actions.update_all()
    ui.actions.update()
    vim.wait(5000, function()
      return #asked > 0
    end, 20)
    vim.wait(300)
    restore()
    assert.equals(1, #asked)
    assert.is_true(said(messages, "Wait for the current operation"))
  end)

  it("drops what U was fetching when the window closes, and asks nothing in the next one", function()
    limited("minor")
    vim.fn.writefile({}, dir .. "/search_slow")
    local asked, _, restore = answering(2)
    vim.v.errmsg = ""
    ui.actions.update_all()
    ui.close()
    require("nuget").open({ tab = "updates" })
    wait_loaded()
    vim.wait(2500)
    restore()
    assert.equals(0, #asked)
    assert.equals("", vim.v.errmsg)
  end)

  it("takes an unlisted version out of the ones U goes to", function()
    local s = limited("minor")
    s.config.fast = true
    local registry = require("nuget.registry")
    local fetch = registry.fetch
    ---@diagnostic disable-next-line: duplicate-set-field
    registry.fetch = function(id, version, cb)
      vim.schedule(function()
        cb({ id = id, version = version, listed = version ~= "12.0.3" })
      end)
    end
    s.model.packages["newtonsoft.json"].available = { "12.0.1", "12.0.2", "12.0.3", "13.0.1", "13.0.4" }
    s.model.packages["serilog"].available = { "2.10.0", "3.0.0", "4.4.0" }
    local asked, _, restore = answering(2)
    ui.actions.update_all()
    vim.wait(5000, function()
      return #asked > 0
    end, 20)
    restore()
    registry.fetch = fetch
    assert.equals("1 patch: Newtonsoft.Json → 12.0.2/13.0.4 · skipped, ≤ minor: Serilog", asked[1].prompt)
  end)

  it("offers the same major next to a major update on enter", function()
    local s = limited("major")
    vim.api.nvim_win_set_cursor(s.layout.list.win, { 1, 0 })
    local asked, _, restore = answering(2)
    ui.actions.primary()
    local log = calls(1)
    restore()
    assert.same({ "Update to 13.0.4 (major)", "Update to 12.0.3 (same major)" }, asked[1].items)
    assert.equals(1, #log)
    assert.matches("Api%.csproj package Newtonsoft%.Json %-%-version 12%.0%.3", log[1])
  end)

  it("offers to choose a version for a major update whose versions are not known", function()
    limited("major")
    local s = ui.state()
    vim.api.nvim_win_set_cursor(s.layout.list.win, { 2, 0 })
    local asked, _, restore = answering(nil)
    ui.actions.primary()
    restore()
    assert.same({ "Update to 4.4.0 (major)", "Choose version…" }, asked[1].items)
  end)

  it("cycles the limit of U with b, and shows it in the hints", function()
    require("nuget").open({ tab = "updates" })
    local s = wait_loaded()
    local function hints()
      return table.concat(vim.api.nvim_buf_get_lines(s.layout.header.buf, 0, -1, false), "\n")
    end
    assert.matches("U update marked/all · b limit", hints())
    ui.actions.bump_limit()
    assert.equals("minor", s.max_bump)
    assert.matches("U update marked/all %(≤ minor%)", hints())
    ui.actions.bump_limit()
    ui.actions.bump_limit()
    assert.equals("major", s.max_bump)
  end)

  it("falls back to major updates for a limit it does not know", function()
    local warnings = {}
    local notify = vim.notify
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg)
      table.insert(warnings, msg)
    end
    require("nuget").setup({
      solution = dir .. "/A.sln",
      details = { fetch = false },
      fast = false,
      updates = { max_bump = "minro" },
    })
    require("nuget").open()
    local s = wait_loaded()
    vim.notify = notify
    assert.equals("major", s.max_bump)
    assert.matches("updates.max_bump must be", warnings[1])
  end)

  it("searches from the Browse tab", function()
    require("nuget").open({ query = "Serilog" })
    local s = wait_loaded()
    assert.is_true(vim.wait(5000, function()
      return #s.search.results > 0
    end, 20))
    assert.equals("browse", s.tab)
    assert.matches("^Serilog", vim.api.nvim_buf_get_lines(s.layout.list.buf, 0, 1, false)[1])
  end)
end)
