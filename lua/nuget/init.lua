local M = {}

---@class NugetConfig
M.default_config = {
  -- Solution or project to manage; nil finds the solution next to the current directory
  -- (asking when there are several) or, without one, the projects below it.
  solution = nil,
  -- Tab shown when the window opens: "browse" | "installed" | "updates" | "consolidate"
  default_tab = "installed",
  -- Include prerelease versions in search and update checks (toggle with `p`)
  prerelease = false,
  -- Package sources (names or URLs from nuget.config) to use; nil uses all of them
  sources = nil,
  -- Answer "is there a newer version / is it vulnerable / is it deprecated" from nuget.org in
  -- seconds (needs curl). Without it the dotnet reports below are the only source, and on a
  -- large solution they take minutes.
  fast = true,
  -- nuget.org requests in flight at once
  fast_concurrency = 12,
  -- dotnet reports that also run in the background and override the quick answers.
  -- `outdated` is the only way to see newer versions on private feeds. `vulnerable` and
  -- `deprecated` add nothing nuget.org does not know and can take many minutes; they are
  -- forced on when `fast` is off or unavailable.
  verify = {
    outdated = true,
    vulnerable = false,
    deprecated = false,
  },
  search = {
    -- Results per page
    take = 30,
    -- Milliseconds to wait after typing before searching
    debounce = 350,
  },
  details = {
    -- Fetch description, license and dependencies from nuget.org (needs curl)
    fetch = true,
  },
  window = {
    -- Fractions of the editor size, or absolute columns / lines when > 1
    width = 0.9,
    height = 0.85,
    -- Fraction of the width given to the details pane
    details_width = 0.4,
    border = "rounded",
  },
  icons = {
    update = "↑",
    vulnerable = "\u{f071}",
    deprecated = "\u{f05e}",
    inconsistent = "≠",
    central = "\u{f015}",
    installed = "✓",
    marked = "●",
    unmarked = "○",
    transitive = "↳",
  },
}

---@type NugetConfig
M.config = vim.deepcopy(M.default_config)

---@param opts NugetConfig?
function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.default_config), opts or {})
end

--- Open the package manager.
---@param opts {tab: string?, query: string?, package: string?, project: string?, solution: string?}?
---   tab: tab to show; query: start a search (implies the Browse tab);
---   package: put the cursor on this package id (implies the Installed tab);
---   project: preselect this project when installing; solution: manage this solution or project
function M.open(opts)
  opts = opts or {}
  if vim.fn.executable(require("nuget.cli").cmd) ~= 1 then
    vim.notify("The dotnet CLI is not on PATH", vim.log.levels.ERROR, { title = "NuGet" })
    return
  end
  if opts.query and not opts.tab then
    opts.tab = "browse"
  elseif opts.package and not opts.tab then
    opts.tab = "installed"
  end
  local explicit = opts.solution or M.config.solution
  if type(explicit) == "function" then
    explicit = explicit()
  end
  require("nuget.solution").resolve(vim.fn.getcwd(), explicit, function(target)
    if not target then
      vim.notify("No solution or project found in " .. vim.fn.getcwd(), vim.log.levels.WARN, { title = "NuGet" })
      return
    end
    require("nuget.ui").open(M.config, target, opts)
  end)
end

function M.close()
  require("nuget.ui").close()
end

function M.toggle(opts)
  if require("nuget.ui").state() then
    M.close()
  else
    M.open(opts)
  end
end

return M
