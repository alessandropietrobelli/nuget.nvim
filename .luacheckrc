std = "lua51"
cache = true

globals = {
  "vim",
}

max_line_length = 120

exclude_files = {
  "deps/",
}

files["tests/"] = {
  std = "+busted",
}
