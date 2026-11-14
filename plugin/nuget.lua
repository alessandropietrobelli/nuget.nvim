if vim.g.loaded_nuget then
  return
end
vim.g.loaded_nuget = true

local tabs = { "browse", "installed", "updates", "consolidate" }
-- Actions on the package under the cursor in a project file, and the versions shown there
local inline = { update = "update", version = "version", inline = "toggle" }

vim.api.nvim_create_user_command("Nuget", function(opts)
  local args = vim.split(vim.trim(opts.args), "%s+", { trimempty = true })
  local tab = args[1]
  if tab and inline[tab] and #args == 1 then
    return require("nuget.inline")[inline[tab]]()
  end
  if tab and not vim.tbl_contains(tabs, tab) then
    -- `:Nuget Serilog` searches for it
    return require("nuget").open({ query = table.concat(args, " ") })
  end
  local query = #args > 1 and table.concat(vim.list_slice(args, 2), " ") or nil
  require("nuget").open({ tab = tab, query = query })
end, {
  nargs = "*",
  desc = "NuGet package manager",
  complete = function(arg_lead, line)
    if line:match("^%S+%s+%S+%s") then
      return {}
    end
    return vim.tbl_filter(function(tab)
      return tab:find(arg_lead, 1, true) == 1
    end, vim.list_extend(vim.list_slice(tabs), vim.tbl_keys(inline)))
  end,
})
