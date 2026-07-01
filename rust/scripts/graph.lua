-- rust_graph — Rust import-relationship overlay for the graph-native "Attuale" map.
--
-- On `execute({scope="graph"})` this walks the project's *.rs files, discovers
-- every crate root (any src/lib.rs and src/main.rs anywhere in the tree, so a
-- single crate opened at its root AND a cargo workspace are handled by the same
-- code with no mode switch), follows `mod foo;` declarations to build a
-- per-crate module-path -> file map, then resolves intra-crate `use` statements
-- (crate:: / super:: / self::) to the file of the longest module-path prefix and
-- emits `imports` edges between the source files.
--
-- Output contract mirrors packs/unity/scripts/graph.lua's scope_graph:
--   { ok=true, payload={ scope="graph", nodes={}, edges={...} }, text="..." }
-- Edges:  { from="file:<p>", to="file:<p>", kind="imports", confidence="static" }
-- where <p> is the root-relative, "/"-separated path EXACTLY as host.walk_dir
-- returns it, so the ids match the app's project_tree `file:<path>` nodes.
--
-- Resolution is deterministic via the mod-map, so every edge is `static`. No
-- fuzzy filename fallback is used in v0 (accurate over ambitious): external /
-- std / sibling-crate uses, unresolvable uses, and self-edges are dropped, so no
-- dangling or wrong edges reach the merge in src/graph/structureGraph.ts.

local IGNORE = { "target", ".git", "node_modules" }

-- ---- small path helpers ----

-- "a/b/c.rs" -> "a/b" ; "x.rs" -> "" (no directory component)
local function dir_of(path)
  return path:match("^(.*)/[^/]+$") or ""
end

local function base_of(path)
  return path:match("([^/]+)$") or path
end

-- Returns crate_dir ("" for a root-level crate) if `path` is a crate root,
-- else nil. A crate root is src/lib.rs or src/main.rs anywhere in the tree.
local function crate_dir_of(path)
  local d = path:match("^(.*)/src/lib%.rs$") or path:match("^(.*)/src/main%.rs$")
  if d then return d end
  if path == "src/lib.rs" or path == "src/main.rs" then return "" end
  -- rare: a project with no src/ but a top-level lib.rs/main.rs
  if path == "lib.rs" or path == "main.rs" then return "" end
  return nil
end

-- Declaring DIRECTORY for a child `mod NAME` inside `file`:
--   lib.rs / main.rs / mod.rs declare into their OWN directory;
--   a file `stem.rs` declaring submodules declares into `<dir>/stem/`.
local function decl_dir(file)
  local b = base_of(file)
  local d = dir_of(file)
  if b == "lib.rs" or b == "main.rs" or b == "mod.rs" then
    return d
  end
  local stem = b:gsub("%.rs$", "")
  if d == "" then return stem end
  return d .. "/" .. stem
end

-- Pick the file backing `mod NAME` declared in `dir`, preferring NAME.rs then
-- NAME/mod.rs, but only if it is in the walked set (`rs_set`). nil if neither.
local function mod_file_for(dir, name, rs_set)
  local flat = (dir == "" and (name .. ".rs")) or (dir .. "/" .. name .. ".rs")
  if rs_set[flat] then return flat end
  local nested = (dir == "" and (name .. "/mod.rs")) or (dir .. "/" .. name .. "/mod.rs")
  if rs_set[nested] then return nested end
  return nil
end

-- A FILE module declaration: `mod NAME;` (terminated by `;`), tolerating a
-- leading visibility modifier (`pub`, `pub(crate)`, `pub(in ...)`). An inline
-- module `mod NAME { ... }` (contains `{`) returns nil (no file). Lines that are
-- line-comments are rejected by the caller.
local function mod_decl_name(line)
  local l = line:gsub("^%s*pub%s*%b()%s*", ""):gsub("^%s*pub%s+", "")
  if l:find("{", 1, true) then return nil end
  return l:match("^%s*mod%s+([%a_][%w_]*)%s*;")
end

-- Split a "::"-joined module path into a segment array.
local function split_segs(modpath)
  local segs = {}
  if modpath == "" then return segs end
  for s in modpath:gmatch("[^:]+") do
    segs[#segs + 1] = s
  end
  return segs
end

-- Longest-prefix resolve of an absolute segment list against the crate's
-- mod-map. Peels trailing segments (symbols/types/fns) until a module file hits.
local function resolve_modpath(crate_dir, segs, mod_file)
  for n = #segs, 1, -1 do
    local key = crate_dir .. "\0" .. table.concat(segs, "::", 1, n)
    local f = mod_file[key]
    if f then return f end
  end
  return nil
end

-- ---- build the per-crate mod-map ----
--
-- mod_file   : (crate_dir .. "\0" .. dotted_module_path) -> file-path
-- file_module: file-path -> { crate_dir=..., modpath="a::b" }  (for super/self)
local function build()
  local rows = host.walk_dir(".", { ignore = IGNORE, ext = { "rs" } })
  local rs_set = {}
  for _, r in ipairs(rows) do
    if r.is_file then rs_set[r.path] = true end
  end

  local mod_file = {}
  local file_module = {}
  local visited = {}      -- file-path -> true (cycle / re-enqueue guard)
  local queue = {}        -- { file, crate_dir, modpath }

  -- Seed each crate root as the crate-root module (modpath = "").
  for path in pairs(rs_set) do
    local cdir = crate_dir_of(path)
    if cdir ~= nil then
      mod_file[cdir .. "\0" .. ""] = path
      file_module[path] = { crate_dir = cdir, modpath = "" }
      if not visited[path] then
        visited[path] = true
        queue[#queue + 1] = { file = path, crate_dir = cdir, modpath = "" }
      end
    end
  end

  -- BFS: follow `mod NAME;` declarations from each reachable file.
  local qi = 1
  while qi <= #queue do
    local item = queue[qi]
    qi = qi + 1
    local ok, body = pcall(host.read_file, item.file)
    if ok and body then
      local ddir = decl_dir(item.file)
      for line in (body .. "\n"):gmatch("(.-)\n") do
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed:sub(1, 2) ~= "//" then
          local name = mod_decl_name(line)
          if name then
            local child = mod_file_for(ddir, name, rs_set)
            if child then
              local child_modpath =
                (item.modpath == "" and name) or (item.modpath .. "::" .. name)
              local key = item.crate_dir .. "\0" .. child_modpath
              -- First declaration wins (deterministic; guards weird dup decls).
              if not mod_file[key] then mod_file[key] = child end
              if not file_module[child] then
                file_module[child] = { crate_dir = item.crate_dir, modpath = child_modpath }
              end
              if not visited[child] then
                visited[child] = true
                queue[#queue + 1] =
                  { file = child, crate_dir = item.crate_dir, modpath = child_modpath }
              end
            end
          end
        end
      end
    end
  end

  local ncrates = 0
  for path in pairs(rs_set) do
    if crate_dir_of(path) ~= nil then
      -- count distinct crate roots' worth is approximate; count entry files.
      ncrates = ncrates + 1
    end
  end

  return { rs_set = rs_set, mod_file = mod_file, file_module = file_module, ncrates = ncrates }
end

-- ---- resolve `use` statements into a leaf path list ----
--
-- Expand a single `use` statement string into resolution-target paths. For a
-- braced group we resolve the PREFIX (parent module) — accurate and never wrong
-- — plus each direct (non-nested) leaf for deeper precision.
local function expand_use(stmt)
  local out = {}
  local brace = stmt:find("{", 1, true)
  if not brace then
    -- single path; strip a trailing ` as Alias`
    local p = stmt:gsub("%s+as%s+[%a_][%w_]*%s*$", "")
    p = p:gsub("%s+", "")
    if p ~= "" then out[#out + 1] = p end
    return out
  end

  local prefix = stmt:sub(1, brace - 1):gsub("%s+", "")
  -- prefix typically ends with "::" — normalize to no trailing "::"
  prefix = prefix:gsub("::%s*$", "")
  if prefix ~= "" then out[#out + 1] = prefix end

  -- Inner list between the first '{' and the matching closing — best-effort:
  -- take up to the last '}'. Split top-level commas; ignore nested groups by
  -- only keeping items without their own '{' (the prefix above already covers
  -- the nested parent module).
  local last = stmt:match("^.*()}")
  local inner = stmt:sub(brace + 1, (last and last - 1) or #stmt)
  for item in inner:gmatch("[^,]+") do
    -- Strip an ` as Alias` rename BEFORE collapsing whitespace, so the safe
    -- whitespace-anchored form matches (`Foo as Bar`, `Foo as _`). Doing it
    -- after the `%s+`-collapse would force an unanchored `as...$` strip that
    -- could clip a real trailing segment ending in "as" (e.g. `Canvas`,
    -- `Bias`, `Overhead`). Tolerate a `_` alias target too (`Trait as _`).
    local it = item:gsub("%s+as%s+[%a_][%w_]*%s*$", "")
    it = it:gsub("%s+", "")
    if it ~= "" and not it:find("{", 1, true) and not it:find("}", 1, true) then
      -- self/super inside a group are relative to the group prefix; skip the
      -- bare "self" item (it just re-imports the prefix module already added).
      if it ~= "self" and it ~= "" and prefix ~= "" then
        out[#out + 1] = prefix .. "::" .. it
      elseif it ~= "self" and it ~= "" and prefix == "" then
        out[#out + 1] = it
      end
    end
  end
  return out
end

-- Normalize one use-path into an absolute (crate_dir, segment-list) for file F,
-- honoring crate:: / super:: / self::. Returns nil for external/std/sibling.
local function absolutize(path, fmod)
  -- strip a trailing "::*" glob marker and any leftover "as"
  path = path:gsub("::%*$", "")
  local segs = split_segs(path)
  if #segs == 0 then return nil end
  local head = segs[1]

  if head == "crate" then
    table.remove(segs, 1)
    return fmod.crate_dir, segs
  elseif head == "self" then
    table.remove(segs, 1)
    local base = split_segs(fmod.modpath)
    for _, s in ipairs(segs) do base[#base + 1] = s end
    return fmod.crate_dir, base
  elseif head == "super" then
    local base = split_segs(fmod.modpath)
    local i = 1
    while segs[i] == "super" do
      if #base == 0 then return nil end -- super past crate root
      base[#base] = nil
      i = i + 1
    end
    for j = i, #segs do base[#base + 1] = segs[j] end
    return fmod.crate_dir, base
  end
  -- std / core / alloc / external crate / sibling workspace crate -> skip.
  return nil
end

local function scope_graph(g)
  local edges = {}
  local emitted = {}

  for file, fmod in pairs(g.file_module) do
    local ok, body = pcall(host.read_file, file)
    if ok and body then
      -- Grab whole use-statements; non-greedy `.-` stops at first `;`, so a
      -- braced multi-line group is captured up to its terminating semicolon.
      -- Optional leading `pub ` (re-exports count as real imports) tolerated by
      -- matching `use%s+` after the keyword anywhere at a boundary.
      --
      -- A leading boundary char ([%s\n;]) is REQUIRED before `use` so that
      -- identifiers ending in "use" (e.g. `reuse_crate_a`) are not mistaken for
      -- a `use` keyword. But that boundary would also DROP a `use` statement
      -- sitting at byte-0 of the file — extremely common in real Rust, where
      -- most non-root modules open with `use` on line 1. Prepend a sentinel
      -- newline (mirroring the mod-BFS `(body .. "\n")`) so the very first
      -- `use` still matches while the boundary guard is preserved.
      for stmt in ("\n" .. body):gmatch("[%s\n;]use%s+(.-);") do
        -- skip obvious comment/string noise
        if not stmt:find("//", 1, true) and not stmt:find("\"", 1, true) then
          local paths = expand_use(stmt)
          for _, p in ipairs(paths) do
            local crate_dir, segs = absolutize(p, fmod)
            if crate_dir ~= nil and segs and #segs > 0 then
              local target = resolve_modpath(crate_dir, segs, g.mod_file)
              if target and target ~= file then
                local k = file .. "->" .. target
                if not emitted[k] then
                  emitted[k] = true
                  edges[#edges + 1] = {
                    from = "file:" .. file,
                    to = "file:" .. target,
                    kind = "imports",
                    confidence = "static",
                  }
                end
              end
            end
          end
        end
      end
    end
  end

  return {
    ok = true,
    payload = { scope = "graph", nodes = {}, edges = edges },
    text = string.format("Rust graph: %d imports-edge(s)", #edges),
  }
end

local function scope_summary(g)
  local nfiles = 0
  for _ in pairs(g.rs_set) do nfiles = nfiles + 1 end
  local nmods = 0
  for _ in pairs(g.file_module) do nmods = nmods + 1 end
  return {
    ok = true,
    payload = { scope = "summary", files = nfiles, modules = nmods },
    text = string.format("Rust graph — files: %d, resolved modules: %d", nfiles, nmods),
  }
end

-- ---- functional lens ----------------------------------------------------
--
-- The graph-native FUNCTIONAL map for Rust: rooted at the ENTRY POINTS = the
-- crate roots (`main.rs` = binary entry; `lib.rs` = library/API entry), flowing
-- outward to the modules they're composed of. The module tree (`mod foo;`
-- declarations) is the containment hierarchy re-cast as `has-component` edges
-- (crate root → module → submodule); intra-crate `use` references overlay as
-- `uses` (drawn connectors, not hierarchy). Emits its own normalized graph.
local function scope_functional(g)
  local nodes, edges = {}, {}
  local function fid(p) return "file:" .. p end
  local function add_node(id, path)
    if not nodes[id] then
      -- Label by module name: `src/agent/mod.rs` → "agent", `foo.rs` → "foo";
      -- the crate roots keep `lib.rs`/`main.rs` (recognisable entry files).
      local b = base_of(path)
      local label
      if b == "mod.rs" then
        label = (dir_of(path):match("([^/]+)$")) or b
      elseif b == "lib.rs" or b == "main.rs" then
        label = b
      else
        label = (b:gsub("%.rs$", ""))
      end
      nodes[id] = { id = id, kind = "module", label = label, path = path, confidence = "static" }
    end
  end
  local function add_edge(from, to, kind)
    if from == to then return end
    local eid = kind .. ":" .. from .. "->" .. to
    if not edges[eid] then
      edges[eid] = { id = eid, from = from, to = to, kind = kind, confidence = "static" }
    end
  end

  -- 1) Module-tree composition: a module's parent (its modpath minus the last
  -- segment) `has-component` it. Roots (modpath "") get no parent edge.
  for file, fmod in pairs(g.file_module) do
    if fmod.modpath ~= "" then
      local parent = fmod.modpath:match("^(.*)::[^:]+$") or ""
      local pfile = g.mod_file[fmod.crate_dir .. "\0" .. parent]
      if pfile then add_edge(fid(pfile), fid(file), "has-component") end
    end
  end

  -- 2) Intra-crate `use` references overlay as `uses` (resolution reused from
  -- the structural scope).
  for file, fmod in pairs(g.file_module) do
    local ok, body = pcall(host.read_file, file)
    if ok and body then
      for stmt in ("\n" .. body):gmatch("[%s\n;]use%s+(.-);") do
        if not stmt:find("//", 1, true) and not stmt:find("\"", 1, true) then
          for _, p in ipairs(expand_use(stmt)) do
            local crate_dir, segs = absolutize(p, fmod)
            if crate_dir ~= nil and segs and #segs > 0 then
              local target = resolve_modpath(crate_dir, segs, g.mod_file)
              if target then add_edge(fid(file), fid(target), "uses") end
            end
          end
        end
      end
    end
  end

  -- 3) Nodes for every module file; mark crate roots as entry. The start = a
  -- `main.rs` (binary) if any, else `lib.rs` (the API entry).
  local roots = {}
  for file, fmod in pairs(g.file_module) do
    add_node(fid(file), file)
    if fmod.modpath == "" then roots[#roots + 1] = file end
  end
  table.sort(roots)
  local start_file
  for _, f in ipairs(roots) do if base_of(f) == "main.rs" then start_file = f break end end
  if not start_file then for _, f in ipairs(roots) do if base_of(f) == "lib.rs" then start_file = f break end end end
  if not start_file then start_file = roots[1] end
  for _, f in ipairs(roots) do
    local n = nodes[fid(f)]
    if n then
      n.entry = true
      n.entryStart = (f == start_file)
    end
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
      meta = { pack = "rust", truncated = false, generatedAt = 0 },
    },
    text = string.format("Rust functional: %d nodi, %d archi", #node_list, #edge_list),
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
