-- Thin async wrappers around the dotnet CLI. Everything NuGet-related goes through it, so
-- nuget.config, private feeds and their credentials behave exactly as in a terminal.
local M = {}

M.cmd = "dotnet"

---@class NugetJob
---@field kill fun()

--- Run dotnet and hand back its output on the main loop.
---@param args string[]
---@param opts {cwd: string?}?
---@param cb fun(ok: boolean, stdout: string, stderr: string)
---@return NugetJob
function M.run(args, opts, cb)
  opts = opts or {}
  local cancelled = false
  -- A folder that is gone (a project moved meanwhile) would fail the spawn itself; every path
  -- in the arguments is absolute, so running from the current directory is just as good
  local cwd = opts.cwd and vim.fn.isdirectory(opts.cwd) == 1 and opts.cwd or nil
  local ok_spawn, proc = pcall(vim.system, vim.list_extend({ M.cmd }, args), {
    text = true,
    cwd = cwd,
    env = { DOTNET_CLI_UI_LANGUAGE = "en", DOTNET_NOLOGO = "1" },
  }, function(result)
    vim.schedule(function()
      if not cancelled then
        cb(result.code == 0, result.stdout or "", result.stderr or "")
      end
    end)
  end)
  if not ok_spawn then
    vim.schedule(function()
      cb(false, "", tostring(proc))
    end)
    return { kill = function() end }
  end
  return {
    kill = function()
      cancelled = true
      pcall(proc.kill, proc, "sigterm")
    end,
  }
end

--- The JSON document in a command's output, which may be preceded by build or restore noise.
---@param text string
---@return table?
function M.decode(text)
  local first = text:find("{", 1, true)
  if not first then
    return nil
  end
  local last
  for i = #text, first, -1 do
    if text:sub(i, i) == "}" then
      last = i
      break
    end
  end
  if not last then
    return nil
  end
  local ok, data = pcall(vim.json.decode, text:sub(first, last), { luanil = { object = true, array = true } })
  return ok and type(data) == "table" and data or nil
end

--- The most useful line of a failed command's output.
---@param stdout string
---@param stderr string
---@return string
function M.error_message(stdout, stderr)
  local text = (stderr ~= "" and stderr or stdout)
  for line in text:gmatch("[^\r\n]+") do
    local msg = line:match("[Ee]rror%s*:?%s*(.+)$") or line:match("error NU%d+:%s*(.+)$")
    if msg then
      return vim.trim(msg)
    end
  end
  local first = vim.trim(text):match("^[^\r\n]+")
  return first or "dotnet failed without output"
end

---@alias NugetListKind "plain"|"outdated"|"vulnerable"|"deprecated"|"transitive"

local LIST_FLAGS = {
  plain = {},
  outdated = { "--outdated" },
  vulnerable = { "--vulnerable", "--include-transitive" },
  deprecated = { "--deprecated" },
  transitive = { "--include-transitive" },
}

--- `dotnet list package` for a solution or a set of projects, merged into one report.
---@param target NugetTarget
---@param kind NugetListKind
---@param opts {prerelease: boolean?, sources: string[]?}
---@param cb fun(report: {projects: table[], problems: string[]})
---@return NugetJob
function M.list(target, kind, opts, cb)
  local args = vim.list_extend({}, LIST_FLAGS[kind])
  if kind == "outdated" and opts.prerelease then
    table.insert(args, "--include-prerelease")
  end
  if kind == "outdated" or kind == "vulnerable" or kind == "deprecated" then
    for _, source in ipairs(opts.sources or {}) do
      vim.list_extend(args, { "--source", source })
    end
  end
  vim.list_extend(args, { "--format", "json", "--output-version", "1" })

  local paths = target.kind == "solution" and { target.path } or target.projects or {}
  local report = { projects = {}, problems = {} }
  local pending = #paths
  local jobs = {}
  if pending == 0 then
    vim.schedule(function()
      cb(report)
    end)
  end
  for _, path in ipairs(paths) do
    local job_args = vim.list_extend({ "list", path, "package" }, args)
    table.insert(
      jobs,
      M.run(job_args, { cwd = vim.fs.dirname(path) }, function(ok, stdout, stderr)
        local data = M.decode(stdout)
        if data then
          vim.list_extend(report.projects, data.projects or {})
          for _, p in ipairs(data.problems or {}) do
            table.insert(report.problems, p.text or vim.inspect(p))
          end
        end
        if not ok or not data then
          table.insert(report.problems, M.error_message(stdout, stderr))
        end
        pending = pending - 1
        if pending == 0 then
          cb(report)
        end
      end)
    )
  end
  return {
    kill = function()
      for _, job in ipairs(jobs) do
        job.kill()
      end
    end,
  }
end

---@class NugetSearchResult
---@field id string
---@field version string latest version
---@field downloads integer?
---@field owners string?
---@field description string?
---@field project_url string?
---@field source string

--- `dotnet package search`, flattened over all sources. Failing sources become problems.
---@param query string
---@param opts {take: integer, skip: integer?, prerelease: boolean?, sources: string[]?, cwd: string?}
---@param cb fun(results: NugetSearchResult[], problems: string[])
---@return NugetJob
function M.search(query, opts, cb)
  local args = {
    "package",
    "search",
    query,
    "--take",
    tostring(opts.take),
    "--skip",
    tostring(opts.skip or 0),
    "--format",
    "json",
    "--verbosity",
    "detailed",
  }
  if opts.prerelease then
    table.insert(args, "--prerelease")
  end
  for _, source in ipairs(opts.sources or {}) do
    vim.list_extend(args, { "--source", source })
  end
  return M.run(args, { cwd = opts.cwd }, function(ok, stdout, stderr)
    local data = M.decode(stdout)
    if not data then
      return cb({}, { ok and "Unreadable search output" or M.error_message(stdout, stderr) })
    end
    local results, problems = {}, {}
    for _, p in ipairs(data.problems or {}) do
      table.insert(problems, p.text)
    end
    for _, source in ipairs(data.searchResult or {}) do
      for _, p in ipairs(source.problems or {}) do
        table.insert(problems, ("%s: %s"):format(source.sourceName, p.text))
      end
      for _, pkg in ipairs(source.packages or {}) do
        table.insert(results, {
          id = pkg.id,
          version = pkg.latestVersion or pkg.version,
          downloads = pkg.totalDownloads,
          owners = pkg.owners,
          description = pkg.description,
          project_url = pkg.projectUrl,
          source = source.sourceName,
        })
      end
    end
    cb(results, problems)
  end)
end

--- Every version of a package across the configured sources, newest first.
---@param id string
---@param opts {prerelease: boolean?, sources: string[]?, cwd: string?}
---@param cb fun(versions: string[], problems: string[])
---@return NugetJob
function M.versions(id, opts, cb)
  local args = { "package", "search", id, "--exact-match", "--format", "json" }
  if opts.prerelease then
    table.insert(args, "--prerelease")
  end
  for _, source in ipairs(opts.sources or {}) do
    vim.list_extend(args, { "--source", source })
  end
  return M.run(args, { cwd = opts.cwd }, function(ok, stdout, stderr)
    local data = M.decode(stdout)
    if not data then
      return cb({}, { ok and "Unreadable search output" or M.error_message(stdout, stderr) })
    end
    local seen, versions, problems = {}, {}, {}
    for _, source in ipairs(data.searchResult or {}) do
      for _, p in ipairs(source.problems or {}) do
        table.insert(problems, ("%s: %s"):format(source.sourceName, p.text))
      end
      for _, pkg in ipairs(source.packages or {}) do
        local v = pkg.version or pkg.latestVersion
        if v and not seen[v] and pkg.id:lower() == id:lower() then
          seen[v] = true
          table.insert(versions, v)
        end
      end
    end
    cb(require("nuget.semver").sort_desc(versions), problems)
  end)
end

--- Add or update a package reference. With central package management the SDK writes the
--- version to Directory.Packages.props instead of the project.
---@param project string
---@param id string
---@param version string?
---@param cb fun(ok: boolean, message: string)
---@return NugetJob
function M.add(project, id, version, cb)
  local args = { "add", project, "package", id }
  if version then
    vim.list_extend(args, { "--version", version })
  end
  return M.run(args, { cwd = vim.fs.dirname(project) }, function(ok, stdout, stderr)
    cb(ok, ok and "" or M.error_message(stdout, stderr))
  end)
end

--- Restore after a shared file was edited by hand, so the next listing sees the new versions.
---@param path string solution or project
---@param cb fun(ok: boolean, message: string)
---@return NugetJob
function M.restore(path, cb)
  return M.run({ "restore", path }, { cwd = vim.fs.dirname(path) }, function(ok, stdout, stderr)
    cb(ok, ok and "" or M.error_message(stdout, stderr))
  end)
end

---@param project string
---@param id string
---@param cb fun(ok: boolean, message: string)
---@return NugetJob
function M.remove(project, id, cb)
  return M.run({ "remove", project, "package", id }, { cwd = vim.fs.dirname(project) }, function(ok, stdout, stderr)
    cb(ok, ok and "" or M.error_message(stdout, stderr))
  end)
end

return M
