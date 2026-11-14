# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the version stays below `1.0.0`, breaking changes to configuration and
keys may land in a minor release; they will always be listed here.

## [Unreleased]

### Added

- Each update is labelled `patch`, `minor` or `major`, majors highlighted, and a
  package whose latest version is a major update also shows the highest one on
  the same major, once its versions are known. `⏎` on it in the Updates tab,
  and the menu on the Installed tab, offer both; `v` tags it `same major`
  ([#1](https://github.com/alessandropietrobelli/nuget.nvim/issues/1)).
- `U` can be limited to updates within the major or the minor version: `b` on
  the Updates tab cycles the limit for the session, and `updates.max_bump`
  sets it (`"major"` by default, as before). Each project goes to the highest
  version the limit allows from the one it is at, leaving out versions their
  authors unlisted. Packages with nothing within the limit are dimmed and
  skipped, and the confirmation groups the updates as patch, minor and major,
  naming what it skips and the packages whose versions could not be fetched
  ([#1](https://github.com/alessandropietrobelli/nuget.nvim/issues/1)).
- Versions inside project files, opt-in with `inline.enabled` or `:Nuget inline`:
  `.csproj`, `.fsproj`, `.vbproj` and `Directory.*.props` show at the end of
  each package line its latest version and kind, vulnerabilities and
  deprecation, from nuget.org and never from `dotnet list package`.
  `:Nuget update` and `:Nuget version` change the version of the package under
  the cursor in the buffer itself, or go to its `PackageVersion` under central
  package management; `inline.keys` maps them
  ([#2](https://github.com/alessandropietrobelli/nuget.nvim/issues/2)).

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
