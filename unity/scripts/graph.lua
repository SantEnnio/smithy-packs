-- unity_graph — query the Unity scene/prefab/script graph.
--
-- Ported from the former native `smithy-unity::graph`. Builds the graph
-- deterministically from `.meta` GUIDs + `.unity`/`.prefab` YAML using only
-- the sandboxed `host` table. No inference. Scopes: summary | scene | script
-- | prefab | orphans.

local IGNORE = { "Library", "Temp", "Logs", "obj", "Build", "Builds", ".vs", ".idea" }

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function read_meta_guid(path)
  local ok, txt = pcall(host.read_file, path)
  if not ok or not txt then return nil end
  return txt:match("guid:%s*([%x][%x]+)")
end

-- The Editor build list (EditorBuildSettings.asset) — the functional ENTRY
-- POINTS: the scenes the game ships with, in order; the first enabled one is the
-- runtime start scene. Returns guid -> { order, enabled }.
local function read_build_scenes()
  local out = {}
  local ok, body = pcall(host.read_file, "ProjectSettings/EditorBuildSettings.asset")
  if not ok or not body then return out end
  local in_scenes, order, enabled = false, 0, nil
  for line in (body .. "\n"):gmatch("(.-)\n") do
    if line:match("^  m_Scenes:") then
      in_scenes = true
    elseif in_scenes and line:match("^  [%w_]") then
      in_scenes = false -- next top-level key ends the list
    elseif in_scenes then
      local en = line:match("enabled:%s*(%d)")
      if en then enabled = (en == "1") end
      local g = line:match("guid:%s*([%x][%x]+)")
      if g then
        order = order + 1
        out[g] = { order = order, enabled = enabled }
        enabled = nil
      end
    end
  end
  return out
end

-- First class/struct/interface name declared in a .cs file (best-effort).
local function class_name_of(path)
  local ok, txt = pcall(host.read_file, path)
  if not ok or not txt then return nil end
  for line in (txt .. "\n"):gmatch("(.-)\n") do
    -- Strip line/doc comments (`//`, `///`) and skip block-comment lines, so a
    -- prose "this class is responsible…" doesn't get parsed as a declaration
    -- (which yielded bogus labels like `is`).
    local code = line:gsub("//.*$", "")
    local trimmed = code:gsub("^%s+", "")
    if trimmed:sub(1, 1) ~= "*" and trimmed:sub(1, 2) ~= "/*" then
      local c = code:match("%f[%a]class%s+([%a_][%w_]*)")
      if c then return c end
    end
  end
  return nil
end

-- Stream a .unity/.prefab YAML: GameObjects (m_Name) and MonoBehaviours
-- (m_GameObject owner + m_Script guid). Mirrors the native line parser.
local function parse_container(path)
  local ok, body = pcall(host.read_file, path)
  if not ok or not body then return {}, {}, {} end
  local game_objects = {}   -- file_id -> name
  local mbs = {}            -- { file_id, game_object_file_id, script_guid }
  local stripped_src = {}   -- stripped GO file_id -> { fid, guid } of its source-prefab GO
  local cur_type, cur_fid = nil, nil
  for line in (body .. "\n"):gmatch("(.-)\n") do
    local t, fid = line:match("^%-%-%-%s+!u!(%d+)%s+&(%d+)")
    if t then
      cur_type, cur_fid = tonumber(t), tonumber(fid)
      if cur_type == 1 then
        game_objects[cur_fid] = game_objects[cur_fid] or "?"
      elseif cur_type == 114 then
        mbs[#mbs + 1] = { file_id = cur_fid }
      end
    elseif cur_type == 1 then
      local nm = line:match("^%s%sm_Name:%s*(.-)%s*$")
      if nm and nm ~= "" then game_objects[cur_fid] = nm end
      -- Prefab-instance GameObjects serialize as `stripped` (no m_Name); their
      -- real name lives in the source prefab, reached via this reference.
      local sf, sg = line:match("m_CorrespondingSourceObject:%s*{%s*fileID:%s*(%-?%d+),%s*guid:%s*([%x]+)")
      if sf and sg and tonumber(sf) ~= 0 then
        stripped_src[cur_fid] = { fid = tonumber(sf), guid = sg }
      end
    elseif cur_type == 114 then
      local cur = mbs[#mbs]
      if cur then
        local go = line:match("m_GameObject:%s*{%s*fileID:%s*(%-?%d+)")
        if go then cur.game_object_file_id = tonumber(go) end
        if line:find("m_Script:", 1, true) then
          local g = line:match("guid:%s*([%x][%x]+)")
          if g then cur.script_guid = g end
        end
      end
    end
  end
  return game_objects, mbs, stripped_src
end

-- Build the whole graph from disk.
local function build()
  local rows = host.walk_dir("Assets", { ignore = IGNORE, ext = { "meta", "cs", "unity", "prefab" } })
  local guid_of = {}            -- inner path -> guid
  local cs_files, container_files = {}, {}
  for _, r in ipairs(rows) do
    if r.ext == "meta" then
      local inner = r.path:gsub("%.meta$", "")
      local g = read_meta_guid(r.path)
      if g then guid_of[inner] = g end
    elseif r.ext == "cs" then
      cs_files[#cs_files + 1] = r.path
    elseif r.ext == "unity" or r.ext == "prefab" then
      container_files[#container_files + 1] = { path = r.path, kind = r.ext }
    end
  end

  local scripts = {}            -- guid -> { guid, path, class_name }
  for _, p in ipairs(cs_files) do
    local g = guid_of[p]
    if g then
      scripts[g] = { guid = g, path = p, class_name = class_name_of(p) }
    end
  end

  -- Pass 1: parse every scene/prefab into a node (so cross-file name resolution
  -- below can reach any source prefab).
  local scenes, prefabs = {}, {}     -- guid -> container node
  for _, cf in ipairs(container_files) do
    local g = guid_of[cf.path]
    if g then
      local gos, mbs, stripped = parse_container(cf.path)
      local node = { guid = g, path = cf.path, game_objects = gos, mono_behaviours = mbs,
                     stripped_src = stripped, kind = (cf.kind == "unity") and "scene" or "prefab" }
      if cf.kind == "unity" then scenes[g] = node else prefabs[g] = node end
    end
  end

  -- Flag the build-list scenes (functional entry points) + the start scene.
  local build_scenes = read_build_scenes()
  local start_order
  for guid, info in pairs(build_scenes) do
    if info.enabled and (not start_order or info.order < start_order) then
      start_order = info.order
    end
  end
  for guid, node in pairs(scenes) do
    local info = build_scenes[guid]
    -- Only ENABLED build-list scenes are entry points; a disabled scene won't
    -- ship at runtime, so it stays a regular scene (no badge, no priority).
    if info and info.enabled then
      node.entry = true
      node.entry_order = info.order
      node.entry_start = info.order == start_order
    end
  end

  -- Resolve a GameObject's name, following m_CorrespondingSourceObject across
  -- files for stripped prefab-instance GameObjects (whose name isn't local).
  local by_guid = {}
  for g, n in pairs(scenes) do by_guid[g] = n end
  for g, n in pairs(prefabs) do by_guid[g] = n end
  local function resolve_go(node, fid, depth)
    if not node or not fid or depth > 8 then return nil end
    local nm = node.game_objects[fid]
    if nm and nm ~= "?" then return nm end
    local src = node.stripped_src and node.stripped_src[fid]
    if src then
      local up = resolve_go(by_guid[src.guid], src.fid, depth + 1)
      if up then return up end
    end
    return nm -- "?" (known but unnamed) or nil (not a GameObject here)
  end

  -- Pass 2: index script usages with resolved GameObject names.
  local script_usage = {}            -- guid -> list of usages
  for _, node in pairs(by_guid) do
    for _, mb in ipairs(node.mono_behaviours) do
      if mb.script_guid then
        local on = resolve_go(node, mb.game_object_file_id, 0)
        script_usage[mb.script_guid] = script_usage[mb.script_guid] or {}
        local u = script_usage[mb.script_guid]
        u[#u + 1] = {
          kind = node.kind,
          container_guid = node.guid,
          container_path = node.path,
          component_file_id = mb.file_id,
          game_object_name = on,
        }
      end
    end
  end

  return {
    scripts = scripts,
    scenes = scenes,
    prefabs = prefabs,
    script_usage = script_usage,
    resolve_go = resolve_go,
  }
end

-- ---- helpers over the built graph ----

local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end

local function values(t) local v = {} for _, x in pairs(t) do v[#v + 1] = x end return v end

local function label_for_script(g, guid)
  local s = guid and g.scripts[guid]
  if not s then return "(unresolved)" end
  return s.class_name or s.path
end

local function find_container(map, needle)
  local nlc = needle:lower()
  for _, c in pairs(map) do
    local leaf = (c.path:match("([^/]+)$") or c.path):lower()
    if leaf == nlc or c.path:lower():find(nlc, 1, true) then return c end
  end
  return nil
end

local function script_matches(s, needle)
  local nlc = needle:lower()
  if s.class_name and s.class_name:lower() == nlc then return true end
  local leaf = (s.path:match("([^/]+)$") or s.path):lower()
  if leaf == nlc or leaf == (nlc .. ".cs") then return true end
  return s.path:lower():find(nlc, 1, true) ~= nil
end

local function orphans(g)
  local out = {}
  for guid, s in pairs(g.scripts) do
    if not g.script_usage[guid] then out[#out + 1] = s end
  end
  return out
end

-- ---- scopes ----

local function scope_summary(g)
  local nscripts, nscenes, nprefabs = count(g.scripts), count(g.scenes), count(g.prefabs)
  local text = string.format("Unity graph — Scripts: %d, Scenes: %d, Prefabs: %d\n",
    nscripts, nscenes, nprefabs)
  local names = {}
  for _, s in pairs(g.scripts) do names[#names + 1] = s.class_name or s.path end
  table.sort(names)
  if #names > 0 then text = text .. "Scripts: " .. table.concat(names, ", ") .. "\n" end
  return {
    ok = true,
    payload = { scope = "summary", scripts = nscripts, scenes = nscenes, prefabs = nprefabs },
    text = text,
  }
end

local function scope_scene(g, name)
  if not name then return { ok = false, text = "scope=scene requires `name` (e.g. `Main.unity`)." } end
  local scene = find_container(g.scenes, name)
  if not scene then
    local known = {}
    for _, c in pairs(g.scenes) do known[#known + 1] = c.path end
    return { ok = false, text = "no scene matched `" .. name .. "`. Known: " .. (table.concat(known, ", ")) }
  end
  local text = "# Scene: " .. scene.path .. "\n"
  if #scene.mono_behaviours == 0 then
    text = text .. "(no MonoBehaviours)\n"
  else
    text = text .. string.format("%d MonoBehaviour(s):\n", #scene.mono_behaviours)
    for _, mb in ipairs(scene.mono_behaviours) do
      local go = mb.game_object_file_id and scene.game_objects[mb.game_object_file_id] or "?"
      text = text .. string.format("- GameObject `%s` → %s (fileID %d)\n",
        go, label_for_script(g, mb.script_guid), mb.file_id)
    end
  end
  return { ok = true, payload = { scope = "scene", scene = { guid = scene.guid, path = scene.path,
    mono_behaviour_count = #scene.mono_behaviours } }, text = text }
end

local function scope_prefab(g, name)
  if not name then return { ok = false, text = "scope=prefab requires `name` (e.g. `Player.prefab`)." } end
  local pf = find_container(g.prefabs, name)
  if not pf then return { ok = false, text = "no prefab matched `" .. name .. "`." } end
  local text = "# Prefab: " .. pf.path .. "\nGameObjects: " .. count(pf.game_objects) .. "\n"
  for fid, nm in pairs(pf.game_objects) do
    text = text .. string.format("- %s (fileID %d)\n", nm, fid)
  end
  text = text .. string.format("\nMonoBehaviours: %d\n", #pf.mono_behaviours)
  for _, mb in ipairs(pf.mono_behaviours) do
    local go = mb.game_object_file_id and pf.game_objects[mb.game_object_file_id] or "?"
    text = text .. string.format("- %s → %s\n", go, label_for_script(g, mb.script_guid))
  end
  return { ok = true, payload = { scope = "prefab", prefab = { guid = pf.guid, path = pf.path } }, text = text }
end

local function scope_script(g, name)
  if not name then return { ok = false, text = "scope=script requires `name` (class or filename)." } end
  local script = nil
  for _, s in pairs(g.scripts) do if script_matches(s, name) then script = s break end end
  if not script then return { ok = false, text = "no script matched `" .. name .. "`." } end
  local usages = g.script_usage[script.guid] or {}
  local class = script.class_name or script.path
  local text = string.format("# Script: %s (%s)\nGUID: %s\n", class, script.path, script.guid)
  if #usages == 0 then
    text = text .. "Used by: nothing (orphan or attached at runtime).\n"
  else
    text = text .. string.format("Used by %d container(s):\n", #usages)
    for _, u in ipairs(usages) do
      text = text .. string.format("- %s `%s` on GameObject `%s` (fileID %d)\n",
        u.kind, u.container_path, u.game_object_name or "?", u.component_file_id)
    end
  end
  return { ok = true, payload = { scope = "script", script = { guid = script.guid, path = script.path,
    class_name = script.class_name }, usage_count = #usages }, text = text }
end

local function scope_orphans(g)
  local orph = orphans(g)
  local text = string.format("%d orphan script(s):\n", #orph)
  local payload_list = {}
  for _, s in ipairs(orph) do
    text = text .. string.format("- %s — %s\n", s.class_name or s.path, s.path)
    payload_list[#payload_list + 1] = { path = s.path, guid = s.guid, class_name = s.class_name }
  end
  if #orph == 0 then
    text = text .. "(every script with a .meta is referenced by at least one scene or prefab)\n"
  end
  return { ok = true, payload = { scope = "orphans", orphans = payload_list }, text = text }
end

-- Normalized structure-graph overlay for the graph-native "Attuale" map: the
-- scene/script/prefab files already exist as project_tree `file:<path>` nodes,
-- so we emit only the USAGE edges (scene/prefab → script) to overlay on them.
local function scope_graph(g)
  local edges = {}
  for guid, usages in pairs(g.script_usage) do
    local script = g.scripts[guid]
    if script then
      for _, u in ipairs(usages) do
        edges[#edges + 1] = {
          from = "file:" .. u.container_path,
          to = "file:" .. script.path,
          kind = "uses",
          confidence = "static",
        }
      end
    end
  end
  return {
    ok = true,
    payload = { scope = "graph", nodes = {}, edges = edges },
    text = string.format("Unity graph: %d uses-edge(s)", #edges),
  }
end

-- Normalized FUNCTIONAL graph for the graph-native "Attuale" map: the domain
-- entities (Scene/Prefab → GameObject → Script) and their declarative wiring,
-- NOT files in folders. Unlike scope:"graph" (which flattens to a file→file
-- overlay on project_tree), this emits its OWN nodes — the backend returns the
-- payload as-is and the frontend `normalize()`s it directly. Edges:
--   Scene/Prefab `contains` GameObject  (containment — dashed in the canvas)
--   GameObject  `has-component` Script  (the wiring — blue arrow; doubles as the
--                                        tree-hierarchy link so Scripts nest under
--                                        their GameObject for the LOD drill-down)
local function scope_functional(g)
  local function leaf(p) return (p:match("([^/]+)$")) or p end
  local nodes, edges = {}, {}   -- id -> node, id -> edge (dedup)
  local function add_node(n) if not nodes[n.id] then nodes[n.id] = n end end
  local function add_edge(from, to, kind)
    local id = kind .. ":" .. from .. "->" .. to
    if not edges[id] then
      edges[id] = { id = id, from = from, to = to, kind = kind, confidence = "static" }
    end
  end

  -- Prefabs worth showing: those that actually host a resolvable script. A scene
  -- that instantiates such a prefab NESTS it (instead of duplicating the prefab's
  -- internals as loose GameObjects) — so the graph reads as "this entry scene is
  -- composed of these prefabs + objects", rooted at the scenes. Decorative
  -- (script-less) prefabs are dropped as noise.
  local prefab_has_script = {}
  for guid, pf in pairs(g.prefabs) do
    for _, mb in ipairs(pf.mono_behaviours) do
      if mb.script_guid and g.scripts[mb.script_guid] then
        prefab_has_script[guid] = true
        break
      end
    end
  end

  local function emit_container(c)
    local cid = (c.kind == "scene" and "scene:" or "prefab:") .. c.guid
    local container_added = false
    local function ensure_container()
      if not container_added then
        local node = { id = cid, kind = c.kind, label = leaf(c.path), path = c.path,
                       groupId = cid, confidence = "static" }
        if c.entry then
          node.entry = true
          node.entryStart = c.entry_start or false
          node.entryOrder = c.entry_order
        end
        add_node(node)
        container_added = true
      end
    end

    -- The scripted prefabs this container instantiates (from EVERY stripped
    -- GameObject's source reference, not just those carrying a script) → nest
    -- each one once, so the scene reads as "composed of these prefabs".
    local nested = {}
    if c.stripped_src then
      for _, src in pairs(c.stripped_src) do
        if src.guid and prefab_has_script[src.guid] and not nested[src.guid] then
          nested[src.guid] = true
          local pf = g.prefabs[src.guid]
          ensure_container()
          local pcid = "prefab:" .. src.guid
          add_node({ id = pcid, kind = "prefab", label = leaf(pf.path), path = pf.path,
                     groupId = pcid, confidence = "static" })
          add_edge(cid, pcid, "contains")
        end
      end
    end

    -- Direct GameObjects (not instances of a nested prefab) that host a script.
    for _, mb in ipairs(c.mono_behaviours) do
      local fid = mb.game_object_file_id
      local src = fid and c.stripped_src and c.stripped_src[fid]
      local in_nested_prefab = src and nested[src.guid]
      if not in_nested_prefab then
        local s = mb.script_guid and g.scripts[mb.script_guid]
        if s then
          ensure_container()
          local sid = "script:" .. s.guid
          add_node({ id = sid, kind = "symbol", label = s.class_name or leaf(s.path),
                     path = s.path, confidence = "static" })
          local go_name = fid and g.resolve_go(c, fid, 0)
          if fid and go_name then
            local gid = "go:" .. c.guid .. ":" .. fid
            add_node({ id = gid, kind = "entity", label = go_name, groupId = cid,
                       confidence = "static" })
            add_edge(cid, gid, "contains")
            add_edge(gid, sid, "has-component")
          else
            add_edge(cid, sid, "has-component")
          end
        end
      end
    end
  end

  for _, c in pairs(g.scenes) do emit_container(c) end
  for _, c in pairs(g.prefabs) do emit_container(c) end

  -- Relegate prefabs that no scene/prefab instantiates (they're spawned at
  -- runtime from code we don't parse) under one collapsed bucket, so they don't
  -- clutter the entry-rooted map as loose top-level roots.
  local has_parent = {}
  for _, e in pairs(edges) do
    if e.kind == "contains" then has_parent[e.to] = true end
  end
  local loose = {}
  for id, n in pairs(nodes) do
    if n.kind == "prefab" and not has_parent[id] then loose[#loose + 1] = id end
  end
  table.sort(loose)
  if #loose > 0 then
    local bid = "bucket:runtime"
    add_node({ id = bid, kind = "runtime", label = "Caricati a runtime / non in scena",
               groupId = bid, confidence = "static" })
    for _, pid in ipairs(loose) do add_edge(bid, pid, "contains") end
  end

  -- Deterministic arrays (pairs() order is unspecified; the frontend re-sorts
  -- anyway, but stable output keeps the unit tests and diffs sane).
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
      meta = { pack = "unity", truncated = false, generatedAt = 0 },
    },
    text = string.format("Unity functional: %d nodi, %d archi", #node_list, #edge_list),
  }
end

function execute(args)
  args = args or {}
  local scope = args.scope or "summary"
  local g = build()
  if scope == "summary" then return scope_summary(g) end
  if scope == "scene" then return scope_scene(g, args.name) end
  if scope == "script" then return scope_script(g, args.name) end
  if scope == "prefab" then return scope_prefab(g, args.name) end
  if scope == "orphans" then return scope_orphans(g) end
  if scope == "graph" then return scope_graph(g) end
  if scope == "functional" then return scope_functional(g) end
  return { ok = false, text = "unknown scope `" .. tostring(scope) ..
    "` — expected: summary, scene, script, prefab, orphans, graph, functional" }
end
