-- Minimal init for the test suite: only plenary is needed.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")

vim.opt.runtimepath:prepend(root)

local plenary = vim.env.PLENARY_DIR or (root .. "/deps/plenary.nvim")
if vim.fn.isdirectory(plenary) == 0 then
  plenary = vim.fn.expand("~/.local/share/nvim/lazy/plenary.nvim")
end
vim.opt.runtimepath:prepend(plenary)

vim.opt.swapfile = false
