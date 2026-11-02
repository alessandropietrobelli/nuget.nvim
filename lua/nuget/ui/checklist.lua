-- A small modal list of checkboxes, used to pick the projects an action applies to.
local layout = require("nuget.ui.layout")

local M = {}

---@class NugetChecklistItem
---@field label string
---@field detail string?
---@field checked boolean
---@field value any

--- Show the checklist; `cb` gets the checked values, or nil when cancelled.
---@param title string
---@param items NugetChecklistItem[]
---@param cb fun(values: any[]?)
---@param opts {border: string|string[]}
function M.open(title, items, cb, opts)
  local return_win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "nuget"

  local labelw = 0
  for _, item in ipairs(items) do
    labelw = math.max(labelw, vim.fn.strdisplaywidth(item.label))
  end
  local width = 10
  for _, item in ipairs(items) do
    width = math.max(width, 4 + labelw + 2 + vim.fn.strdisplaywidth(item.detail or ""))
  end
  local footer = "space toggle · a all · ⏎ confirm · q cancel"
  width =
    math.min(math.max(width, vim.fn.strdisplaywidth(footer) + 2, vim.fn.strdisplaywidth(title) + 4), vim.o.columns - 8)
  local height = math.min(#items, vim.o.lines - 8)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    border = opts.border,
    style = "minimal",
    title = " " .. title .. " ",
    title_pos = "center",
    footer = " " .. footer .. " ",
    footer_pos = "center",
    zindex = 60,
  })
  vim.wo[win].cursorline = true
  vim.wo[win].winhighlight = "NormalFloat:Normal,CursorLine:NugetCursorLine"

  local function render()
    local b = require("nuget.ui.view").builder()
    for _, item in ipairs(items) do
      b:add({
        { item.checked and "[x] " or "[ ] ", item.checked and "NugetMarked" or "NugetMuted" },
        { require("nuget.ui.view").fit(item.label, labelw) .. "  ", "NugetId" },
        { item.detail or "", "NugetMuted" },
      })
    end
    vim.bo[buf].modifiable = true
    layout.set(buf, b.lines)
    vim.bo[buf].modifiable = false
  end
  render()

  local done = false
  local function finish(values)
    if done then
      return
    end
    done = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_win_is_valid(return_win) then
      vim.api.nvim_set_current_win(return_win)
    end
    cb(values)
  end

  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true })
  end
  map("<Space>", function()
    local i = vim.api.nvim_win_get_cursor(win)[1]
    items[i].checked = not items[i].checked
    render()
    if i < #items then
      vim.api.nvim_win_set_cursor(win, { i + 1, 0 })
    end
  end)
  map("a", function()
    local all = vim.iter(items):all(function(item)
      return item.checked
    end)
    for _, item in ipairs(items) do
      item.checked = not all
    end
    render()
  end)
  map("<CR>", function()
    local values = {}
    for _, item in ipairs(items) do
      if item.checked then
        table.insert(values, item.value)
      end
    end
    finish(values)
  end)
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    map(lhs, function()
      finish(nil)
    end)
  end
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        finish(nil)
      end)
    end,
  })
end

return M
