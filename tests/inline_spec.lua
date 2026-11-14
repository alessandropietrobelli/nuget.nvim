-- Versions shown inside project files, against a fake nuget.org.
local cli = require("nuget.cli")
local fast = require("nuget.fast")
local inline = require("nuget.inline")
local registry = require("nuget.registry")
local solution = require("nuget.solution")

local VERSIONS = {
  ["newtonsoft.json"] = { "12.0.1", "12.0.3", "13.0.4" },
  serilog = { "4.3.0", "4.4.0" },
  prop = { "1.0.0", "2.0.0" },
  ranged = { "1.5.0", "2.1.0" },
  old = { "1.0.0", "1.2.0", "1.3.0-beta" },
}

local PROJECT = {
  '<Project Sdk="Microsoft.NET.Sdk">',
  "  <ItemGroup>",
  '    <PackageReference Include="Newtonsoft.Json" Version="12.0.1" />',
  '    <PackageReference Include="Serilog">',
  "      <Version>4.4.0</Version>",
  "    </PackageReference>",
  '    <!-- <PackageReference Include="Commented" Version="1.0.0" /> -->',
  '    <PackageReference Include="Prop" Version="$(PropVersion)" />',
  '    <PackageReference Include="Ranged" Version="[1.0,2.0)" />',
  '    <PackageReference Include="A;B" Version="1.0.0" />',
  '    <PackageReference Include="Old" VersionOverride="1.0.0" />',
  '    <PackageReference Include="Private.Feed" Version="1.0.0" />',
  "  </ItemGroup>",
  "</Project>",
}

describe("versions in project files", function()
  local dir, saved, asked, messages
  -- What the fake nuget.org does: `offline` fails every request, `delay` holds the answers
  local net
  -- Package lists asked for, and answers still on the way
  local latest_calls, inflight
  local feeds_asked

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    solution.clear_cache()
    net = { offline = false, delay = 0, advisories_fail = false }
    latest_calls, inflight, feeds_asked = {}, 0, {}
    saved = {
      enabled = fast.enabled,
      why_disabled = fast.why_disabled,
      latest = fast.latest,
      advisories = fast.advisories,
      fetch = registry.fetch,
      versions = cli.versions,
      select = vim.ui.select,
      notify = vim.notify,
    }
    local function answer(fn)
      inflight = inflight + 1
      vim.defer_fn(function()
        inflight = inflight - 1
        fn()
      end, net.delay)
    end
    fast.enabled = function()
      return true
    end
    fast.why_disabled = function()
      return nil
    end
    fast.latest = function(ids, opts, on_result, on_done)
      table.insert(latest_calls, vim.list_slice(ids))
      answer(function()
        for _, id in ipairs(ids) do
          local versions = VERSIONS[id:lower()]
          if net.offline then
            if opts.on_failed then
              opts.on_failed(id)
            end
          elseif versions then
            on_result(id, versions[#versions], versions)
          end
        end
        on_done()
      end)
      return { cancel = function() end }
    end
    fast.advisories = function(cb)
      answer(function()
        if net.offline or net.advisories_fail then
          return cb(nil)
        end
        cb({ ["newtonsoft.json"] = { { url = "https://advisory", severity = "High", versions = "[12.0.0, 12.0.3)" } } })
      end)
    end
    registry.clear_cache()
    registry.fetch = function(id, version, cb)
      answer(function()
        if net.offline then
          return cb(nil, true)
        end
        cb({ id = id, version = version, deprecation = id == "Old" and { reasons = { "Legacy" } } or nil })
      end)
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    cli.versions = function(id, opts, cb)
      table.insert(feeds_asked, { id = id, opts = opts })
      vim.schedule(function()
        cb({ "9.0.0", "8.0.0" }, {})
      end)
      return { kill = function() end }
    end
    asked, messages = {}, {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      table.insert(messages, { msg = msg, level = level })
    end
    require("nuget").setup({ inline = { enabled = true } })
  end)

  after_each(function()
    -- Answers still on the way would land in the next test
    vim.wait(2000, function()
      return inflight == 0
    end, 10)
    require("nuget").setup({})
    fast.enabled, fast.why_disabled = saved.enabled, saved.why_disabled
    fast.latest, fast.advisories = saved.latest, saved.advisories
    registry.fetch, cli.versions = saved.fetch, saved.versions
    vim.ui.select, vim.notify = saved.select, saved.notify
    vim.cmd("silent! %bwipeout!")
    vim.fn.delete(dir, "rf")
  end)

  --- Answer every vim.ui.select with item `pick`, collecting the labels it was asked.
  local function answering(pick)
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, opts, on_choice)
      table.insert(
        asked,
        vim.tbl_map(function(item)
          return opts.format_item and opts.format_item(item) or item
        end, items)
      )
      on_choice(pick and items[pick])
    end
  end

  local function open(name, lines)
    local path = dir .. "/" .. name
    vim.fn.writefile(lines, path)
    vim.cmd.edit(vim.fn.fnameescape(path))
    return vim.api.nvim_get_current_buf()
  end

  --- The text shown at the end of each line, by 1-based line number.
  local function shown(buf)
    local out = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, inline.ns, 0, -1, { details = true })) do
      out[mark[2] + 1] = table.concat(vim.tbl_map(function(c)
        return c[1]
      end, mark[4].virt_text))
    end
    return out
  end

  local function wait_for(cond, what)
    assert.is_true(vim.wait(2000, cond, 10), what)
  end

  local function wait_shown(buf, line)
    wait_for(function()
      return shown(buf)[line] ~= nil
    end, "line " .. line .. " shows something")
    return shown(buf)
  end

  local function wait_settled()
    wait_for(function()
      return inflight == 0
    end, "nuget.org answered")
  end

  local function line(buf, n)
    return vim.api.nvim_buf_get_lines(buf, n - 1, n, false)[1]
  end

  --- Change lines as typing would: headless, TextChanged only fires when asked.
  local function edit(buf, first, last, lines)
    vim.api.nvim_buf_set_lines(buf, first, last, false, lines)
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = buf })
  end

  --- Whether line 3 shows the update from 12.0.3, the version the edits below write.
  local function from_12_0_3(buf)
    local t = shown(buf)[3]
    return t ~= nil and t:find("13.0.4", 1, true) ~= nil and not t:find("patch", 1, true)
  end

  local function said(pattern)
    return vim.iter(messages):any(function(m)
      return m.msg:find(pattern) ~= nil
    end)
  end

  local function count_said(pattern)
    return #vim.tbl_filter(function(m)
      return m.msg:find(pattern) ~= nil
    end, messages)
  end

  it("reads the items that name one package, with where their version is", function()
    local text = table.concat(PROJECT, "\n")
    local entries = inline.entries(text)
    local ids = vim.tbl_map(function(e)
      return e.id
    end, entries)
    assert.same({ "Newtonsoft.Json", "Serilog", "Prop", "Ranged", "Old", "Private.Feed" }, ids)
    assert.equals(2, entries[1].row)
    assert.equals("12.0.1", entries[1].version.value)
    -- The child element: the text goes on its line
    assert.equals(4, entries[2].row)
    assert.same({ 3, 5 }, { entries[2].first, entries[2].last })
    assert.equals("versionoverride", entries[5].attr)
    assert.equals("1.0.0", text:sub(entries[5].version.start, entries[5].version.stop))
  end)

  it("shows the update and its kind, vulnerabilities and deprecation, and nothing else", function()
    local buf = open("Api.csproj", PROJECT)
    wait_shown(buf, 11)
    wait_settled()
    local t = shown(buf)
    assert.matches("↑ 13%.0%.4 major · 12%.0%.3 patch", t[3])
    assert.matches("High", t[3])
    assert.is_nil(t[5], "Serilog is up to date")
    assert.is_nil(t[7], "commented out")
    assert.is_nil(t[8], "a property")
    assert.matches("^ ↑ 2%.1%.0$", t[9], "the latest is outside the range")
    assert.is_nil(t[10], "a list")
    assert.matches("↑ 1%.2%.0 minor", t[11])
    assert.matches("deprecated", t[11])
    assert.not_matches("beta", t[11], "prereleases only when asked for")
    assert.is_nil(t[12], "not on nuget.org")
  end)

  it("judges a prerelease against prereleases", function()
    local buf = open("Api.csproj", { '<PackageReference Include="Old" Version="1.2.0-alpha" />' })
    assert.matches("↑ 1%.3%.0%-beta minor", wait_shown(buf, 1)[1])
  end)

  it("shows nothing for a floating version", function()
    local buf = open("Api.csproj", { '<PackageReference Include="Serilog" Version="4.*" />' })
    wait_settled()
    assert.same({}, shown(buf))
  end)

  it("shows nothing when it is not turned on", function()
    require("nuget").setup({})
    local buf = open("Api.csproj", PROJECT)
    vim.wait(100)
    assert.same({}, shown(buf))
    assert.is_false(inline.is_enabled())
  end)

  it("attaches project and Directory files only, including those open before it was turned on", function()
    require("nuget").setup({})
    local before = open("Api.fsproj", PROJECT)
    local props = open("Directory.Build.targets", PROJECT)
    local other = open("packages.lock.json", PROJECT)
    require("nuget").setup({ inline = { enabled = true } })
    wait_shown(before, 3)
    wait_shown(props, 3)
    wait_settled()
    assert.same({}, shown(other))
    assert.is_nil(vim.b[other].nuget_inline)
  end)

  it("follows the edits", function()
    local buf = open("Api.csproj", PROJECT)
    wait_shown(buf, 3)
    edit(buf, 2, 3, { '    <PackageReference Include="Newtonsoft.Json" Version="12.0.3" />' })
    wait_for(function()
      return from_12_0_3(buf)
    end, "shows the update from the version written now")
  end)

  it("still follows the edits after a second setup", function()
    require("nuget").setup({ inline = { enabled = true } })
    local buf = open("Api.csproj", PROJECT)
    wait_shown(buf, 3)
    require("nuget").setup({ inline = { enabled = true } })
    edit(buf, 2, 3, { '    <PackageReference Include="Newtonsoft.Json" Version="12.0.3" />' })
    wait_for(function()
      return from_12_0_3(buf)
    end, "shows the update from the version written now")
  end)

  it("asks nuget.org once for a package two files show at the same time", function()
    net.delay = 200
    local a = open("A.csproj", { '<PackageReference Include="Serilog" Version="4.3.0" />' })
    local b = open("B.csproj", { '<PackageReference Include="Serilog" Version="4.3.0" />' })
    wait_shown(a, 1)
    wait_shown(b, 1)
    assert.equals(1, #latest_calls)
  end)

  it("warns once when nuget.org cannot be reached, and asks again on the next change", function()
    net.offline = true
    local buf = open("Api.csproj", PROJECT)
    wait_settled()
    assert.same({}, shown(buf))
    assert.equals(1, count_said("Could not reach nuget%.org"))
    assert.equals(1, count_said("vulnerability database"))
    -- Still offline: asked again, without warning again
    edit(buf, 0, 0, { "" })
    wait_for(function()
      return #latest_calls >= 2
    end, "asked again")
    wait_settled()
    assert.equals(1, count_said("Could not reach nuget%.org"))
    net.offline = false
    edit(buf, 0, 1, {})
    wait_shown(buf, 11)
    wait_settled()
    local t = shown(buf)
    assert.matches("↑ 13%.0%.4 major", t[3])
    assert.matches("High", t[3], "the vulnerability database is downloaded again")
    assert.matches("deprecated", t[11], "the deprecation is asked again")
  end)

  it("marks vulnerable packages once the vulnerability database downloads", function()
    net.advisories_fail = true
    local buf = open("Api.csproj", PROJECT)
    wait_shown(buf, 3)
    wait_settled()
    assert.not_matches("High", shown(buf)[3])
    assert.is_true(said("vulnerable packages are not marked"))
    net.advisories_fail = false
    vim.cmd("silent write")
    wait_for(function()
      return (shown(buf)[3] or ""):find("High") ~= nil
    end, "marked after the save")
  end)

  it("updates a minor in place, in the attribute the version is in", function()
    local buf = open("Api.csproj", PROJECT)
    vim.api.nvim_win_set_cursor(0, { 11, 0 })
    inline.update()
    wait_for(function()
      return line(buf, 11):find("1.2.0", 1, true) ~= nil
    end, "updated")
    assert.equals('    <PackageReference Include="Old" VersionOverride="1.2.0" />', line(buf, 11))
    assert.is_true(vim.bo[buf].modified, "not saved")
    vim.cmd("silent undo")
    assert.equals(PROJECT[11], line(buf, 11))
  end)

  it("updates right after the file opens, from nuget.org's answer on the way", function()
    net.delay = 200
    local buf = open("Api.csproj", PROJECT)
    vim.api.nvim_win_set_cursor(0, { 11, 0 })
    inline.update()
    wait_for(function()
      return line(buf, 11):find("1.2.0", 1, true) ~= nil
    end, "updated")
    assert.same({}, feeds_asked, "dotnet package search")
    assert.equals(1, #latest_calls)
  end)

  it("writes where the version moved to while the versions were fetched", function()
    net.delay = 200
    local buf = open("Api.csproj", PROJECT)
    vim.api.nvim_win_set_cursor(0, { 11, 0 })
    inline.update()
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "<!-- added -->" })
    wait_for(function()
      return line(buf, 12):find("1.2.0", 1, true) ~= nil
    end, "updated on its new line")
  end)

  it("writes nothing when the version changed while the versions were fetched", function()
    net.delay = 200
    local buf = open("Api.csproj", PROJECT)
    vim.api.nvim_win_set_cursor(0, { 11, 0 })
    inline.update()
    vim.api.nvim_buf_set_lines(buf, 10, 11, false, { '    <PackageReference Include="Old" VersionOverride="1.1.0" />' })
    wait_for(function()
      return said("changed to 1%.1%.0 meanwhile")
    end, "says so")
    assert.matches('"1%.1%.0"', line(buf, 11))
  end)

  it("says when the package is up to date", function()
    open("Api.csproj", PROJECT)
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    inline.update()
    wait_for(function()
      return said("Serilog is up to date %(4%.4%.0%)")
    end, "says so")
  end)

  it("asks between the latest and the same major for a major, and takes the badge away", function()
    answering(1)
    local buf = open("Api.csproj", PROJECT)
    wait_shown(buf, 3)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    inline.update()
    wait_for(function()
      return #asked > 0
    end, "asked")
    assert.same({ "Update to 13.0.4 (major)", "Update to 12.0.3 (same major)", "Choose version…" }, asked[1])
    assert.matches('Version="13%.0%.4"', line(buf, 3))
    assert.is_nil(shown(buf)[3], "neither the update nor the vulnerability is shown")
    assert.is_true(said("Newtonsoft%.Json → 13%.0%.4 in Api%.csproj: save to apply"))
  end)

  it("updates to the same major", function()
    answering(2)
    local buf = open("Api.csproj", PROJECT)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    inline.update()
    wait_for(function()
      return #asked > 0
    end, "asked")
    assert.matches('Version="12%.0%.3"', line(buf, 3))
  end)

  it("lists every version from Choose version…", function()
    local buf = open("Api.csproj", PROJECT)
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, opts, on_choice)
      table.insert(asked, vim.tbl_map(opts.format_item or tostring, items))
      on_choice(items[3])
    end
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    inline.update()
    wait_for(function()
      return #asked == 2
    end, "asked twice")
    assert.same({ "13.0.4  (latest)", "12.0.3  (same major)", "12.0.1  (installed)" }, asked[2])
    assert.equals(PROJECT[3], line(buf, 3), "the installed version changes nothing")
  end)

  it("asks before replacing a range with the latest version", function()
    answering(2)
    local buf = open("Api.csproj", PROJECT)
    vim.api.nvim_win_set_cursor(0, { 9, 0 })
    inline.update()
    wait_for(function()
      return #asked > 0
    end, "asked")
    assert.same({ "Replace [1.0,2.0) with 2.1.0", "Cancel" }, asked[1])
    assert.equals(PROJECT[9], line(buf, 9), "cancelled")
    answering(1)
    inline.update()
    wait_for(function()
      return line(buf, 9):find('"2.1.0"', 1, true) ~= nil
    end, "replaced")
  end)

  it("replaces a floating version after asking", function()
    answering(1)
    local buf = open("Api.csproj", { '<PackageReference Include="Serilog" Version="4.*" />' })
    inline.update()
    wait_for(function()
      return line(buf, 1):find('"4.4.0"', 1, true) ~= nil
    end, "replaced")
    assert.same({ "Replace 4.* with 4.4.0", "Cancel" }, asked[1])
  end)

  it("changes a version written as a child element, from anywhere in the item", function()
    answering(1)
    local buf = open("Api.csproj", PROJECT)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    inline.version()
    wait_for(function()
      return #asked > 0
    end, "asked")
    assert.same({ "4.4.0  (latest, installed)", "4.3.0" }, asked[1])
    answering(2)
    asked = {}
    inline.version()
    wait_for(function()
      return #asked > 0
    end, "asked")
    assert.equals("      <Version>4.3.0</Version>", line(buf, 5))
  end)

  it("lists the versions from the feeds for a package nuget.org does not have", function()
    answering(1)
    local buf = open("Api.csproj", PROJECT)
    vim.api.nvim_win_set_cursor(0, { 12, 0 })
    inline.version()
    wait_for(function()
      return #asked > 0
    end, "asked")
    assert.equals("Private.Feed", feeds_asked[1].id)
    assert.equals(vim.uv.fs_realpath(dir), vim.uv.fs_realpath(feeds_asked[1].opts.cwd))
    assert.matches('"9%.0%.0"', line(buf, 12))
  end)

  it("asks the feeds when the quick checks are off", function()
    fast.enabled = function()
      return false
    end
    answering(1)
    local buf = open("Api.csproj", PROJECT)
    vim.wait(100)
    assert.same({}, shown(buf))
    assert.same({}, latest_calls)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    inline.version()
    wait_for(function()
      return #asked > 0
    end, "asked")
    assert.equals("Newtonsoft.Json", feeds_asked[1].id)
  end)

  it("leaves a version written as a property alone", function()
    local buf = open("Api.csproj", PROJECT)
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    inline.update()
    assert.is_true(said("MSBuild property %$%(PropVersion%)"))
    assert.equals(PROJECT[8], line(buf, 8))
  end)

  it("says when the file cannot be changed", function()
    local buf = open("Api.csproj", PROJECT)
    vim.bo[buf].modifiable = false
    vim.api.nvim_win_set_cursor(0, { 11, 0 })
    inline.update()
    assert.is_true(said("not modifiable"))
    assert.equals(PROJECT[11], line(buf, 11))
  end)

  it("shows a central version on the reference, goes to it, and follows its saves", function()
    vim.fn.writefile({
      "<Project>",
      "  <PropertyGroup>",
      "    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>",
      "  </PropertyGroup>",
      "  <ItemGroup>",
      '    <PackageVersion Include="Newtonsoft.Json" Version="12.0.1" />',
      "  </ItemGroup>",
      "</Project>",
    }, dir .. "/Directory.Packages.props")
    local buf = open("Api.csproj", {
      '<Project Sdk="Microsoft.NET.Sdk">',
      '  <ItemGroup><PackageReference Include="Newtonsoft.Json" /></ItemGroup>',
      "</Project>",
    })
    local t = wait_shown(buf, 2)
    assert.matches("↑ 13%.0%.4 major", t[2])
    assert.matches(require("nuget").config.icons.central, t[2], 1, true)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    inline.update()
    assert.matches("Directory%.Packages%.props$", vim.api.nvim_buf_get_name(0))
    assert.equals(6, vim.api.nvim_win_get_cursor(0)[1])
    assert.is_true(said("The version of Newtonsoft.Json is in Directory.Packages.props"))
    -- Updated and saved there: the project shows it is up to date
    answering(1)
    inline.update()
    wait_for(function()
      return line(0, 6):find("13.0.4", 1, true) ~= nil
    end, "updated")
    assert.is_true(said("for every project that uses it"))
    vim.cmd("silent write")
    wait_for(function()
      return shown(buf)[2] == nil
    end, "the project follows the saved central version")
  end)

  it("says when there is no package under the cursor", function()
    open("Api.csproj", PROJECT)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    inline.update()
    assert.is_true(said("No package under the cursor"))
  end)

  it("maps the keys asked for, and takes them away when turned off", function()
    require("nuget").setup({ inline = { enabled = true, keys = { update = "<leader>xu", version = "<leader>xv" } } })
    local buf = open("Api.csproj", PROJECT)
    assert.equals(1, vim.fn.maparg("<leader>xu", "n", false, true).buffer)
    require("nuget").setup({ inline = { enabled = true, keys = { update = "<leader>yu" } } })
    assert.equals("", vim.fn.maparg("<leader>xu", "n"), "the keys of the previous config are gone")
    assert.equals("", vim.fn.maparg("<leader>xv", "n"))
    assert.not_equals("", vim.fn.maparg("<leader>yu", "n"))
    require("nuget").setup({})
    assert.equals("", vim.fn.maparg("<leader>yu", "n"))
    assert.is_nil(vim.b[buf].nuget_inline_keys)
  end)

  it("turns on and off with :Nuget inline, and says why nothing can show", function()
    local buf = open("Api.csproj", PROJECT)
    wait_shown(buf, 3)
    inline.toggle()
    assert.is_false(inline.is_enabled())
    assert.same({}, shown(buf))
    assert.is_true(said("Versions in project files: off"))
    fast.why_disabled = function()
      return "curl is not installed"
    end
    inline.toggle()
    assert.is_true(inline.is_enabled())
    assert.is_true(said("nuget%.org cannot be asked: curl is not installed"))
  end)

  it("routes :Nuget update, version and inline, and still searches for a package named after them", function()
    if vim.fn.exists(":Nuget") ~= 2 then
      vim.cmd.runtime("plugin/nuget.lua")
    end
    local called, opened = {}, {}
    local nuget = require("nuget")
    local stubs = { update = inline.update, version = inline.version, toggle = inline.toggle, open = nuget.open }
    for _, name in ipairs({ "update", "version", "toggle" }) do
      inline[name] = function()
        table.insert(called, name)
      end
    end
    nuget.open = function(opts)
      table.insert(opened, opts)
    end
    vim.cmd("Nuget update")
    vim.cmd("Nuget version")
    vim.cmd("Nuget inline")
    vim.cmd("Nuget update foo")
    inline.update, inline.version, inline.toggle, nuget.open = stubs.update, stubs.version, stubs.toggle, stubs.open
    assert.same({ "update", "version", "toggle" }, called)
    assert.same({ { query = "update foo" } }, opened)
  end)
end)
