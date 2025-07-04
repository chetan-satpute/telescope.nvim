---@tag telescope.utils
---@config { ["module"] = "telescope.utils" }

---@brief [[
--- Utilities for writing telescope pickers
---@brief ]]

local Path = require "plenary.path"
local Job = require "plenary.job"

local log = require "telescope.log"

local truncate = require("plenary.strings").truncate
local get_status = require("telescope.state").get_status

local utils = {}

utils.iswin = vim.loop.os_uname().sysname == "Windows_NT"

---@param s string
---@param i number
---@param encoding "utf-8" | "utf-16" | "utf-32"
---@return integer
utils.str_byteindex = function(s, i, encoding)
  if vim.fn.has "nvim-0.11" == 1 then
    return vim.str_byteindex(s, encoding, i, false)
  else
    return vim.lsp.util._str_byteindex_enc(s, i, encoding)
  end
end

--TODO(clason): Remove when dropping support for Nvim 0.9
utils.islist = vim.fn.has "nvim-0.10" == 1 and vim.islist or vim.tbl_islist
local flatten = function(t)
  return vim.iter(t):flatten():totable()
end
utils.flatten = vim.fn.has "nvim-0.11" == 1 and flatten or vim.tbl_flatten

--- Hybrid of `vim.fn.expand()` and custom `vim.fs.normalize()`
---
--- Paths starting with '%', '#' or '<' are expanded with `vim.fn.expand()`.
--- Otherwise avoids using `vim.fn.expand()` due to its overly aggressive
--- expansion behavior which can sometimes lead to errors or the creation of
--- non-existent paths when dealing with valid absolute paths.
---
--- Other paths will have '~' and environment variables expanded.
--- Unlike `vim.fs.normalize()`, backslashes are preserved. This has better
--- compatibility with `plenary.path` and also avoids mangling valid Unix paths
--- with literal backslashes.
---
--- Trailing slashes are trimmed. With the exception of root paths.
--- eg. `/` on Unix or `C:\` on Windows
---
---@param path string
---@return string
utils.path_expand = function(path)
  vim.validate {
    path = { path, { "string" } },
  }

  if utils.is_uri(path) then
    return path
  end

  if path:match "^[%%#<]" then
    path = vim.fn.expand(path)
  end

  if path:sub(1, 1) == "~" then
    local home = vim.loop.os_homedir() or "~"
    if home:sub(-1) == "\\" or home:sub(-1) == "/" then
      home = home:sub(1, -2)
    end
    path = home .. path:sub(2)
  end

  path = path:gsub("%$([%w_]+)", vim.loop.os_getenv)
  path = path:gsub("/+", "/")
  if utils.iswin then
    path = path:gsub("\\+", "\\")
    if path:match "^%w:\\$" then
      return path
    else
      return (path:gsub("(.)\\$", "%1"))
    end
  end
  return (path:gsub("(.)/$", "%1"))
end

utils.get_separator = function()
  return Path.path.sep
end

utils.cycle = function(i, n)
  return i % n == 0 and n or i % n
end

utils.get_lazy_default = function(x, defaulter, ...)
  if x == nil then
    return defaulter(...)
  else
    return x
  end
end

utils.repeated_table = function(n, val)
  local empty_lines = {}
  for _ = 1, n do
    table.insert(empty_lines, val)
  end
  return empty_lines
end

utils.filter_symbols = function(results, opts, post_filter)
  local has_ignore = opts.ignore_symbols ~= nil
  local has_symbols = opts.symbols ~= nil
  local filtered_symbols

  if has_symbols and has_ignore then
    utils.notify("filter_symbols", {
      msg = "Either opts.symbols or opts.ignore_symbols, can't process opposing options at the same time!",
      level = "ERROR",
    })
    return {}
  elseif not (has_ignore or has_symbols) then
    return results
  elseif has_ignore then
    if type(opts.ignore_symbols) == "string" then
      opts.ignore_symbols = { opts.ignore_symbols }
    end
    if type(opts.ignore_symbols) ~= "table" then
      utils.notify("filter_symbols", {
        msg = "Please pass ignore_symbols as either a string or a list of strings",
        level = "ERROR",
      })
      return {}
    end

    opts.ignore_symbols = vim.tbl_map(string.lower, opts.ignore_symbols)
    filtered_symbols = vim.tbl_filter(function(item)
      return not vim.tbl_contains(opts.ignore_symbols, string.lower(item.kind))
    end, results)
  elseif has_symbols then
    if type(opts.symbols) == "string" then
      opts.symbols = { opts.symbols }
    end
    if type(opts.symbols) ~= "table" then
      utils.notify("filter_symbols", {
        msg = "Please pass filtering symbols as either a string or a list of strings",
        level = "ERROR",
      })
      return {}
    end

    opts.symbols = vim.tbl_map(string.lower, opts.symbols)
    filtered_symbols = vim.tbl_filter(function(item)
      return vim.tbl_contains(opts.symbols, string.lower(item.kind))
    end, results)
  end

  if type(post_filter) == "function" then
    filtered_symbols = post_filter(filtered_symbols)
  end

  if not vim.tbl_isempty(filtered_symbols) then
    return filtered_symbols
  end

  -- print message that filtered_symbols is now empty
  if has_symbols then
    local symbols = table.concat(opts.symbols, ", ")
    utils.notify("filter_symbols", {
      msg = string.format("%s symbol(s) were not part of the query results", symbols),
      level = "WARN",
    })
  elseif has_ignore then
    local symbols = table.concat(opts.ignore_symbols, ", ")
    utils.notify("filter_symbols", {
      msg = string.format("%s ignore_symbol(s) have removed everything from the query result", symbols),
      level = "WARN",
    })
  end
  return {}
end

local path_filename_first = function(path, reverse_directories)
  local dirs = vim.split(path, utils.get_separator())
  local filename

  if reverse_directories then
    dirs = utils.reverse_table(dirs)
    filename = table.remove(dirs, 1)
  else
    filename = table.remove(dirs, #dirs)
  end

  local tail = table.concat(dirs, utils.get_separator())
  -- Trim prevents a top-level filename to have a trailing white space
  local transformed_path = vim.trim(filename .. " " .. tail)
  local path_style = { { { #filename, #transformed_path }, "TelescopeResultsComment" } }

  return transformed_path, path_style
end

local calc_result_length = function(truncate_len)
  local status = get_status(vim.api.nvim_get_current_buf())
  local len = vim.api.nvim_win_get_width(status.layout.results.winid) - status.picker.selection_caret:len() - 2
  return type(truncate_len) == "number" and len - truncate_len or len
end

local path_truncate = function(path, truncate_len, opts)
  if opts.__length == nil then
    opts.__length = calc_result_length(truncate_len)
  end
  if opts.__prefix == nil then
    opts.__prefix = 0
  end
  return truncate(path, opts.__length - opts.__prefix, nil, -1)
end

local path_shorten = function(path, length, exclude)
  if exclude ~= nil then
    return Path:new(path):shorten(length, exclude)
  else
    return Path:new(path):shorten(length)
  end
end

local path_abs = function(path, opts)
  local cwd
  if opts.cwd then
    cwd = opts.cwd
    if not vim.in_fast_event() then
      cwd = utils.path_expand(opts.cwd)
    end
  else
    cwd = vim.loop.cwd()
  end
  return Path:new(path):make_relative(cwd)
end

-- IMPORTANT: This function should have been a local function as it's only used
-- in this file, but the code was already exported a long time ago. By making it
-- local we would potential break consumers of this method.
utils.path_smart = (function()
  local paths = {}
  local os_sep = utils.get_separator()
  return function(filepath)
    local final = filepath
    if #paths ~= 0 then
      local dirs = vim.split(filepath, os_sep)
      local max = 1
      for _, p in pairs(paths) do
        if #p > 0 and p ~= filepath then
          local _dirs = vim.split(p, os_sep)
          for i = 1, math.min(#dirs, #_dirs) do
            if (dirs[i] ~= _dirs[i]) and i > max then
              max = i
              break
            end
          end
        end
      end
      if #dirs ~= 0 then
        if max == 1 and #dirs >= 2 then
          max = #dirs - 2
        end
        final = ""
        for k, v in pairs(dirs) do
          if k >= max - 1 then
            final = final .. (#final > 0 and os_sep or "") .. v
          end
        end
      end
    end
    if not paths[filepath] then
      paths[filepath] = ""
      table.insert(paths, filepath)
    end
    if final and final ~= filepath then
      return ".." .. os_sep .. final
    else
      return filepath
    end
  end
end)()

utils.path_tail = (function()
  local os_sep = utils.get_separator()

  if os_sep == "/" then
    return function(path)
      for i = #path, 1, -1 do
        if path:sub(i, i) == os_sep then
          return path:sub(i + 1, -1)
        end
      end
      return path
    end
  else
    return function(path)
      for i = #path, 1, -1 do
        local c = path:sub(i, i)
        if c == os_sep or c == "/" then
          return path:sub(i + 1, -1)
        end
      end
      return path
    end
  end
end)()

utils.is_path_hidden = function(opts, path_display)
  path_display = path_display or vim.F.if_nil(opts.path_display, require("telescope.config").values.path_display)

  return path_display == nil
    or path_display == "hidden"
    or type(path_display) == "table" and (vim.tbl_contains(path_display, "hidden") or path_display.hidden)
end

utils.is_uri = function(filename)
  local char = string.byte(filename, 1) or 0

  -- is alpha?
  if char < 65 or (char > 90 and char < 97) or char > 122 then
    return false
  end

  for i = 2, #filename do
    char = string.byte(filename, i)
    if char == 58 then -- `:`
      return i < #filename and string.byte(filename, i + 1) ~= 92 -- `\`
    elseif
      not (
        (char >= 48 and char <= 57) -- 0-9
        or (char >= 65 and char <= 90) -- A-Z
        or (char >= 97 and char <= 122) -- a-z
        or char == 43 -- `+`
        or char == 46 -- `.`
        or char == 45 -- `-`
      )
    then
      return false
    end
  end
  return false
end

--- Transform path is a util function that formats a path based on path_display
--- found in `opts` or the default value from config.
--- It is meant to be used in make_entry to have a uniform interface for
--- builtins as well as extensions utilizing the same user configuration
--- Note: It is only supported inside `make_entry`/`make_display` the use of
--- this function outside of telescope might yield to undefined behavior and will
--- not be addressed by us
---@param opts table: The opts the users passed into the picker. Might contains a path_display key
---@param path string|nil: The path that should be formatted
---@return string: path to be displayed
---@return table: The transformed path ready to be displayed with the styling
utils.transform_path = function(opts, path)
  if path == nil then
    return "", {}
  end
  if utils.is_uri(path) then
    return path, {}
  end

  ---@type fun(opts:table, path: string): string, table?
  local path_display = vim.F.if_nil(opts.path_display, require("telescope.config").values.path_display)

  local transformed_path = path
  local path_style = {}

  if type(path_display) == "function" then
    local custom_transformed_path, custom_path_style = path_display(opts, transformed_path)
    return custom_transformed_path, custom_path_style or path_style
  elseif utils.is_path_hidden(nil, path_display) then
    return "", path_style
  elseif type(path_display) == "table" then
    if vim.tbl_contains(path_display, "tail") or path_display.tail then
      return utils.path_tail(transformed_path), path_style
    end

    if not vim.tbl_contains(path_display, "absolute") and not path_display.absolute then
      transformed_path = path_abs(transformed_path, opts)
    end

    if vim.tbl_contains(path_display, "smart") or path_display.smart then
      transformed_path = utils.path_smart(transformed_path)
    end

    if vim.tbl_contains(path_display, "shorten") or path_display["shorten"] ~= nil then
      local length
      local exclude = nil

      if type(path_display["shorten"]) == "table" then
        local shorten = path_display["shorten"]
        length = shorten.len
        exclude = shorten.exclude
      else
        length = type(path_display["shorten"]) == "number" and path_display["shorten"]
      end

      transformed_path = path_shorten(transformed_path, length, exclude)
    end

    if vim.tbl_contains(path_display, "truncate") or path_display.truncate then
      transformed_path = path_truncate(transformed_path, path_display.truncate, opts)
    end

    if vim.tbl_contains(path_display, "filename_first") or path_display["filename_first"] ~= nil then
      local reverse_directories = false

      if type(path_display["filename_first"]) == "table" then
        local filename_first_opts = path_display["filename_first"]

        if filename_first_opts.reverse_directories == nil or filename_first_opts.reverse_directories == false then
          reverse_directories = false
        else
          reverse_directories = filename_first_opts.reverse_directories
        end
      end

      transformed_path, path_style = path_filename_first(transformed_path, reverse_directories)
    end

    return transformed_path, path_style
  else
    log.warn("`path_display` must be either a function or a table.", "See `:help telescope.defaults.path_display.")
    return transformed_path, path_style
  end
end

-- local x = utils.make_default_callable(function(opts)
--   return function()
--     print(opts.example, opts.another)
--   end
-- end, { example = 7, another = 5 })

-- x()
-- x.new { example = 3 }()
function utils.make_default_callable(f, default_opts)
  default_opts = default_opts or {}

  return setmetatable({
    new = function(opts)
      opts = vim.tbl_extend("keep", opts, default_opts)
      return f(opts)
    end,
  }, {
    __call = function()
      local ok, err = pcall(f(default_opts))
      if not ok then
        error(debug.traceback(err))
      end
    end,
  })
end

function utils.job_is_running(job_id)
  if job_id == nil then
    return false
  end
  return vim.fn.jobwait({ job_id }, 0)[1] == -1
end

function utils.buf_delete(bufnr)
  if bufnr == nil then
    return
  end

  -- Suppress the buffer deleted message for those with &report<2
  local start_report = vim.o.report
  if start_report < 2 then
    vim.o.report = 2
  end

  if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end

  if start_report < 2 then
    vim.o.report = start_report
  end
end

function utils.win_delete(name, win_id, force, bdelete)
  if win_id == nil or not vim.api.nvim_win_is_valid(win_id) then
    return
  end

  local bufnr = vim.api.nvim_win_get_buf(win_id)
  if bdelete then
    utils.buf_delete(bufnr)
  end

  if not vim.api.nvim_win_is_valid(win_id) then
    return
  end

  if not pcall(vim.api.nvim_win_close, win_id, force) then
    log.trace("Unable to close window: ", name, "/", win_id)
  end
end

function utils.max_split(s, pattern, maxsplit)
  pattern = pattern or " "
  maxsplit = maxsplit or -1

  local t = {}

  local curpos = 0
  while maxsplit ~= 0 and curpos < #s do
    local found, final = string.find(s, pattern, curpos, false)
    if found ~= nil then
      local val = string.sub(s, curpos, found - 1)

      if #val > 0 then
        maxsplit = maxsplit - 1
        table.insert(t, val)
      end

      curpos = final + 1
    else
      table.insert(t, string.sub(s, curpos))
      break
      -- curpos = curpos + 1
    end

    if maxsplit == 0 then
      table.insert(t, string.sub(s, curpos))
    end
  end

  return t
end

-- IMPORTANT: This function should have been a local function as it's only used
-- in this file, but the code was already exported a long time ago. By making it
-- local we would potential break consumers of this method.
function utils.data_directory()
  local sourced_file = require("plenary.debug_utils").sourced_filepath()
  local base_directory = vim.fn.fnamemodify(sourced_file, ":h:h:h")

  return Path:new({ base_directory, "data" }):absolute() .. Path.path.sep
end

function utils.buffer_dir()
  return vim.fn.expand "%:p:h"
end

function utils.display_termcodes(str)
  return str:gsub(string.char(9), "<TAB>"):gsub("", "<C-F>"):gsub(" ", "<Space>")
end

function utils.get_os_command_output(cmd, cwd)
  if type(cmd) ~= "table" then
    utils.notify("get_os_command_output", {
      msg = "cmd has to be a table",
      level = "ERROR",
    })
    return {}
  end
  local command = table.remove(cmd, 1)
  local stderr = {}
  local stdout, ret = Job:new({
    command = command,
    args = cmd,
    cwd = cwd,
    on_stderr = function(_, data)
      table.insert(stderr, data)
    end,
  }):sync()
  return stdout, ret, stderr
end

function utils.win_set_buf_noautocmd(win, buf)
  local save_ei = vim.o.eventignore
  vim.o.eventignore = "all"
  vim.api.nvim_win_set_buf(win, buf)
  vim.o.eventignore = save_ei
end

local load_once = function(f)
  local resolved = nil
  return function(...)
    if resolved == nil then
      resolved = f()
    end

    return resolved(...)
  end
end

-- IMPORTANT: This function should have been a local function as it's only used
-- in this file, but the code was already exported a long time ago. By making it
-- local we would potential break consumers of this method.
utils.file_extension = function(filename)
  local parts = vim.split(filename, "%.")
  -- this check enables us to get multi-part extensions, like *.test.js for example
  if #parts > 2 then
    return table.concat(vim.list_slice(parts, #parts - 1), ".")
  else
    return table.concat(vim.list_slice(parts, #parts), ".")
  end
end

utils.transform_devicons = load_once(function()
  local has_devicons, devicons = pcall(require, "nvim-web-devicons")

  if has_devicons then
    if not devicons.has_loaded() then
      devicons.setup()
    end

    return function(filename, display, disable_devicons, icon_separator)
      icon_separator = icon_separator or " "

      local conf = require("telescope.config").values
      if disable_devicons or not filename then
        return display
      end

      local basename = utils.path_tail(filename)
      local icon, icon_highlight = devicons.get_icon(basename, utils.file_extension(basename), { default = false })
      if not icon then
        icon, icon_highlight = devicons.get_icon(basename, nil, { default = true })
        icon = icon or " "
      end
      local icon_display = icon .. icon_separator .. (display or "")

      if conf.color_devicons then
        return icon_display, icon_highlight, icon
      else
        return icon_display, nil, icon
      end
    end
  else
    return function(_, display, _)
      return display
    end
  end
end)

utils.get_devicons = load_once(function()
  local has_devicons, devicons = pcall(require, "nvim-web-devicons")

  if has_devicons then
    if not devicons.has_loaded() then
      devicons.setup()
    end

    return function(filename, disable_devicons)
      local conf = require("telescope.config").values
      if disable_devicons or not filename then
        return ""
      end

      local basename = utils.path_tail(filename)
      local icon, icon_highlight = devicons.get_icon(basename, utils.file_extension(basename), { default = false })
      if not icon then
        icon, icon_highlight = devicons.get_icon(basename, nil, { default = true })
      end
      if conf.color_devicons then
        return icon, icon_highlight
      else
        return icon, nil
      end
    end
  else
    return function(_, _)
      return ""
    end
  end
end)

--- Checks if treesitter parser for language is installed
---@param lang string
utils.has_ts_parser = function(lang)
  if vim.fn.has "nvim-0.11" == 1 then
    return vim.treesitter.language.add(lang)
  else
    return pcall(vim.treesitter.language.add, lang)
  end
end

--- Telescope Wrapper around vim.notify
---@param funname string: name of the function that will be
---@param opts table: opts.level string, opts.msg string, opts.once bool
utils.notify = function(funname, opts)
  opts.once = vim.F.if_nil(opts.once, false)
  local level = vim.log.levels[opts.level]
  if not level then
    error("Invalid error level", 2)
  end
  local notify_fn = opts.once and vim.notify_once or vim.notify
  notify_fn(string.format("[telescope.%s]: %s", funname, opts.msg), level, {
    title = "telescope.nvim",
  })
end

utils.__warn_no_selection = function(name)
  utils.notify(name, {
    msg = "Nothing currently selected",
    level = "WARN",
  })
end

--- Generate git command optionally with git env variables
---@param args string[]
---@param opts? table
---@return string[]
utils.__git_command = function(args, opts)
  opts = opts or {}

  local _args = { "git" }
  if opts.gitdir then
    vim.list_extend(_args, { "--git-dir", opts.gitdir })
  end
  if opts.toplevel then
    vim.list_extend(_args, { "--work-tree", opts.toplevel })
  end

  return vim.list_extend(_args, args)
end

utils.list_find = function(func, list)
  for i, v in ipairs(list) do
    if func(v, i, list) then
      return i, v
    end
  end
end

--- Takes the path and parses optional cursor location `$file:$line:$column`
--- If line or column not present `0` returned.
---@param path string
---@return string path
---@return integer? lnum
---@return integer? col
utils.__separate_file_path_location = function(path)
  local location_numbers = {}
  for i = #path, 1, -1 do
    if path:sub(i, i) == ":" then
      if i == #path then
        path = path:sub(1, i - 1)
      else
        local location_value = tonumber(path:sub(i + 1))
        if location_value then
          table.insert(location_numbers, location_value)
          path = path:sub(1, i - 1)

          if #location_numbers == 2 then
            -- There couldn't be more than 2 : separated number
            break
          end
        end
      end
    end
  end

  if #location_numbers == 2 then
    -- because of the reverse the line number will be second
    return path, location_numbers[2], location_numbers[1]
  end

  if #location_numbers == 1 then
    return path, location_numbers[1], 0
  end

  return path, nil, nil
end

local function add_offset(offset, obj)
  return { obj[1] + offset, obj[2] + offset }
end

utils.merge_styles = function(style1, style2, offset)
  for _, item in ipairs(style2) do
    item[1] = add_offset(offset, item[1])
    table.insert(style1, item)
  end

  return style1
end

-- IMPORTANT: This function should have been a local function as it's only used
-- in this file, but the code was already exported a long time ago. By making it
-- local we would potential break consumers of this method.
utils.reverse_table = function(input_table)
  local temp_table = {}
  for index = 0, #input_table do
    temp_table[#input_table - index] = input_table[index + 1] -- Reverses the order
  end
  return temp_table
end

utils.split_lines = (function()
  if utils.iswin then
    return function(s, opts)
      return vim.split(s, "\r?\n", opts)
    end
  else
    return function(s, opts)
      return vim.split(s, "\n", opts)
    end
  end
end)()

return utils
