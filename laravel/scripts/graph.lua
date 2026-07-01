-- laravel_graph — Laravel STRUCTURE overlay for the graph-native "Attuale" map.
--
-- Laravel's structure is convention-based and invisible to a plain `use` scan,
-- so this models the real relationships:
--   routes/*.php  --routes_to-->  app/Http/Controllers/*.php   (FooController::class
--                                  or 'App\Http\Controllers\Foo@m')
--   controllers   --uses-------->  app/Models/*.php (and any `use`d app class)
--   any php       --references-->  resources/views/<a/b>.blade.php   (view('a.b'))
--   blade         --references-->  blade   (@extends/@include('layouts.app'))
--
-- Output mirrors packs/web/scripts/graph.lua: edges are `file:<path>`→`file:<path>`
-- onto the project_tree nodes (graph scope), or a self-contained normalized graph
-- (functional scope). Accurate over ambitious: every endpoint MUST be a walked
-- file, so a dangling/wrong edge is dropped by structureGraph.ts before render.

local IGNORE = {
  "vendor", "node_modules", ".git", "storage", "bootstrap/cache",
  "public", ".phpunit.cache", "dist", "build",
}

-- ---- helpers (shared shape with packs/web/scripts/graph.lua) --------------

local function ends_with(s, suffix)
  return s:sub(-#suffix) == suffix
end

local function leaf(p) return (p:match("([^/]+)$")) or p end

local function is_blade(path) return ends_with(path, ".blade.php") end

-- Strip `/* */`, `//` and `#` comments so a commented-out `use`/route/view never
-- makes an edge. (Blade `{{-- --}}` comments are left as-is; they don't contain
-- the bare `@extends('x')`/`view('x')` token shapes we match below in a way that
-- survives — and being conservative here only drops edges, never invents them.)
local function strip_php_comments(body)
  body = body:gsub("/%*.-%*/", " ")
  local lines = {}
  for line in (body .. "\n"):gmatch("(.-)\n") do
    local sl = line:find("//", 1, true)
    if sl then line = line:sub(1, sl - 1) end
    local hh = line:find("#", 1, true)
    if hh then line = line:sub(1, hh - 1) end
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n")
end

-- Expand one `use` body (between `use ` and `;`) to fully-qualified class names:
-- handles `function `/`const `, a leading `\`, ` as Alias`, and `Prefix\{A, B}`.
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

-- Map a fully-qualified class name to a "/"-path via the PSR-4 map (longest
-- prefix wins). Returns the path (e.g. "app/Http/Controllers/Foo.php") or nil.
local function php_fqn_to_path(fqn, psr4)
  for _, m in ipairs(psr4) do
    if fqn:sub(1, #m.prefix) == m.prefix then
      local rest = fqn:sub(#m.prefix + 1)
      return m.dir .. "/" .. rest:gsub("\\", "/") .. ".php"
    end
  end
  return nil
end

-- A dotted (or slashed) Laravel view name -> "resources/views/<a/b>.blade.php".
-- "users.index" -> "resources/views/users/index.blade.php". Namespaced views
-- ("package::view") are skipped (vendor-owned, never a walked file).
local function view_name_to_path(name)
  if name:find("::", 1, true) then return nil end
  local p = name:gsub("%.", "/")
  return "resources/views/" .. p .. ".blade.php"
end

-- ---- walk + config -------------------------------------------------------

local function build()
  local rows = host.walk_dir(".", { ignore = IGNORE, ext = { "php" } })
  local file_set, php_files = {}, {}
  local routes, controllers, blades = {}, {}, {}
  local nfiles = 0
  for _, r in ipairs(rows) do
    if r.is_file then
      file_set[r.path] = true
      php_files[#php_files + 1] = r.path
      nfiles = nfiles + 1
      if r.path:match("^routes/.+%.php$") then
        routes[#routes + 1] = r.path
      elseif r.path:match("^app/Http/Controllers/.+%.php$") then
        controllers[#controllers + 1] = r.path
      end
      if is_blade(r.path) then blades[#blades + 1] = r.path end
    end
  end

  -- PSR-4 map from composer.json (autoload + autoload-dev); default App\ -> app.
  local psr4 = {}
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
              if type(dir) == "string" then d = dir
              elseif type(dir) == "table" and type(dir[1]) == "string" then d = dir[1] end
              if type(prefix) == "string" and d then
                psr4[#psr4 + 1] = { prefix = prefix, dir = (d:gsub("/$", "")) }
                added = true
              end
            end
          end
        end
      end
    end
    if not added then psr4[#psr4 + 1] = { prefix = "App\\", dir = "app" } end
    table.sort(psr4, function(a, b) return #a.prefix > #b.prefix end)
  end

  return {
    file_set = file_set, php_files = php_files, routes = routes,
    controllers = controllers, blades = blades, nfiles = nfiles, psr4 = psr4,
  }
end

-- Short-class-name -> FQN map from a file's `use` statements (last segment).
local function use_short_map(scanbody)
  local map = {}
  for stmt in scanbody:gmatch("[^%w_]use%s+(.-);") do
    for _, fqn in ipairs(expand_php_use(stmt)) do
      map[leaf(fqn:gsub("\\", "/"))] = fqn
    end
  end
  return map
end

-- Controllers a route file references: `Foo::class` resolved via the file's
-- `use` map (else assumed App\Http\Controllers\Foo), and string controllers
-- 'App\Http\Controllers\Foo@method'. Returns a list of {path, confidence}.
local function route_targets(scanbody, g)
  local seen, out = {}, {}
  local short = use_short_map(scanbody)
  local function push(path, conf)
    if path and g.file_set[path] and path:match("^app/Http/Controllers/")
      and not seen[path] then
      seen[path] = true
      out[#out + 1] = { path = path, confidence = conf }
    end
  end
  -- Foo::class  (only *Controller names, to avoid model/::class noise)
  for name in scanbody:gmatch("([%a_][%w_]*)::class") do
    if name:match("Controller$") then
      local fqn = short[name] or ("App\\Http\\Controllers\\" .. name)
      push(php_fqn_to_path(fqn, g.psr4), short[name] and "static" or "heuristic")
    end
  end
  -- 'App\Http\Controllers\Foo@method' or "App\\..\\Foo" (double-backslashed)
  for q in scanbody:gmatch("['\"](App\\[%w@\\]*)['\"]") do
    if q:find("Controller", 1, true) then
      local fqn = q:gsub("@.*$", ""):gsub("\\\\", "\\")
      push(php_fqn_to_path(fqn, g.psr4), "static")
    end
  end
  return out
end

-- Views referenced by `view('a.b')` / `view("a.b")` in a php body. The boundary
-- before `view` stops `preview(`/`overview(` from matching.
local function view_targets(scanbody, g)
  local seen, out = {}, {}
  for name in scanbody:gmatch("[^%w_]view%s*%(%s*['\"]([%w_%.%-/]+)['\"]") do
    local p = view_name_to_path(name)
    if p and g.file_set[p] and not seen[p] then seen[p] = true; out[#out + 1] = p end
  end
  return out
end

-- Blade includes/extends in a blade body -> resolved .blade.php paths.
local function blade_targets(scanbody, g)
  local seen, out = {}, {}
  for name in scanbody:gmatch("@[%a]+%s*%(%s*['\"]([%w_%.%-/]+)['\"]") do
    local p = view_name_to_path(name)
    if p and g.file_set[p] and not seen[p] then seen[p] = true; out[#out + 1] = p end
  end
  return out
end

local function read_scan(file)
  local ok, body = pcall(host.read_file, file)
  if not ok or not body then return nil end
  return "\n" .. strip_php_comments(body)
end

-- ---- scopes --------------------------------------------------------------

local function scope_graph(g)
  local edges, emitted = {}, {}
  local function emit(from, to, kind, conf)
    if not to or to == from then return end
    local k = kind .. ":" .. from .. "->" .. to
    if emitted[k] then return end
    emitted[k] = true
    edges[#edges + 1] = {
      from = "file:" .. from, to = "file:" .. to, kind = kind, confidence = conf,
    }
  end
  local route_set = {}
  for _, r in ipairs(g.routes) do route_set[r] = true end

  for _, file in ipairs(g.php_files) do
    local scan = read_scan(file)
    if scan then
      if route_set[file] then
        for _, t in ipairs(route_targets(scan, g)) do
          emit(file, t.path, "routes_to", t.confidence)
        end
      else
        -- controller/model deps via `use App\...`
        for stmt in scan:gmatch("[^%w_]use%s+(.-);") do
          for _, fqn in ipairs(expand_php_use(stmt)) do
            local target = php_fqn_to_path(fqn, g.psr4)
            if target and g.file_set[target] then emit(file, target, "uses", "static") end
          end
        end
      end
      -- view('a.b') from anywhere (controllers, view composers, …)
      for _, v in ipairs(view_targets(scan, g)) do emit(file, v, "references", "heuristic") end
    end
  end
  -- blade @extends/@include
  for _, file in ipairs(g.blades) do
    local scan = read_scan(file)
    if scan then
      for _, t in ipairs(blade_targets(scan, g)) do emit(file, t, "references", "heuristic") end
    end
  end

  return {
    ok = true,
    payload = { scope = "graph", nodes = {}, edges = edges },
    text = string.format("Laravel graph: %d edge(s)", #edges),
  }
end

local function scope_summary(g)
  return {
    ok = true,
    payload = {
      scope = "summary", files = g.nfiles,
      routes = #g.routes, controllers = #g.controllers, blades = #g.blades,
    },
    text = string.format(
      "Laravel — php: %d (routes: %d, controllers: %d, blade: %d)",
      g.nfiles, #g.routes, #g.controllers, #g.blades
    ),
  }
end

-- Functional lens: ENTRY = the route files, flowing route → controller → view
-- (has-component spine) and controller → model (uses). The renderer roots the
-- entries; `routes/web.php` is the start.
local function scope_functional(g)
  local nodes, edges = {}, {}
  local function fid(p) return "file:" .. p end
  local function kind_of(path)
    if path:match("^routes/.+%.php$") then return "route" end
    if path:match("^app/Http/Controllers/") then return "component" end
    if path:match("^app/Models/") then return "entity" end
    if is_blade(path) then return "module" end
    return "module"
  end
  local function add_node(path, opts)
    local id = fid(path)
    if nodes[id] then
      if opts then for k, v in pairs(opts) do nodes[id][k] = v end end
      return
    end
    local n = { id = id, kind = kind_of(path), label = leaf(path), path = path, confidence = "static" }
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

  local route_set = {}
  for _, r in ipairs(g.routes) do route_set[r] = true end

  for _, file in ipairs(g.php_files) do
    local scan = read_scan(file)
    if scan then
      if route_set[file] then
        add_node(file, { entry = true })
        for _, t in ipairs(route_targets(scan, g)) do
          add_node(t.path); add_edge(fid(file), fid(t.path), "routes_to")
        end
      else
        for stmt in scan:gmatch("[^%w_]use%s+(.-);") do
          for _, fqn in ipairs(expand_php_use(stmt)) do
            local target = php_fqn_to_path(fqn, g.psr4)
            if target and g.file_set[target] then
              add_node(file); add_node(target); add_edge(fid(file), fid(target), "uses")
            end
          end
        end
      end
      for _, v in ipairs(view_targets(scan, g)) do
        add_node(file); add_node(v); add_edge(fid(file), fid(v), "has-component")
      end
    end
  end
  for _, file in ipairs(g.blades) do
    local scan = read_scan(file)
    if scan then
      for _, t in ipairs(blade_targets(scan, g)) do
        add_node(file); add_node(t); add_edge(fid(file), fid(t), "has-component")
      end
    end
  end

  -- Start node: routes/web.php if present, else the first route file.
  local start = nodes[fid("routes/web.php")] or (g.routes[1] and nodes[fid(g.routes[1])])
  if start then start.entry = true; start.entryStart = true end

  local node_list, edge_list = {}, {}
  for _, n in pairs(nodes) do node_list[#node_list + 1] = n end
  for _, e in pairs(edges) do edge_list[#edge_list + 1] = e end
  table.sort(node_list, function(a, b) return a.id < b.id end)
  table.sort(edge_list, function(a, b) return a.id < b.id end)
  return {
    ok = true,
    payload = {
      scope = "functional", nodes = node_list, edges = edge_list,
      meta = { pack = "laravel", truncated = false, generatedAt = 0 },
    },
    text = string.format("Laravel functional: %d nodi, %d archi", #node_list, #edge_list),
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
