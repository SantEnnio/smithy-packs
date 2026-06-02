-- unity_compile — Unity batch-mode compile + Roslyn diagnostics.
--
-- Ported from the former native `smithy-unity` crate. All side effects go
-- through the sandboxed `host` table; nothing here is special-cased in the
-- Rust core. The returned `payload.diagnostics` is what the agent loop reads
-- to drive correction retrieval and the verify-passed completion check, so
-- its shape must match the core `Diagnostic` type exactly:
--   { path, line, column, severity ("error"|"warning"|"info"), code, message }

-- Roslyn diagnostic line: <path>(<line>,<col>): <severity> <code>: <message>
-- Long-bracket string so Lua doesn't choke on the regex backslashes.
local DIAG = [[(?m)^\s*(?P<path>[A-Za-z]?:?[^\s(]+?)\((?P<line>\d+),(?P<col>\d+)\):\s*(?P<sev>error|warning|info|Error|Warning|Info)\s+(?P<code>[A-Z]+[0-9]+):\s*(?P<msg>.+?)\s*$]]

local SUCCESS_SENTINELS = {
  "CompilationFinished",
  "Compilation succeeded",
  "Exiting batchmode successfully",
}
local FATAL_SENTINELS = {
  "Aborting batchmode",
  "Editor.log:",
  "Failure: ",
  "Internal compiler error",
  "Unhandled Exception",
}

local function contains_any(haystack, needles)
  for _, n in ipairs(needles) do
    if haystack:find(n, 1, true) then return true end
  end
  return false
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Candidate Unity binaries, best first: env override → Hub (by editor
-- version) → PATH. We don't stat absolute paths (the sandbox scopes paths
-- to the project root); instead we try to spawn each — a missing path
-- fails immediately with ENOENT, so the first that launches is the editor.
local function candidates()
  local list = {}
  local env = host.env("SMITHY_UNITY_PATH")
  if env and #env > 0 then list[#list + 1] = env end

  local ver = nil
  local pv = "ProjectSettings/ProjectVersion.txt"
  if host.path_exists(pv) then
    local ok, txt = pcall(host.read_file, pv)
    if ok and txt then ver = txt:match("m_EditorVersion:%s*([%w%.]+)") end
  end
  if ver then
    list[#list + 1] = "/Applications/Unity/Hub/Editor/" .. ver .. "/Unity.app/Contents/MacOS/Unity"
    local home = host.env("HOME")
    if home then list[#list + 1] = home .. "/Unity/Hub/Editor/" .. ver .. "/Editor/Unity" end
    list[#list + 1] = "C:\\Program Files\\Unity\\Hub\\Editor\\" .. ver .. "\\Editor\\Unity.exe"
  end

  for _, dir in ipairs(host.path_env()) do
    list[#list + 1] = dir .. "/Unity"
    list[#list + 1] = dir .. "/Unity.exe"
  end
  return list
end

local function run_unity(args, timeout)
  for _, bin in ipairs(candidates()) do
    local ok, res = pcall(host.spawn, bin, args, { timeout = timeout })
    if ok and res then return res, bin end
  end
  return nil, nil
end

local function parse_diagnostics(log)
  local out, seen = {}, {}
  for _, m in ipairs(host.regex(DIAG, log)) do
    local sev = (m.sev or "error"):lower()
    if sev == "hidden" then sev = "info" end
    local d = {
      path = m.path,
      line = tonumber(m.line) or 0,
      column = tonumber(m.col) or 0,
      severity = sev,
      code = m.code,
      message = trim(m.msg or ""),
    }
    local key = d.path .. ":" .. d.line .. ":" .. d.column .. ":" .. d.code .. ":" .. d.message
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = d
    end
  end
  return out
end

local function last_lines(s, n)
  local lines = {}
  for line in (s .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
  local start = math.max(1, #lines - n + 1)
  local tail = {}
  for i = start, #lines do tail[#tail + 1] = lines[i] end
  return table.concat(tail, "\n")
end

function execute(args)
  args = args or {}
  local timeout = args.timeout_seconds or 180

  local res, bin = run_unity(
    { "-batchmode", "-quit", "-nographics", "-projectPath", host.root(), "-logFile", "-" },
    timeout
  )
  if not res then
    return {
      ok = false,
      payload = { verdict = "degraded", diagnostics = {} },
      text = "Could not locate the Unity editor binary. Set SMITHY_UNITY_PATH or install via Unity Hub.",
    }
  end

  local combined = res.stdout
  if res.stderr and #res.stderr > 0 then
    combined = combined .. "\n--- stderr ---\n" .. res.stderr
  end

  local diagnostics = parse_diagnostics(combined)
  local has_errors = false
  for _, d in ipairs(diagnostics) do
    if d.severity == "error" then has_errors = true break end
  end

  local mentions_success = contains_any(combined, SUCCESS_SENTINELS)
  local mentions_fatal = contains_any(combined, FATAL_SENTINELS)
  local exit_code = res.exit or -1

  local verdict
  if has_errors then
    verdict = "fail"
  elseif exit_code == 0 and (mentions_success or not mentions_fatal) then
    verdict = "pass"
  elseif mentions_fatal and #diagnostics == 0 then
    verdict = "degraded"
  elseif exit_code ~= 0 then
    verdict = "degraded"
  else
    verdict = "pass"
  end

  -- Text optimised for small models: first error first, then a next-step
  -- hint, then the full list.
  local text = ""
  for _, d in ipairs(diagnostics) do
    if d.severity == "error" then
      text = text .. string.format(
        "FIRST ERROR: %s %s at %s:%d:%d\n  message: %s\n  next step: read_file `%s` near line %d\n\n",
        d.code, d.severity, d.path, d.line, d.column, d.message, d.path, d.line)
      break
    end
  end
  text = text .. string.format("Unity compile %s (exit=%d, %d diagnostic(s) total).\n",
    verdict:upper(), exit_code, #diagnostics)
  for _, d in ipairs(diagnostics) do
    text = text .. string.format("  %s(%d,%d): %s %s: %s\n",
      d.path, d.line, d.column, d.severity, d.code, d.message)
  end

  local raw_window = nil
  if verdict == "degraded" then
    raw_window = last_lines(combined, 40)
    text = text .. "\n--- raw log window ---\n" .. raw_window
  end

  return {
    ok = verdict == "pass",
    payload = {
      verdict = verdict,
      exit_code = exit_code,
      diagnostics = diagnostics,
      raw_window = raw_window,
    },
    text = text,
  }
end
