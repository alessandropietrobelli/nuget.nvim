-- The floating windows: a header with the tabs, a one-line search/filter input, the list on
-- the left and the details on the right.
local M = {}

M.ns = vim.api.nvim_create_namespace("nuget")

local function define_highlights()
  local links = {
    NugetTitle = "Title",
    NugetSection = "Special",
    NugetLabel = "Comment",
    NugetMuted = "Comment",
    NugetId = "Identifier",
    NugetVersion = "Number",
    NugetLatest = "DiagnosticOk",
    NugetUpdate = "DiagnosticWarn",
    NugetInstalled = "DiagnosticOk",
    NugetDeprecated = "DiagnosticWarn",
    NugetInconsistent = "DiagnosticInfo",
    NugetSeverityLow = "DiagnosticHint",
    NugetSeverityModerate = "DiagnosticWarn",
    NugetSeverityHigh = "DiagnosticError",
    NugetMarked = "DiagnosticOk",
    NugetSource = "Constant",
    NugetUrl = "Underlined",
    NugetTab = "Comment",
    NugetTabActive = "Title",
    NugetBusy = "DiagnosticInfo",
    NugetError = "DiagnosticError",
    NugetCursorLine = "CursorLine",
  }
  for group, link in pairs(links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

define_highlights()
vim.api.nvim_create_autocmd("ColorScheme", { callback = define_highlights })

---@class NugetLayout
---@field header {buf: integer, win: integer}
---@field input {buf: integer, win: integer}
---@field list {buf: integer, win: integer}
---@field details {buf: integer, win: integer}

---@param name string
---@return integer
local function scratch(name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "nuget"
  pcall(vim.api.nvim_buf_set_name, buf, "nuget://" .. name)
  return buf
end

--- Window geometry for the current editor size.
---@param opts {width: number, height: number, details_width: number, border: string|string[]}
local function geometry(opts)
  local cols, lines = vim.o.columns, vim.o.lines - vim.o.cmdheight - 1
  local function size(v, total)
    return v <= 1 and math.floor(total * v) or math.floor(v)
  end
  local width = math.max(math.min(size(opts.width, cols), cols - 4), 60)
  local height = math.max(math.min(size(opts.height, lines), lines - 4), 16)
  local row = math.floor((lines - height) / 2)
  local col = math.floor((cols - width) / 2)
  -- Every window has a border: 2 extra columns and rows each
  local header_h, input_h = 2, 1
  local body_row = row + header_h + 2 + input_h + 2
  local body_h = height - header_h - input_h - 6
  local details_w = math.floor(width * opts.details_width)
  local list_w = width - details_w - 2
  return {
    header = { row = row, col = col, width = width, height = header_h },
    input = { row = row + header_h + 2, col = col, width = list_w, height = input_h },
    list = { row = body_row, col = col, width = list_w, height = body_h },
    details = { row = row + header_h + 2, col = col + list_w + 2, width = details_w, height = body_h + input_h + 2 },
  }
end

local function win_config(g, border, title)
  return {
    relative = "editor",
    row = g.row,
    col = g.col,
    width = g.width,
    height = g.height,
    border = border,
    style = "minimal",
    title = title and (" " .. title .. " ") or nil,
    title_pos = title and "left" or nil,
    zindex = 50,
  }
end

---@param opts {width: number, height: number, details_width: number, border: string|string[]}
---@return NugetLayout
function M.open(opts)
  local g = geometry(opts)
  local layout = {}
  local specs = {
    { "header", false, nil },
    { "input", false, "Filter" },
    { "details", false, "Details" },
    { "list", true, nil },
  }
  for _, spec in ipairs(specs) do
    local name, enter, title = spec[1], spec[2], spec[3]
    local buf = scratch(name)
    local win = vim.api.nvim_open_win(buf, enter, win_config(g[name], opts.border, title))
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = name == "list"
    vim.wo[win].winhighlight = "NormalFloat:Normal,CursorLine:NugetCursorLine"
    layout[name] = { buf = buf, win = win }
  end
  vim.wo[layout.details.win].wrap = true
  vim.wo[layout.details.win].linebreak = true
  vim.bo[layout.input.buf].modifiable = true
  for _, name in ipairs({ "header", "list", "details" }) do
    vim.bo[layout[name].buf].modifiable = false
  end
  return layout
end

---@param layout NugetLayout
---@param opts table
function M.resize(layout, opts)
  local g = geometry(opts)
  for _, name in ipairs({ "header", "input", "list", "details" }) do
    local w = layout[name].win
    if vim.api.nvim_win_is_valid(w) then
      local cfg = vim.api.nvim_win_get_config(w)
      vim.api.nvim_win_set_config(
        w,
        vim.tbl_extend("force", cfg, {
          relative = "editor",
          row = g[name].row,
          col = g[name].col,
          width = g[name].width,
          height = g[name].height,
        })
      )
    end
  end
end

---@param layout NugetLayout
function M.close(layout)
  for _, name in ipairs({ "header", "input", "list", "details" }) do
    local part = layout[name]
    if part and vim.api.nvim_win_is_valid(part.win) then
      pcall(vim.api.nvim_win_close, part.win, true)
    end
  end
end

---@param layout NugetLayout
---@return boolean
function M.is_valid(layout)
  return layout ~= nil and vim.api.nvim_win_is_valid(layout.list.win)
end

--- Replace a buffer's content with built lines and their highlights.
---@param buf integer
---@param lines NugetLine[]
function M.set(buf, lines)
  local text = {}
  for i, line in ipairs(lines) do
    text[i] = line.text
  end
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
  vim.bo[buf].modifiable = modifiable
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for i, line in ipairs(lines) do
    for _, h in ipairs(line.hl) do
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, i - 1, h[1], { end_col = h[2], hl_group = h[3] })
    end
  end
end

---@param win integer
---@param title string
function M.set_title(win, title)
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, { title = " " .. title .. " ", title_pos = "left" })
  end
end

return M
