-- Highlight groups of the window and of the versions shown inside project files, linked to
-- standard groups so colorschemes style them; defined once, again after a colorscheme change.
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
    NugetBumpMajor = "DiagnosticWarn",
    NugetBumpMinor = "Normal",
    NugetBumpPatch = "Comment",
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

return {}
