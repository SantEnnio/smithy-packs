-- web_graph — Web import-relationship overlay for the graph-native "Attuale" map.
--
-- On `execute({scope="graph"})` this walks the project's source files and emits
-- real `imports` edges between them, normalized onto the `file:<path>` nodes the
-- app builds from project_tree. ONE script serves every web toolchain
-- (Next.js / Vite / plain JS/TS, and Laravel PHP) by simply processing whatever
-- files exist — it never branches on toolchain.
--
-- Output contract mirrors packs/rust/scripts/graph.lua's scope_graph:
--   { ok=true, payload={ scope="graph", nodes={}, edges={...} }, text="..." }
-- Edges:  { from="file:<p>", to="file:<p>", kind="imports", confidence=... }
-- where <p> is the root-relative, "/"-separated path EXACTLY as host.walk_dir
-- returns it, so the ids match the app's project_tree `file:<path>` nodes.
--
-- Two relationship families, no toolchain switch:
--   JS/TS (*.ts,*.tsx,*.js,*.jsx,*.mjs,*.cjs): `import .. from "X"`,
--     `import "X"`, `export .. from "X"`, `require("X")`, dynamic `import("X")`.
--     ONLY relative specifiers ("./", "../") are resolved (deterministic ->
--     confidence="static"); an optional tsconfig/jsconfig "@/*" alias is
--     resolved best-effort (config-dependent -> confidence="heuristic"). Bare
--     npm/URL/absolute specifiers are skipped.
--   PHP (Laravel): `use App\Http\Controllers\FooController;` resolved via PSR-4
--     (composer.json autoload, default App\ -> app/) to a *.php file; vendor
--     namespaces (Illuminate\, Symfony\, ...) never match a walked file and are
--     dropped. Deterministic -> confidence="static".
--
-- Accurate over ambitious: every edge endpoint MUST be a member of the walked
-- file set, so a wrong/dangling edge can never reach the merge in
-- src/graph/structureGraph.ts (which drops any edge whose `from`/`to` is not an
-- existing node). Self-edges and duplicates are dropped. An empty edge list is
-- acceptable. `nodes={}` is ALWAYS present so packs/mod.rs structure_graph()
-- keeps the payload (it requires `payload.nodes` to be Some).

local IGNORE = { "node_modules", ".git", "dist", ".chrome-tmp", "vendor", "build", ".next" }
local JS_EXTS = { "ts", "tsx", "js", "jsx", "mjs", "cjs" }
-- Extension probe order for a relative specifier without an explicit extension.
local JS_PROBE = {
  ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs",
  "/index.ts", "/index.tsx", "/index.js", "/index.jsx",
}

-- ---- small helpers -------------------------------------------------------

-- "a/b/c.ts" -> "a/b" ; "x.ts" -> "" (no directory component)
local function dir_of(path)
  return path:match("^(.*)/[^/]+$") or ""
end

local function ends_with(s, suffix)
  return s:sub(-#suffix) == suffix
end

-- True if `path` already carries one of the JS extensions we resolve to.
local function has_js_ext(path)
  for _, e in ipairs(JS_EXTS) do
    if ends_with(path, "." .. e) then return true end
  end
  return false
end

-- Blank the CONTENTS of every string literal on `line` whose text is NOT an
-- import specifier, so import-like text inside an unrelated string (e.g.
-- `const s = "import x from './dead'"`) or a template literal (e.g.
-- `` const t = `import x from './dead'` ``) can't be mistaken for a real import.
--
-- Three quote chars are scanned: `"`, `'`, and the JS template-literal backtick
-- `` ` ``. A `"`/`'` string is treated as a specifier (kept verbatim) ONLY when
-- the immediately-preceding token is `from` / `import` / `import (` /
-- `require (` (optional whitespace before the paren) — exactly the shapes
-- collect_js_specs matches. EVERY backtick span is blanked unconditionally:
-- import/require specifiers are ALWAYS plain `"`/`'` string literals, never
-- template literals, so a backtick can never carry a real specifier — blanking
-- it removes a whole false-positive class (codegen / SQL / HTML builders that
-- embed `import ... from "..."` text).
--
-- Returns `out, open_backtick` where `open_backtick` is true when a `` ` ``
-- was opened on this line but not closed (a multi-line template literal). The
-- caller (`strip_comments`) carries that state into the next line so a template
-- literal spanning lines is blanked end-to-end. When `open_backtick_in` is true
-- the line BEGINS inside a template literal: blank from column 1 up to the
-- closing backtick (or the whole line if none) before normal scanning resumes.
--
-- No escape handling is needed for `"`/`'`: import specifiers never contain an
-- escaped quote. For backticks we don't honor `\`` escapes either — treating an
-- escaped backtick as a closer can only END the blanked span EARLY, re-exposing
-- inert text to the import scanners; that text must then independently match a
-- real `from "..."`/`import "..."` shape to leak, which template-literal bodies
-- do not (they aren't preceded by the keyword tokens). Conservative either way.
local function blank_noimport_strings(line, open_backtick_in)
  local out = {}
  local i, n = 1, #line

  -- If we entered this line still inside a multi-line template literal, blank up
  -- to (and including) the closing backtick, or the whole line if it stays open.
  if open_backtick_in then
    local close = line:find("`", 1, true)
    if not close then
      return string.rep(" ", n), true
    end
    out[#out + 1] = string.rep(" ", close - 1) .. "`"
    i = close + 1
  end

  while i <= n do
    local c = line:sub(i, i)
    if c == "`" then
      -- Template literal: find its close on THIS line; blank the contents.
      local j = i + 1
      while j <= n and line:sub(j, j) ~= "`" do j = j + 1 end
      if j > n then
        -- Unterminated on this line -> blank to EOL, stay open for next line.
        out[#out + 1] = "`" .. string.rep(" ", n - i)
        return table.concat(out), true
      end
      local content_len = (j - 1) - (i + 1) + 1
      if content_len < 0 then content_len = 0 end
      out[#out + 1] = "`" .. string.rep(" ", content_len) .. "`"
      i = j + 1
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n and line:sub(j, j) ~= c do j = j + 1 end
      local before = line:sub(1, i - 1):gsub("%s+$", "")
      local is_import = before:match("from$")
        or before:match("import$")
        or before:match("import%s*%($")
        or before:match("require%s*%($")
      if is_import then
        out[#out + 1] = line:sub(i, (j <= n) and j or n) -- keep specifier verbatim
      else
        local content_len = (j - 1) - (i + 1) + 1
        if content_len < 0 then content_len = 0 end
        out[#out + 1] = c .. string.rep(" ", content_len) .. (j <= n and c or "")
      end
      i = j + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out), false
end

-- Strip line (`//`) and block (`/* */`) comments so a commented-out import or
-- `use` never makes an edge. Block comments are blanked first (`.-` is
-- non-greedy so each `/* */` is matched minimally), then everything from a `//`
-- (or, for PHP, a `#`) to end-of-line is dropped per line. For JS, each
-- surviving line also has its non-import string + template literals blanked
-- (above), so a specifier embedded in an unrelated string/backtick never makes
-- an edge; an `open_backtick` flag is carried ACROSS lines so a multi-line
-- template literal embedding `from "./x"` cannot leak. Conservative: when in
-- doubt this drops a real edge rather than emitting a wrong one. The newline
-- structure is preserved so a multi-line `import { ... } from "X"` still scans.
local function strip_comments(body, php)
  body = body:gsub("/%*.-%*/", " ")
  local lines = {}
  local open_backtick = false
  for line in (body .. "\n"):gmatch("(.-)\n") do
    if php then
      local sl = line:find("//", 1, true)
      if sl then line = line:sub(1, sl - 1) end
      local hh = line:find("#", 1, true)
      if hh then line = line:sub(1, hh - 1) end
      lines[#lines + 1] = line
    else
      -- For JS, neutralize strings/backticks FIRST (so a `//` that lives inside
      -- a string or template literal isn't mistaken for a comment, and so a
      -- `//`-bearing template-literal line is still blanked), then strip a
      -- trailing line comment from the neutralized text.
      local neutral, still_open = blank_noimport_strings(line, open_backtick)
      open_backtick = still_open
      local sl = neutral:find("//", 1, true)
      if sl then neutral = neutral:sub(1, sl - 1) end
      lines[#lines + 1] = neutral
    end
  end
  return table.concat(lines, "\n")
end

-- Join an importer directory with a relative specifier and fold "." / ".." path
-- segments. Returns the normalized "/"-path, or nil if a ".." escapes the root
-- (popping an empty stack) — in which case the specifier is dropped.
local function normalize_join(dir, spec)
  local joined = (dir == "" and spec) or (dir .. "/" .. spec)
  local stack = {}
  for seg in joined:gmatch("[^/]+") do
    if seg == "." then
      -- no-op
    elseif seg == ".." then
      if #stack == 0 then return nil end
      stack[#stack] = nil
    else
      stack[#stack + 1] = seg
    end
  end
  return table.concat(stack, "/")
end

-- Resolve a normalized candidate base `c` to a member of `file_set`. If `c`
-- already ends in a known JS extension it resolves directly (and only if it
-- exists). Otherwise probe base+ext then base/index+ext in JS_PROBE order;
-- first hit wins. Returns the resolved path or nil.
local function resolve_js_candidate(c, file_set)
  if not c then return nil end
  if has_js_ext(c) then
    if file_set[c] then return c end
    return nil
  end
  for _, suffix in ipairs(JS_PROBE) do
    local cand = c .. suffix
    if file_set[cand] then return cand end
  end
  return nil
end

-- ---- walk + config -------------------------------------------------------
--
-- ONE walk over all source exts; partition rows by ext; the existence set is
-- shared (cheap) but each language only ever resolves to its own kind of file.
local function build()
  local exts = {}
  for _, e in ipairs(JS_EXTS) do exts[#exts + 1] = e end
  exts[#exts + 1] = "php"

  local rows = host.walk_dir(".", { ignore = IGNORE, ext = exts })
  local file_set = {}
  local js_files = {}
  local php_files = {}
  local nfiles = 0
  for _, r in ipairs(rows) do
    if r.is_file then
      file_set[r.path] = true
      nfiles = nfiles + 1
      if r.ext == "php" then
        php_files[#php_files + 1] = r.path
      else
        js_files[#js_files + 1] = r.path
      end
    end
  end

  -- tsconfig / jsconfig "@/*" alias (best-effort, pcall-guarded). We model the
  -- single common case paths["@/*"] = ["<base>/*"] (Next convention "src/*", or
  -- "./*"); anything richer is left unmapped (skip, never guess wrong). A JSONC
  -- file (comments / trailing commas) makes the strict host.read_json fail; the
  -- pcall swallows it and the alias simply degrades to "off" (never wrong).
  local alias_base = nil -- e.g. "src" or "" (root); nil => no alias resolution
  do
    local cfg = nil
    for _, name in ipairs({ "tsconfig.json", "jsconfig.json" }) do
      if cfg == nil and host.path_exists(name) then
        local ok, parsed = pcall(host.read_json, name)
        if ok and type(parsed) == "table" then cfg = parsed end
      end
    end
    if cfg and type(cfg.compilerOptions) == "table" then
      local co = cfg.compilerOptions
      local base_url = (type(co.baseUrl) == "string" and co.baseUrl) or "."
      base_url = base_url:gsub("^%./", ""):gsub("/$", "")
      if type(co.paths) == "table" then
        local star = co.paths["@/*"]
        local target = nil
        if type(star) == "table" then
          target = star[1]
        elseif type(star) == "string" then
          target = star
        end
        if type(target) == "string" then
          -- "src/*" -> "src" ; "./*" -> "" ; "*" -> "".
          local prefix = target:gsub("%*$", ""):gsub("/$", ""):gsub("^%./", "")
          if base_url ~= "" and prefix ~= "" then
            alias_base = base_url .. "/" .. prefix
          elseif base_url ~= "" then
            alias_base = base_url
          else
            alias_base = prefix
          end
        end
      end
    end
  end

  -- PSR-4 map for PHP: composer.json autoload + autoload-dev "psr-4". Each entry
  -- maps a namespace prefix ("App\\") to a dir ("app/"); the value may be a
  -- string or an array of dirs. Default to {App\ -> app} when absent/unreadable.
  local psr4 = {} -- { {prefix="App\\", dir="app"}, ... }, longest prefix wins
  do
    local added = false
    if host.path_exists("composer.json") then
      local ok, parsed = pcall(host.read_json, "composer.json")
      if ok and type(parsed) == "table" then
        for _, key in ipairs({ "autoload", "autoload-dev" }) do
          local sect = parsed[key]
          if type(sect) == "table" and type(sect["psr-4"]) == "table" then
            for prefix, dir in pairs(sect["psr-4"]) do
              local d = nil
              if type(dir) == "string" then
                d = dir
              elseif type(dir) == "table" and type(dir[1]) == "string" then
                d = dir[1]
              end
              if type(prefix) == "string" and d then
                psr4[#psr4 + 1] = { prefix = prefix, dir = (d:gsub("/$", "")) }
                added = true
              end
            end
          end
        end
      end
    end
    if not added then
      psr4[#psr4 + 1] = { prefix = "App\\", dir = "app" }
    end
    -- Longest prefix first => deterministic longest-match resolution.
    table.sort(psr4, function(a, b) return #a.prefix > #b.prefix end)
  end

  return {
    file_set = file_set,
    js_files = js_files,
    php_files = php_files,
    nfiles = nfiles,
    alias_base = alias_base,
    psr4 = psr4,
  }
end

-- ---- JS/TS specifier capture --------------------------------------------
--
-- Collect every import specifier in `body` (already comment-stripped, sentinel
-- "\n" prepended by the caller). A leading boundary class [^%w_] keeps an
-- identifier ending in `from`/`import`/`require` (e.g. `platformRequire`) from
-- masquerading as the keyword while still matching at line/expression starts.
-- Both quote styles are accepted; the capture forbids quote+newline so a
-- multi-line `import {\n a\n} from "X"` resolves via its `from` clause.
local function collect_js_specs(scanbody)
  local specs = {}
  local function add(q) specs[#specs + 1] = q end
  -- `import ... from "X"`, `export ... from "X"`, `export * from "X"`.
  for q in scanbody:gmatch("[^%w_]from%s*['\"]([^'\"\n]+)['\"]") do add(q) end
  -- bare side-effect `import "X"` (no `from`); the `import(...)` dynamic form is
  -- captured separately below and won't match this (a `(` follows, not a quote).
  for q in scanbody:gmatch("[^%w_]import%s*['\"]([^'\"\n]+)['\"]") do add(q) end
  -- dynamic `import("X")` / `import ("X")` (optional whitespace before paren).
  for q in scanbody:gmatch("[^%w_]import%s*%(%s*['\"]([^'\"\n]+)['\"]") do add(q) end
  -- CJS `require("X")` / `require ("X")`.
  for q in scanbody:gmatch("[^%w_]require%s*%(%s*['\"]([^'\"\n]+)['\"]") do add(q) end
  return specs
end

-- Classify + resolve one JS specifier from file `file`. Returns target,confidence
-- (target nil => skip). Only relative and configured-alias specifiers resolve;
-- bare pkgs / URLs / project-absolute paths are skipped.
local function resolve_js_spec(spec, file, g)
  if spec:sub(1, 2) == "./" or spec:sub(1, 3) == "../" then
    local c = normalize_join(dir_of(file), spec)
    local t = resolve_js_candidate(c, g.file_set)
    if t then return t, "static" end
    return nil
  end
  if g.alias_base ~= nil and spec:sub(1, 2) == "@/" then
    local rest = spec:sub(3)
    local base = (g.alias_base == "" and rest) or (g.alias_base .. "/" .. rest)
    local c = normalize_join("", base)
    local t = resolve_js_candidate(c, g.file_set)
    if t then return t, "heuristic" end
    return nil
  end
  return nil
end

-- ---- PHP `use` resolution -----------------------------------------------
--
-- Expand a single `use` statement body (between `use ` and `;`) into one or more
-- fully-qualified class names. Handles a leading `function `/`const ` keyword, a
-- leading backslash, an ` as Alias` rename, and a grouped `Prefix\{A, B}` list.
local function expand_php_use(stmt)
  local out = {}
  stmt = stmt:gsub("^%s*function%s+", ""):gsub("^%s*const%s+", "")
  local brace = stmt:find("{", 1, true)
  if not brace then
    local p = stmt:gsub("%s+as%s+[%a_][%w_]*%s*$", "")
    p = p:gsub("%s", ""):gsub("^\\", "")
    if p ~= "" then out[#out + 1] = p end
    return out
  end
  local prefix = stmt:sub(1, brace - 1):gsub("%s", ""):gsub("^\\", ""):gsub("\\+$", "")
  local close = stmt:match("^.*()}")
  local inner = stmt:sub(brace + 1, (close and close - 1) or #stmt)
  for item in inner:gmatch("[^,]+") do
    local it = item:gsub("%s+as%s+[%a_][%w_]*%s*$", ""):gsub("%s", "")
    if it ~= "" and not it:find("{", 1, true) and not it:find("}", 1, true) and prefix ~= "" then
      out[#out + 1] = prefix .. "\\" .. it
    end
  end
  return out
end

-- Map a fully-qualified class name to a "/"-path via the PSR-4 map; longest
-- matching prefix wins. Returns the path (e.g. "app/Http/.../Foo.php") or nil.
local function php_fqn_to_path(fqn, psr4)
  for _, m in ipairs(psr4) do
    if fqn:sub(1, #m.prefix) == m.prefix then
      local rest = fqn:sub(#m.prefix + 1)
      return m.dir .. "/" .. rest:gsub("\\", "/") .. ".php"
    end
  end
  return nil
end

-- ---- scopes --------------------------------------------------------------

local function scope_graph(g)
  local edges = {}
  local emitted = {}

  local function emit(from, to, confidence)
    if not to or to == from then return end
    local k = from .. "->" .. to
    if emitted[k] then return end
    emitted[k] = true
    edges[#edges + 1] = {
      from = "file:" .. from,
      to = "file:" .. to,
      kind = "imports",
      confidence = confidence,
    }
  end

  -- JS/TS files.
  for _, file in ipairs(g.js_files) do
    local ok, body = pcall(host.read_file, file)
    if ok and body then
      local scanbody = "\n" .. strip_comments(body, false)
      for _, spec in ipairs(collect_js_specs(scanbody)) do
        local target, confidence = resolve_js_spec(spec, file, g)
        emit(file, target, confidence)
      end
    end
  end

  -- PHP files.
  for _, file in ipairs(g.php_files) do
    local ok, body = pcall(host.read_file, file)
    if ok and body then
      local scanbody = "\n" .. strip_comments(body, true)
      -- A boundary before `use` (so `$x->useFoo()` / `useState` don't match);
      -- non-greedy `.-` stops at the terminating `;`.
      for stmt in scanbody:gmatch("[^%w_]use%s+(.-);") do
        for _, fqn in ipairs(expand_php_use(stmt)) do
          local target = php_fqn_to_path(fqn, g.psr4)
          if target and g.file_set[target] then
            emit(file, target, "static")
          end
        end
      end
    end
  end

  return {
    ok = true,
    payload = { scope = "graph", nodes = {}, edges = edges },
    text = string.format("Web graph: %d imports-edge(s)", #edges),
  }
end

local function scope_summary(g)
  return {
    ok = true,
    payload = {
      scope = "summary",
      files = g.nfiles,
      js_files = #g.js_files,
      php_files = #g.php_files,
    },
    text = string.format(
      "Web graph — files: %d (js: %d, php: %d)",
      g.nfiles, #g.js_files, #g.php_files
    ),
  }
end

-- ---- functional lens ----------------------------------------------------
--
-- The graph-native FUNCTIONAL map for the web: rooted at the ENTRY POINTS (the
-- pages/routes), flowing outward to what they compose. Entry = the home page
-- (App Router `app/page.*` or Pages Router `pages/index.*`); composition = the
-- resolved import graph re-cast as `has-component` edges (page → component →
-- …), so it reads "the home page is made of these". Node kinds classify each
-- file by web convention (route / component / hook / module). Emits its OWN
-- normalized graph (the backend returns it as-is, the frontend `normalize()`s it).

local function leaf(p) return (p:match("([^/]+)$")) or p end

-- Classify a source path by web convention → (kind, is_home).
local function classify(path)
  local base = leaf(path)
  -- Home entry: App Router app/page.* or Pages Router pages/index.* (also src/).
  if path:match("^app/page%.[jt]sx?$") or path:match("^src/app/page%.[jt]sx?$")
    or path:match("^pages/index%.[jt]sx?$") or path:match("^src/pages/index%.[jt]sx?$") then
    return "route", true
  end
  -- Other routes/pages/layouts/api endpoints.
  if path:match("/page%.[jt]sx?$") or path:match("/layout%.[jt]sx?$")
    or path:match("^app/layout%.[jt]sx?$") or path:match("/route%.[jt]s$")
    or ((path:match("^pages/") or path:match("^src/pages/")) and not base:match("^_")) then
    return "route", false
  end
  -- Hooks (use*, or in a hooks/ dir).
  if base:match("^use%u") or path:match("/hooks?/") then return "hook", false end
  -- Components (PascalCase .tsx/.jsx, or in a components/ dir).
  if path:match("/components?/") or base:match("^%u[%w_]*%.[jt]sx$") then
    return "component", false
  end
  return "module", false -- lib / utils / services / plain modules
end

local function scope_functional(g)
  local nodes, edges = {}, {}
  local function fid(p) return "file:" .. p end
  local function add_node(id, path, kind, opts)
    if nodes[id] then return end
    local n = { id = id, kind = kind, label = leaf(path), path = path, confidence = "static" }
    if opts then for k, v in pairs(opts) do n[k] = v end end
    nodes[id] = n
  end
  local function add_edge(from, to, kind)
    if from == to then return end
    local eid = kind .. ":" .. from .. "->" .. to
    if not edges[eid] then
      edges[eid] = { id = eid, from = from, to = to, kind = kind, confidence = "static" }
    end
  end

  -- Composition = resolved imports, as `has-component` edges (page composes
  -- component composes …) — both hierarchy (LOD nesting) and a drawn connector.
  for _, file in ipairs(g.js_files) do
    local ok, body = pcall(host.read_file, file)
    if ok and body then
      local scanbody = "\n" .. strip_comments(body, false)
      for _, spec in ipairs(collect_js_specs(scanbody)) do
        local target = resolve_js_spec(spec, file, g)
        if target then add_edge(fid(file), fid(target), "has-component") end
      end
    end
  end
  for _, file in ipairs(g.php_files) do
    local ok, body = pcall(host.read_file, file)
    if ok and body then
      local scanbody = "\n" .. strip_comments(body, true)
      for stmt in scanbody:gmatch("[^%w_]use%s+(.-);") do
        for _, fqn in ipairs(expand_php_use(stmt)) do
          local target = php_fqn_to_path(fqn, g.psr4)
          if target and g.file_set[target] then add_edge(fid(file), fid(target), "has-component") end
        end
      end
    end
  end

  -- Nodes worth showing: every composition endpoint + every page/route (entries,
  -- which may have no imports of their own but must still anchor the map).
  local touched = {}
  for _, e in pairs(edges) do touched[e.from] = true; touched[e.to] = true end
  local home_id
  for _, file in ipairs(g.js_files) do
    local kind, is_home = classify(file)
    if kind == "route" then
      touched[fid(file)] = true
      if is_home and not home_id then home_id = fid(file) end
    end
  end
  for id in pairs(touched) do
    local path = id:gsub("^file:", "")
    add_node(id, path, (classify(path)))
  end
  if home_id and nodes[home_id] then
    nodes[home_id].entry = true
    nodes[home_id].entryStart = true
  end

  local node_list, edge_list = {}, {}
  for _, n in pairs(nodes) do node_list[#node_list + 1] = n end
  for _, e in pairs(edges) do edge_list[#edge_list + 1] = e end
  table.sort(node_list, function(a, b) return a.id < b.id end)
  table.sort(edge_list, function(a, b) return a.id < b.id end)
  return {
    ok = true,
    payload = {
      scope = "functional",
      nodes = node_list,
      edges = edge_list,
      meta = { pack = "web", truncated = false, generatedAt = 0 },
    },
    text = string.format("Web functional: %d nodi, %d archi", #node_list, #edge_list),
  }
end

function execute(args)
  args = args or {}
  local scope = args.scope or "graph"
  local g = build()
  if scope == "graph" then return scope_graph(g) end
  if scope == "functional" then return scope_functional(g) end
  if scope == "summary" then return scope_summary(g) end
  return { ok = false, text = "unknown scope `" .. tostring(scope) ..
    "` — expected: graph, functional, summary" }
end
