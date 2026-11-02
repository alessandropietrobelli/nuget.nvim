# nuget.nvim

A NuGet package manager for Neovim: one floating window, four tabs, the whole solution at once.

<!-- panvimdoc-ignore-start -->

![nuget.nvim on the jellyfin solution: the installed packages with their details, a filter,
updating Polly in Directory.Packages.props, searching for Bogus and installing it in one project](assets/demo.gif)

<sub>Recorded on a [jellyfin](https://github.com/jellyfin/jellyfin) checkout — 41 projects,
central package management. The demo is a script: [`assets/demo.tape`](assets/demo.tape).</sub>

jellyfin has nothing to flag.

<!-- panvimdoc-ignore-end -->

On a solution that does, the list says so — a vulnerable package, an outdated one at different
versions across projects (`≠`), a deprecated one:

```
Microsoft.Azure.Storage.Blob 11.2.3  deprecated
Newtonsoft.Json              13.0.1, 12.0.1 ↑ 13.0.4  High ≠
Serilog                      3.0.0, 2.10.0 ↑ 4.4.0 ≠
```

- **Browse** — search every configured feed as you type, see the details, install into the
  projects you pick, at the version you pick
- **Installed** — every package of the solution with its versions per project, a newer version
  when there is one, vulnerabilities, deprecations, and the vulnerable packages that only come in
  transitively
- **Updates** — what can be updated, vulnerable packages first; update one, the marked ones, or
  all of them
- **Consolidate** — packages referenced at different versions across projects, and which project
  has which; bring them to one version
- **Wherever the version is written** — in the project, in `Directory.Packages.props` (central
  package management, updated once for every project), as a `VersionOverride`, in
  `Directory.Build.props`, or as a `GlobalPackageReference`. The details pane says which, and
  changing a shared version asks first when it also affects projects you did not pick
- **Details** — description, license, authors, release date, project site, dependencies for the
  frameworks you target, advisories with links, deprecation with its suggested replacement

## How it works

Everything that reads or changes packages goes through the `dotnet` CLI — `dotnet list package`,
`dotnet package search`, `dotnet add` / `remove package` — so `nuget.config`, private feeds and
their credentials behave exactly as they do in a terminal, and central package management is
handled by the SDK itself.

The one exception is what the SDK refuses to edit: package items in `Directory.Build.props` and
`GlobalPackageReference` (`dotnet add` fails with *"Cannot edit items in imported files"*). For
those, nuget.nvim changes the version or removes the item in the file itself — only that value
or that element, leaving formatting and comments alone — and runs `dotnet restore` afterwards. A
version that is an MSBuild property (`Version="$(SerilogVersion)"`) is never overwritten: you are
told to change the property instead.

On a large solution `dotnet list package --outdated` takes minutes and `--vulnerable` can take much
longer. So once the package list is in, nuget.nvim asks nuget.org directly, which answers in
seconds:

- **newer versions** from the package's version list
- **vulnerabilities** from nuget.org's vulnerability database — the one NuGet audit itself uses —
  checked against every resolved version, transitive ones included
- **deprecations** from each installed version's metadata

`dotnet list package --outdated` keeps running in the background and has the last word: it is the
only way to see newer versions on private feeds. The header says when it is still at it.

## Requirements

- Neovim 0.10+
- .NET SDK 8.0.200+ (`dotnet package search`)
- `curl`, for the quick nuget.org checks and the details pane — optional, everything else works
  without it, just slower
- A Nerd Font for the default icons, or set your own (see `icons` below)

`:checkhealth nuget` checks all of the above.

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "alessandropietrobelli/nuget.nvim",
  -- Startup only defines :Nuget; everything else loads when the window opens. Loading it
  -- lazily would also hide :checkhealth nuget until the first :Nuget.
  lazy = false,
  opts = {},
  keys = {
    { "<leader>cN", "<cmd>Nuget<cr>", desc = "NuGet packages" },
    { "<leader>cU", "<cmd>Nuget updates<cr>", desc = "NuGet updates" },
  },
}
```

## Usage

| Command | |
|---|---|
| `:Nuget` | Open on the default tab |
| `:Nuget browse` / `installed` / `updates` / `consolidate` | Open on that tab |
| `:Nuget <query>` | Open Browse and search for `query` |

The solution is the `.sln` / `.slnx` in the current directory or the closest parent (you are asked
when there are several). Without one, the projects below the current directory are managed.

### Keys

| Key | |
|---|---|
| `1`–`4`, `<Tab>` / `<S-Tab>` | Switch tab |
| `/` | Search (Browse) or filter by id (other tabs); `⏎` or `<Esc>` back to the list |
| `⏎` | The obvious action: install (Browse), a menu (Installed), update (Updates), consolidate (Consolidate) |
| `i` | Install in projects — or add an installed package to more projects |
| `u` | Update to the latest version |
| `U` | Update the marked packages, or all of them (Updates) |
| `<Space>` | Mark for `U` (Updates) |
| `v` | Pick a version — to install, update, downgrade or consolidate on |
| `d` | Remove from projects |
| `]` | More search results |
| `p` | Include / exclude prerelease versions |
| `r` | Refresh |
| `o` / `O` / `a` | Open on nuget.org / the project site / the advisory |
| `J` / `K` | Scroll the details |
| `?` | All keys |
| `q` / `<Esc>` | Close |

Choosing projects opens a checklist: `<Space>` toggles, `a` toggles all, `⏎` confirms, `q` cancels.
Changes run one at a time, with progress in the header, and the window reloads when they are done.

### Lua API

```lua
require("nuget").open({ tab = "updates" })
require("nuget").open({ query = "Serilog" })               -- search
require("nuget").open({ project = "src/Api/Api.csproj" })  -- preselect it when installing
require("nuget").open({ solution = "path/to/Other.sln" })
```

## Configuration

Defaults:

```lua
require("nuget").setup({
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
})
```

### Highlights

Every group links to a standard one by default, so the window follows your colour scheme:

| Group | Default link | |
|---|---|---|
| `NugetTitle` | `Title` | package name in the details |
| `NugetSection` | `Special` | section headings |
| `NugetId` | `Identifier` | package ids |
| `NugetVersion` | `Number` | versions |
| `NugetLatest` / `NugetInstalled` | `DiagnosticOk` | latest version, installed mark |
| `NugetUpdate` | `DiagnosticWarn` | newer version available |
| `NugetSeverityLow` / `Moderate` / `High` | `DiagnosticHint` / `DiagnosticWarn` / `DiagnosticError` | advisories (Critical uses High) |
| `NugetDeprecated` | `DiagnosticWarn` | deprecations |
| `NugetInconsistent` | `DiagnosticInfo` | versions differ across projects |
| `NugetMarked` | `DiagnosticOk` | marked for update |
| `NugetSource` | `Constant` | packages from feeds other than nuget.org |
| `NugetUrl` | `Underlined` | links |
| `NugetTab` / `NugetTabActive` | `Comment` / `Title` | tabs |
| `NugetLabel` / `NugetMuted` | `Comment` | labels, secondary text |
| `NugetBusy` | `DiagnosticInfo` | progress in the header |
| `NugetCursorLine` | `CursorLine` | selected row |

## Limitations

- **Private feeds in search.** Feeds that do not implement NuGet's search service (some GitHub
  Packages setups, for instance) cannot be searched; they are reported once and the other feeds
  still answer. Installing and updating from them works, since that goes through `dotnet add`.
- **Details come from nuget.org.** Packages only on private feeds show what the search returns:
  version, owners, description.
- **Newer versions on private feeds** appear when `dotnet list package --outdated` finishes, which
  on a large solution takes a couple of minutes.
- **`packages.config` projects** are not supported, as `dotnet list package` does not read them.
- **Where a version is written** is read from the files, not from an MSBuild evaluation:
  conditions on item groups are not decided, and imports other than the `Directory.Build.props`
  chain and `Directory.Build.targets` are not followed. When the version comes from somewhere
  else, changes fall back to `dotnet add`.

## Development

```sh
git clone --depth 1 https://github.com/nvim-lua/plenary.nvim deps/plenary.nvim
nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Trademarks

nuget.nvim is an independent project. It is not affiliated with, endorsed or sponsored by Microsoft
or the .NET Foundation, and it is not an official NuGet client. NuGet and .NET are trademarks of
their respective owners, used here only to say what the plugin works with. Package data comes from
the feeds you configure and from nuget.org's public APIs.

## License

[Apache 2.0](LICENSE)
