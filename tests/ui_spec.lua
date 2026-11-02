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
    '  "package search"*) cat "' .. fixtures .. '/search.json" ;;',
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
