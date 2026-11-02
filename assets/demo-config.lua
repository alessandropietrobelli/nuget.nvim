-- The Neovim configuration used to record assets/demo.gif. Copy it to
-- ~/.config/nuget-demo/init.lua and run:
--
--   NVIM_APPNAME=nuget-demo nvim
--
-- NVIM_APPNAME moves config, data and state into their own nuget-demo
-- directories, so this touches nothing in ~/.config/nvim.
--
-- It is dressed for the camera (colorscheme, no line numbers, no statusline)
-- rather than being the README install snippet.

-- where this repository is checked out
local PLUGIN_DIR = vim.env.NUGET_NVIM_DIR or vim.fn.expand("~/src/nuget.nvim")

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

vim.g.mapleader = " "

vim.opt.termguicolors = true
vim.opt.number = false
vim.opt.signcolumn = "no"
vim.opt.hlsearch = false
-- VHS emits a frame when the screen changes, so a long Sleep over a still
-- screen shortens in the recording. A blinking cursor gives the still frames
-- something to differ by.
vim.opt.guicursor = "n-v-c:block-blinkwait200-blinkon450-blinkoff450,i:ver25-blinkwait200-blinkon450-blinkoff450"
vim.opt.laststatus = 0
vim.opt.cmdheight = 1
vim.opt.showmode = false
vim.opt.fillchars = { eob = " " }
-- dotnet rewrites Directory.Packages.props during the demo; reload it silently
vim.opt.autoread = true

require("lazy").setup({
  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    opts = { style = "night" },
    config = function(_, opts)
      require("tokyonight").setup(opts)
      vim.cmd.colorscheme("tokyonight")
    end,
  },
  {
    "nuget.nvim",
    dir = PLUGIN_DIR,
    cmd = "Nuget",
    opts = {
      -- Every package of the demo solution is on nuget.org, so the quick checks
      -- already know everything; the background `dotnet list package --outdated`
      -- would only keep a spinner in the header for two more minutes.
      verify = { outdated = false },
      window = { width = 0.94, height = 0.9 },
    },
  },
}, {
  install = { colorscheme = { "tokyonight" } },
  change_detection = { notify = false },
  ui = { backdrop = 100 },
})
