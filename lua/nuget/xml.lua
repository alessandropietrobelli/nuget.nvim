-- Finds and edits package items in MSBuild files as text, so everything else in the file
-- (formatting, comments, other items) stays exactly as it was.
--
-- Only what the SDK cannot edit goes through here: items in Directory.Build.props and
-- GlobalPackageReference (`dotnet add` refuses "items in imported files").
local M = {}

--- The text with comments blanked out (same length, so positions still match the original).
---@param text string
---@return string
local function without_comments(text)
  return (text:gsub("<!%-%-.-%-%->", function(c)
    return (c:gsub("[^\n]", " "))
  end))
end

--- Attributes of a start tag body, by lower-case name: { name = {value, start, stop} } where
--- start/stop are the positions of the value inside the whole text.
---@param text string
---@param from integer position just after the tag name
---@param to integer position of the closing `>`
local function attributes(text, from, to)
  local attrs = {}
  local pos = from
  while pos < to do
    local s, e, name, quote = text:find("([%w_:%.%-]+)%s*=%s*([\"'])", pos)
    if not s or s >= to then
      break
    end
    local close = text:find(quote, e + 1, true)
    if not close or close > to then
      break
    end
    attrs[name:lower()] = { value = text:sub(e + 1, close - 1), start = e + 1, stop = close - 1 }
    pos = close + 1
  end
  return attrs
end

---@class NugetXmlItem
---@field start integer first character of the element
---@field stop integer last character of the element
---@field attrs table<string, {value: string, start: integer, stop: integer}>
---@field children table<string, {value: string, start: integer, stop: integer}> <Version>…</Version> and the like

--- Whether an Include/Update value names the package (it can be a `;` separated list).
---@param value string?
---@param id string
local function names(value, id)
  if not value then
    return false
  end
  for part in value:gmatch("[^;]+") do
    if vim.trim(part):lower() == id:lower() then
      return true
    end
  end
  return false
end

--- Every `<tag Include="id" …>` (or Update="id") element in the text.
---@param text string
---@param tag string PackageReference | PackageVersion | GlobalPackageReference
---@param id string
---@return NugetXmlItem[]
function M.find(text, tag, id)
  local clean = without_comments(text)
  local items = {}
  local pos = 1
  while true do
    local s, e = clean:find("<" .. tag .. "[%s/>]", pos)
    if not s then
      break
    end
    local gt = clean:find(">", e, true)
    if not gt then
      break
    end
    local self_closing = clean:sub(gt - 1, gt - 1) == "/"
    local attrs = attributes(clean, s + #tag + 1, gt)
    local stop, children = gt, {}
    if not self_closing then
      local close_s, close_e = clean:find("</" .. tag .. "%s*>", gt)
      if not close_s then
        break
      end
      stop = close_e
      local body_from = gt + 1
      for child, value_s, value, value_e in
        clean:sub(body_from, close_s - 1):gmatch("<([%w]+)[^>]*>()([^<]*)()</%1%s*>")
      do
        children[child:lower()] = {
          value = vim.trim(value),
          start = body_from + value_s - 1,
          stop = body_from + value_e - 2,
        }
      end
    end
    local include = attrs.include or attrs.update
    if include and names(include.value, id) then
      table.insert(items, { start = s, stop = stop, attrs = attrs, children = children })
    end
    pos = stop + 1
  end
  return items
end

--- The version an item sets, and where: an attribute, or a child element of that name.
---@param item NugetXmlItem
---@param name string "version" | "versionoverride"
---@return {value: string, start: integer, stop: integer}?
function M.version_of(item, name)
  return item.attrs[name] or item.children[name]
end

--- Replace the version an item sets. Fails rather than overwrite an MSBuild property reference.
---@param text string
---@param tag string
---@param id string
---@param name string "version" | "versionoverride"
---@param version string
---@return string? text, string? error
function M.set_version(text, tag, id, name, version)
  local found
  for _, item in ipairs(M.find(text, tag, id)) do
    if M.version_of(item, name) then
      found = found or item
    end
  end
  if not found then
    return nil, ("no %s for %s with a %s"):format(tag, id, name)
  end
  local v = M.version_of(found, name)
  if v.value:find("$(", 1, true) then
    return nil, ("the version of %s is the MSBuild property %s: edit that property by hand"):format(id, v.value)
  end
  return text:sub(1, v.start - 1) .. version .. text:sub(v.stop + 1)
end

--- Remove the item from the text, together with its line when it is alone on it.
---@param text string
---@param tag string
---@param id string
---@return string? text, string? error
function M.remove(text, tag, id)
  local item = M.find(text, tag, id)[1]
  if not item then
    return nil, ("no %s for %s"):format(tag, id)
  end
  local include = (item.attrs.include or item.attrs.update or {}).value or ""
  if include:find(";", 1, true) then
    return nil, ("%s is listed together with other packages; remove it by hand"):format(id)
  end
  local s, e = item.start, item.stop
  local line_start = s
  while line_start > 1 and text:sub(line_start - 1, line_start - 1):match("[ \t]") do
    line_start = line_start - 1
  end
  local line_end = e
  while text:sub(line_end + 1, line_end + 1):match("[ \t]") do
    line_end = line_end + 1
  end
  local at_line_start = line_start == 1 or text:sub(line_start - 1, line_start - 1) == "\n"
  local at_line_end = text:sub(line_end + 1, line_end + 1) == "\n"
  if at_line_start and at_line_end then
    return text:sub(1, line_start - 1) .. text:sub(line_end + 2)
  end
  return text:sub(1, s - 1) .. text:sub(e + 1)
end

---@param path string
---@return string?
function M.read(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  return text
end

---@param path string
---@param text string
---@return boolean ok, string? error
function M.write(path, text)
  local f, err = io.open(path, "wb")
  if not f then
    return false, err
  end
  f:write(text)
  f:close()
  return true
end

return M
