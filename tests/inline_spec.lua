-- Versions shown inside project files, against a fake nuget.org.
local fast = require("nuget.fast")
local inline = require("nuget.inline")
local registry = require("nuget.registry")
local solution = require("nuget.solution")
local xml = require("nuget.xml")

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

  before_each(function()
    dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    solution.clear_cache()
    inline.clear_cache()
    saved = {
      enabled = fast.enabled,
      latest = fast.latest,
      advisories = fast.advisories,
      fetch = registry.fetch,
      select = vim.ui.select,
      notify = vim.notify,
    }
    fast.enabled = function()
      return true
    end
    fast.latest = function(ids, _, on_result, on_done)
      vim.schedule(function()
        for _, id in ipairs(ids) do
          local versions = VERSIONS[id:lower()]
          if versions then
            on_result(id, versions[#versions], versions)
          end
        end
        on_done()
      end)
      return { cancel = function() end }
    end
    fast.advisories = function(cb)
      vim.schedule(function()
        cb({ ["newtonsoft.json"] = { { url = "https://advisory", severity = "High", versions = "[12.0.0, 12.0.3)" } } })
      end)
    end
    registry.clear_cache()
    registry.fetch = function(id, version, cb)
      vim.schedule(function()
        cb({ id = id, version = version, deprecation = id == "Old" and { reasons = { "Legacy" } } or nil })
      end)
    end
    asked, messages = {}, {}
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, level)
      table.insert(messages, { msg = msg, level = level })
    end
    require("nuget").setup({ inline = { enabled = true } })
  end)

  after_each(function()
    require("nuget").setup({})
    fast.enabled, fast.latest, fast.advisories = saved.enabled, saved.latest, saved.advisories
    registry.fetch = saved.fetch
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

  local function wait_shown(buf, line)
    vim.wait(2000, function()
      return shown(buf)[line] ~= nil
    end, 10)
    return shown(buf)
  end

  local function said(pattern)
    return vim.iter(messages):any(function(m)
      return m.msg:find(pattern) ~= nil
    end)
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

  it("lists every item of the tags asked, in file order", function()
    local items = xml.items('<PackageVersion Include="B" Version="2" /><PackageReference Include="A" />', {
      "PackageReference",
      "PackageVersion",
    })
    assert.same({ "PackageVersion", "PackageReference" }, { items[1].tag, items[2].tag })
  end)

  it("shows the update and its kind, vulnerabilities and deprecation, and nothing else", function()
    local buf = open("Api.csproj", PROJECT)
    wait_shown(buf, 11)
    vim.wait(200)
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

  it("shows nothing when it is not turned on", function()
    require("nuget").setup({})
    local buf = open("Api.csproj", PROJECT)
    vim.wait(200)
    assert.same({}, shown(buf))
    assert.is_false(inline.is_enabled())
  end)

  it("follows the edits", function()
    local buf = open("Api.csproj", PROJECT)
    wait_shown(buf, 3)
    vim.api.nvim_buf_set_lines(
      buf,
      2,
      3,
      false,
      { '    <PackageReference Include="Newtonsoft.Json" Version="13.0.4" />' }
    )
    vim.wait(1000, function()
      return shown(buf)[3] == nil
    end, 10)
    assert.is_nil(shown(buf)[3])
  end)

  it("updates a minor in place, in the attribute the version is in", function()
    local buf = open("Api.csproj", PROJECT)
    vim.api.nvim_win_set_cursor(0, { 11, 0 })
    inline.update()
    vim.wait(1000, function()
      return vim.api.nvim_buf_get_lines(buf, 10, 11, false)[1]:find("1.2.0", 1, true) ~= nil
    end, 10)
    assert.equals(
      '    <PackageReference Include="Old" VersionOverride="1.2.0" />',
      vim.api.nvim_buf_get_lines(buf, 10, 11, false)[1]
    )
    assert.is_true(vim.bo[buf].modified, "not saved")
    vim.cmd("silent undo")
    assert.equals(PROJECT[11], vim.api.nvim_buf_get_lines(buf, 10, 11, false)[1])
  end)

  it("asks between the latest and the same major for a major", function()
    answering(2)
    local buf = open("Api.csproj", PROJECT)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    inline.update()
    vim.wait(1000, function()
      return #asked > 0
    end, 10)
    assert.same({ "Update to 13.0.4 (major)", "Update to 12.0.3 (same major)", "Choose version…" }, asked[1])
    assert.matches('Version="12%.0%.3"', vim.api.nvim_buf_get_lines(buf, 2, 3, false)[1])
  end)

  it("changes a version written as a child element, from anywhere in the item", function()
    answering(1)
    local buf = open("Api.csproj", PROJECT)
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    inline.version()
    vim.wait(1000, function()
      return #asked > 0
    end, 10)
    assert.same({ "4.4.0  (latest, installed)", "4.3.0" }, asked[1])
    answering(2)
    asked = {}
    inline.version()
    vim.wait(1000, function()
      return #asked > 0
    end, 10)
    assert.equals("      <Version>4.3.0</Version>", vim.api.nvim_buf_get_lines(buf, 4, 5, false)[1])
  end)

  it("leaves a version written as a property alone", function()
    local buf = open("Api.csproj", PROJECT)
    vim.api.nvim_win_set_cursor(0, { 8, 0 })
    inline.update()
    assert.is_true(said("MSBuild property %$%(PropVersion%)"))
    assert.equals(PROJECT[8], vim.api.nvim_buf_get_lines(buf, 7, 8, false)[1])
  end)

  it("shows a central version on the reference, and goes to it", function()
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
  end)

  it("says when there is no package under the cursor", function()
    open("Api.csproj", PROJECT)
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    inline.update()
    assert.is_true(said("No package under the cursor"))
  end)
end)
