-- match(python.*)

-- buildcache Lua wrapper for the Firefox WebIDL binding code generation step.
-- Caches the output of: python3 -m mozbuild.action.webidl
--
-- The action generates C++ binding files from .webidl sources. It produces
-- thousands of output files from hundreds of input files, making it a good
-- candidate for caching across clean builds or branch switches.

-- luacheck: globals require_std ARGS

require_std("io")
require_std("os")
require_std("string")
require_std("table")
require_std("bcache")

local _cwd = nil
local _file_lists = nil

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*all")
  f:close()
  return content
end

local function read_json(path)
  local content = read_file(path)
  if not content then return nil end
  return bcache.parse_json(content)
end

local function get_cwd()
  if not _cwd then
    local result = bcache.run({"/bin/pwd"})
    _cwd = result.std_out:gsub("%s+$", "")
  end
  return _cwd
end

local function get_file_lists()
  if not _file_lists then
    _file_lists = read_json("file-lists.json")
    if not _file_lists then
      error("Cannot read file-lists.json")
    end
  end
  return _file_lists
end

local function get_srcdir()
  return ARGS[#ARGS]
end

-------------------------------------------------------------------------------
-- Wrapper interface implementation.
-------------------------------------------------------------------------------

function can_handle_command()
  for i = 2, #ARGS do
    if ARGS[i] == "mozbuild.action.webidl" then
      return true
    end
  end
  return false
end

function get_capabilities()
  return {"direct_mode"}
end

function get_program_id()
  local result = bcache.run({ARGS[1], "--version"})
  if result.return_code ~= 0 then
    error("Unable to get Python version information")
  end
  return ARGS[1] .. ":" .. result.std_out .. result.std_err
end

function get_relevant_arguments()
  return {"mozbuild.action.webidl"}
end

function get_input_files()
  local file_lists = get_file_lists()
  local files = {}

  for _, path in ipairs(file_lists.webidls or {}) do
    table.insert(files, path)
  end

  local cwd = get_cwd()
  table.insert(files, cwd .. "/file-lists.json")

  -- Python codegen dependencies: reuse the previous run's global_depends
  -- when available, otherwise discover .py files from the source tree.
  local codegen = read_json("codegen.json")
  if codegen and codegen.global_depends then
    for path, _ in pairs(codegen.global_depends) do
      table.insert(files, path)
    end
  else
    local srcdir = get_srcdir()
    local result = bcache.run({"find", srcdir, "-name", "*.py", "-type", "f"})
    if result.return_code == 0 then
      for path in result.std_out:gmatch("[^\n]+") do
        table.insert(files, path)
      end
    end
    table.insert(files, srcdir .. "/Bindings.conf")
  end

  return files
end

function get_build_files()
  local file_lists = get_file_lists()
  local cwd = get_cwd()
  local topobjdir = cwd:match("^(.*)/dom/bindings$")
  local exported_header_dir = topobjdir .. "/dist/include/mozilla/dom"
  local codegen_dir = cwd

  local exported_stems = {}
  for _, stem in ipairs(file_lists.exported_stems or {}) do
    exported_stems[stem] = true
  end

  local event_stems = {}
  for _, stem in ipairs(file_lists.generated_events_stems or {}) do
    event_stems[stem] = true
  end

  local files = {}
  local n = 0

  local function add(path)
    n = n + 1
    files["output_" .. n] = path
  end

  -- Global declare files (exported headers).
  for _, name in ipairs({"BindingNames.h", "GeneratedAtomList.h",
      "GeneratedEventList.h", "PrototypeList.h", "RegisterBindings.h",
      "RegisterWorkerBindings.h", "RegisterWorkerDebuggerBindings.h",
      "RegisterWorkletBindings.h", "UnionTypes.h", "WebIDLPrefs.h",
      "WebIDLSerializable.h"}) do
    add(exported_header_dir .. "/" .. name)
  end

  -- Global define files (codegen dir).
  for _, name in ipairs({"BindingNames.cpp", "RegisterBindings.cpp",
      "RegisterWorkerBindings.cpp", "RegisterWorkerDebuggerBindings.cpp",
      "RegisterWorkletBindings.cpp", "UnionTypes.cpp", "PrototypeList.cpp",
      "WebIDLPrefs.cpp", "WebIDLSerializable.cpp"}) do
    add(codegen_dir .. "/" .. name)
  end

  -- Per-webidl binding outputs.
  for _, webidl_path in ipairs(file_lists.webidls or {}) do
    local basename = webidl_path:match("([^/]+)$")
    local stem = basename:match("^(.+)%.webidl$")
    if stem then
      local binding_stem = stem .. "Binding"
      local header_dir = exported_stems[stem] and exported_header_dir or codegen_dir
      add(header_dir .. "/" .. binding_stem .. ".h")
      add(codegen_dir .. "/" .. binding_stem .. ".cpp")
      add(header_dir .. "/" .. binding_stem .. "Fwd.h")
      if event_stems[stem] then
        add(header_dir .. "/" .. stem .. ".h")
        add(codegen_dir .. "/" .. stem .. ".cpp")
      end
    end
  end

  -- Example interface files.
  for _, iface in ipairs(file_lists.example_interfaces or {}) do
    add(codegen_dir .. "/" .. iface .. "-example.h")
    add(codegen_dir .. "/" .. iface .. "-example.cpp")
  end

  -- Codegen state files needed for subsequent incremental builds.
  add(codegen_dir .. "/codegen.json")
  add(codegen_dir .. "/codegen.pp")

  return files
end

function preprocess_source()
  -- Fallback when direct mode misses. Return a fingerprint that uniquely
  -- identifies the set of inputs so the preprocessor-mode cache key is
  -- correct. We build a string from each file's path and size, then let
  -- buildcache hash the result. This is lightweight; actual content
  -- hashing is handled by direct mode.
  local files = get_input_files()
  table.sort(files)

  local parts = {}
  for _, path in ipairs(files) do
    local info = bcache.get_file_info(path)
    if info then
      table.insert(parts, path .. ":" .. tostring(info.size))
    else
      table.insert(parts, path .. ":missing")
    end
  end
  return table.concat(parts, "\n")
end
