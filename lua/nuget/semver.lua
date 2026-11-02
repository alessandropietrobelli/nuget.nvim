-- NuGet version parsing and ordering (SemVer 2.0 plus the legacy fourth number).
local M = {}

---@class NugetVersion
---@field parts integer[] major, minor, patch, revision
---@field pre string[]? prerelease identifiers, nil for a stable version
---@field raw string

---@param s string
---@return NugetVersion?
function M.parse(s)
  if type(s) ~= "string" then
    return nil
  end
  local raw = vim.trim(s)
  -- Build metadata never takes part in ordering
  local core, pre = raw:gsub("%+.*$", ""):match("^v?([%d%.]+)%-?(.*)$")
  if not core or core == "" then
    return nil
  end
  local parts = {}
  for n in core:gmatch("%d+") do
    table.insert(parts, tonumber(n))
  end
  if #parts == 0 then
    return nil
  end
  for i = #parts + 1, 4 do
    parts[i] = 0
  end
  local identifiers
  if pre ~= "" then
    identifiers = vim.split(pre, ".", { plain = true })
  end
  return { parts = parts, pre = identifiers, raw = raw }
end

--- Order two prerelease identifier lists: numeric identifiers compare as numbers and sort
--- before alphanumeric ones, a shorter list sorts first when all shared identifiers match.
local function compare_pre(a, b)
  for i = 1, math.max(#a, #b) do
    local x, y = a[i], b[i]
    if x == nil then
      return -1
    elseif y == nil then
      return 1
    end
    local nx, ny = tonumber(x), tonumber(y)
    if nx and ny then
      if nx ~= ny then
        return nx < ny and -1 or 1
      end
    elseif nx then
      return -1
    elseif ny then
      return 1
    else
      local lx, ly = x:lower(), y:lower()
      if lx ~= ly then
        return lx < ly and -1 or 1
      end
    end
  end
  return 0
end

--- -1, 0 or 1. Unparseable versions sort before everything else.
---@param a string|NugetVersion
---@param b string|NugetVersion
---@return integer
function M.compare(a, b)
  local va = type(a) == "table" and a or M.parse(a --[[@as string]])
  local vb = type(b) == "table" and b or M.parse(b --[[@as string]])
  if not va or not vb then
    if va then
      return 1
    elseif vb then
      return -1
    end
    return 0
  end
  for i = 1, 4 do
    if va.parts[i] ~= vb.parts[i] then
      return va.parts[i] < vb.parts[i] and -1 or 1
    end
  end
  -- A release sorts after its prereleases
  if va.pre and not vb.pre then
    return -1
  elseif vb.pre and not va.pre then
    return 1
  elseif va.pre and vb.pre then
    return compare_pre(va.pre, vb.pre)
  end
  return 0
end

---@param s string
---@return boolean
function M.is_prerelease(s)
  local v = M.parse(s)
  return v ~= nil and v.pre ~= nil
end

--- The concrete version a requested version names. Ranges and floating versions
--- ("[1.0,2.0)", "1.*") have no single version, so the resolved one is used instead.
---@param requested string?
---@param resolved string?
---@return string?
function M.effective(requested, resolved)
  if requested and requested:match("^[%d%.]+[%w%.%-]*$") then
    return requested
  end
  return resolved or requested
end

--- Highest of a list of versions, optionally ignoring prereleases.
---@param versions string[]
---@param include_prerelease boolean?
---@return string?
function M.max(versions, include_prerelease)
  local best
  for _, v in ipairs(versions) do
    if (include_prerelease or not M.is_prerelease(v)) and (not best or M.compare(v, best) > 0) then
      best = v
    end
  end
  return best
end

--- Whether `version` falls in a NuGet version range: "(, 13.0.1)", "[1.0, 2.0)", "[1.0]",
--- or a bare "1.0", which means "1.0 or higher".
---@param version string
---@param range string
---@return boolean
function M.in_range(version, range)
  range = vim.trim(range or "")
  if range == "" or range == "*" then
    return true
  end
  local open, body, close = range:match("^([%[%(])(.*)([%]%)])$")
  if not open then
    return M.compare(version, range) >= 0
  end
  local low, high = body:match("^%s*([^,]*)%s*,%s*([^,]*)%s*$")
  if not low then
    -- "[1.0]": exactly that version
    return M.compare(version, vim.trim(body)) == 0
  end
  low, high = vim.trim(low), vim.trim(high)
  if low ~= "" then
    local c = M.compare(version, low)
    if c < 0 or (c == 0 and open == "(") then
      return false
    end
  end
  if high ~= "" then
    local c = M.compare(version, high)
    if c > 0 or (c == 0 and close == ")") then
      return false
    end
  end
  return true
end

--- Sort versions newest first.
---@param versions string[]
---@return string[]
function M.sort_desc(versions)
  local copy = vim.list_slice(versions)
  table.sort(copy, function(a, b)
    return M.compare(a, b) > 0
  end)
  return copy
end

return M
