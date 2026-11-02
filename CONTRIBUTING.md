# Contributing

Thanks for taking a look. Issues and pull requests are both welcome.

## Reporting a bug

Please include:

- Neovim version (`nvim --version`)
- The output of `:checkhealth nuget`
- Whether the solution is `.sln` or `.slnx`, and whether it uses central package management
  (`Directory.Packages.props`)
- Which feeds are configured (`dotnet nuget list source`), with private URLs redacted
- For wrong data, the output of the command behind it, run in the solution's directory. Sanitise
  project paths and feed URLs, but keep the structure — the parsers read the JSON exactly as the SDK
  writes it:

  ```sh
  dotnet list <solution> package --include-transitive --format json   # the package list
  dotnet list <solution> package --outdated --format json             # newer versions
  dotnet package search <id> --exact-match --format json              # versions of one package
  ```

- For a failed install or update, the message in the notification and the result of running the
  same `dotnet add <project> package <id> --version <version>` in a terminal

The most common reports, and what they usually are:

- *"A private feed shows an error when I search"*: the feed does not offer NuGet's search service,
  or its credentials are not available to `dotnet`. Run `dotnet package search <id>` in a terminal:
  if it fails there too, it is not the plugin.
- *"An update I know about is missing"*: if the package lives on a private feed, it shows up when
  `dotnet list package --outdated` finishes — the header says *verifying versions with dotnet*
  until then.
- *"It is slow to open"*: the package list itself is `dotnet list package`, and on a solution with
  hundreds of projects that takes a while. The window fills in as soon as it returns.

## Development setup

Point your plugin manager at a local checkout instead of the GitHub repo. With lazy.nvim:

```lua
{ "alessandropietrobelli/nuget.nvim", dir = "~/src/nuget.nvim", cmd = "Nuget", opts = {} }
```

Restart Neovim (or `:Lazy reload nuget.nvim`) to pick up changes. A throwaway solution makes the
write paths safe to try:

```sh
dotnet new sln -n Lab && dotnet new classlib -n Api -f net8.0 && dotnet sln add Api
dotnet add Api package Newtonsoft.Json -v 12.0.1   # vulnerable
dotnet add Api package Serilog -v 2.10.0           # outdated
```

## Before opening a pull request

```sh
stylua lua/ plugin/ tests/   # formatting is enforced in CI
luacheck lua/ plugin/ tests/
nvim --headless -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```

The suite needs [plenary.nvim](https://github.com/nvim-lua/plenary.nvim): clone it into `deps/`, or it
is picked up from lazy.nvim's install directory. It does not touch the network: the window tests
run against a fake `dotnet` that replays the fixtures. CI also loads every module against Neovim
stable and nightly.

Keep `README.md` in sync when you change behaviour, keys or configuration defaults — its `setup()`
block mirrors `default_config` in `lua/nuget/init.lua`.

## Code layout

| Path | Responsibility |
|---|---|
| `lua/nuget/init.lua` | `setup`, configuration, `open` |
| `lua/nuget/solution.lua` | finding the solution or projects; where each project's version is written |
| `lua/nuget/cli.lua` | `dotnet list package`, `package search`, `add` / `remove package`, `restore` |
| `lua/nuget/plan.lua` | turns "this version in these projects" into steps, one per place the version is written |
| `lua/nuget/xml.lua` | edits package items in MSBuild files as text, for what `dotnet add` refuses to touch |
| `lua/nuget/model.lua` | merges the reports into one view per package: versions, latest, advisories, deprecation |
| `lua/nuget/fast.lua` | the quick nuget.org checks: latest versions, vulnerability database, bounded concurrency |
| `lua/nuget/registry.lua` | nuget.org metadata for the details pane (and deprecations) |
| `lua/nuget/semver.lua` | NuGet version ordering and version ranges |
| `lua/nuget/ui/init.lua` | the window: state, loading, keys, actions |
| `lua/nuget/ui/view.lua` | list and details content — pure, no window access |
| `lua/nuget/ui/layout.lua` | the floating windows and highlight groups |
| `lua/nuget/ui/checklist.lua` | the project picker |
| `lua/nuget/health.lua` | `:checkhealth nuget` |
| `plugin/nuget.lua` | the `:Nuget` command |

### Fixtures

`tests/fixtures/` holds real SDK output for a small solution with a vulnerable, an outdated and a
deprecated package, with paths and feed names replaced. When a fix depends on what the SDK prints,
add a capture rather than hand-written JSON.

## Scope

This is a *package manager*: finding, installing, updating, consolidating and removing NuGet
packages, and showing what is wrong with the ones installed. Things that do not belong here:
building and running projects, solution exploration (see
[dotnet-tree.nvim](https://github.com/alessandropietrobelli/dotnet-tree.nvim)), editing
`nuget.config` or feed credentials.

## License

By contributing you agree that your contributions are licensed under the [Apache-2.0](LICENSE)
license that covers this project.
