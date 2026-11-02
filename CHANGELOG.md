# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the version stays below `1.0.0`, breaking changes to configuration and
keys may land in a minor release; they will always be listed here.

## [Unreleased]

## [0.2.0] - 2026-11-02

### Added

- `open({ package = "Id" })` opens the window on that package, in the
  Installed tab; with the window already open, it moves the cursor there.
- `open({ project = ... })` also updates the project picked for installs when
  the window is already open.
- A `User NugetPackagesChanged` event after every change, with the solution
  in `data.target`, so other plugins can reload the files `dotnet` rewrote.
  dotnet-tree.nvim uses both: its `a` key opens this window.

### Fixed

- A `dotnet` command whose working folder no longer exists (a project moved
  while the window was open) runs from the current directory instead of
  failing before it starts.

## [0.1.1] - 2026-11-02

No change to the plugin's code.

### Added

- `:help nuget`: the help file, generated from the README with panvimdoc, so the
  documentation is there inside Neovim. Sections have short tags, such as
  `nuget-usage` and `nuget-configuration`.
- A "See also" section pointing to dotnet-tree.nvim and dotnet-counters.nvim.

## [0.1.0] - 2026-11-02

First public release.

### Added

- One floating window over the whole solution, with four tabs:
  - **Browse**: search every configured feed as you type, and install into the
    projects you pick, at the version you pick.
  - **Installed**: every package with its versions per project, a newer
    version when there is one, advisories, deprecations, and the vulnerable
    packages that only come in transitively.
  - **Updates**: vulnerable packages first; update one, the marked ones or all.
  - **Consolidate**: packages referenced at different versions across projects,
    brought to one version.
- A details pane: description, license, authors, release date, project site,
  dependencies for the frameworks in use, advisories with their links, and the
  replacement suggested for deprecated packages.
- Quick answers from nuget.org — newer versions, the vulnerability database
  NuGet audit uses (checked against every resolved version, transitive ones
  included), deprecations — in seconds, while `dotnet list package --outdated`
  confirms them in the background and adds private feeds.
- Versions changed where they are written: in the project, in
  `Directory.Packages.props` (once for every project), as a `VersionOverride`,
  in `Directory.Build.props` or as a `GlobalPackageReference`. The last two,
  which `dotnet add` refuses to edit, are changed in the file itself, followed
  by a restore. A version that is an MSBuild property is never overwritten.
- A confirmation before changing a shared version that also affects projects
  that were not picked.
- `:Nuget`, `:Nuget <tab>` and `:Nuget <query>`, and a Lua API
  (`require("nuget").open({ tab, query, project, solution })`).
- Prerelease versions on demand (`p`), refresh (`r`), links to nuget.org, the
  project site and advisories, `?` for every key.
- Highlight groups linked to standard ones, and `:checkhealth nuget`.

### Known limitations

- Feeds without NuGet's search service cannot be searched; they are reported
  once per session, and installing from them still works.
- Package details come from nuget.org only.
- Newer versions on private feeds appear when `dotnet list package --outdated`
  finishes, which takes a couple of minutes on a large solution.
- Where a version is written is read from the files, not from an MSBuild
  evaluation: conditions are not decided and only the `Directory.Build.props`
  chain and `Directory.Build.targets` are followed.
- `packages.config` projects are not supported.

[Unreleased]: https://github.com/alessandropietrobelli/nuget.nvim/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/alessandropietrobelli/nuget.nvim/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/alessandropietrobelli/nuget.nvim/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/alessandropietrobelli/nuget.nvim/releases/tag/v0.1.0
