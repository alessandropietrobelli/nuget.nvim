local M = {}

function M.check()
  local health = vim.health
  local config = require("nuget").config
  local cli = require("nuget.cli")

  health.start("nuget.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10+ is required")
  end

  if vim.fn.executable(cli.cmd) ~= 1 then
    health.error("dotnet not found on PATH", { "Install the .NET SDK 8.0.200 or later" })
  else
    local result = vim.system({ cli.cmd, "--version" }, { text = true }):wait(10000)
    local version = vim.trim(result.stdout or "")
    local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)")
    major, minor, patch = tonumber(major), tonumber(minor), tonumber(patch)
    -- `dotnet package search` arrived in 8.0.200; JSON output of `dotnet list package` in 7.0.200
    if major and (major > 8 or (major == 8 and (minor > 0 or patch >= 200))) then
      health.ok("dotnet SDK " .. version)
    elseif major then
      health.error("dotnet SDK " .. version .. " is too old", { "Searching needs the .NET SDK 8.0.200 or later" })
    else
      health.warn("Could not read the dotnet SDK version: " .. version)
    end
  end

  if not config.details.fetch then
    health.info("Package details from nuget.org are disabled (details.fetch = false)")
  elseif vim.fn.executable("curl") == 1 then
    health.ok("curl found: package details are fetched from nuget.org")
  else
    health.warn("curl not found: the details pane will not show descriptions, licenses or dependencies")
  end

  local sln = require("nuget.solution")
  local solutions = sln.find_solutions(vim.fn.getcwd())
  if #solutions > 0 then
    health.ok("Solution: " .. table.concat(
      vim.tbl_map(function(p)
        return vim.fn.fnamemodify(p, ":~:.")
      end, solutions),
      ", "
    ))
  else
    local projects = sln.find_projects(vim.fn.getcwd())
    if #projects > 0 then
      health.ok(("No solution; %d project(s) below the current directory"):format(#projects))
    else
      health.info("No solution or project below the current directory")
    end
  end
end

return M
