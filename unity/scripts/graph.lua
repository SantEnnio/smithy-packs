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

-- First class/struct/interface name declared in a .cs file (best-effort).
local function class_name_of(path)
  local ok, txt = pcall(host.read_file, path)
  if not ok or not txt then return nil end
  for line in (txt .. "\n"):gmatch("(.-)\n") do
    local c = line:match("%f[%a]class%s+([%a_][%w_]*)")
    if c then return c end
  end
  return nil
end

-- Stream a .unity/.prefab YAML: GameObjects (m_Name) and MonoBehaviours
-- (m_GameObject owner + m_Script guid). Mirrors the native line parser.
local function parse_container(path)
  local ok, body = pcall(host.read_file, path)
  if not ok or not body then return {}, {} end
  local game_objects = {}   -- file_id -> name
  local mbs = {}            -- { file_id, game_object_file_id, script_guid }
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
      if nm then game_objects[cur_fid] = nm end
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
  return game_objects, mbs
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

  local scenes, prefabs = {}, {}     -- guid -> container node
  local script_usage = {}            -- guid -> list of usages
  for _, cf in ipairs(container_files) do
    local g = guid_of[cf.path]
    if g then
      local gos, mbs = parse_container(cf.path)
      local node = { guid = g, path = cf.path, game_objects = gos, mono_behaviours = mbs,
                     kind = (cf.kind == "unity") and "scene" or "prefab" }
      if cf.kind == "unity" then scenes[g] = node else prefabs[g] = node end
      for _, mb in ipairs(mbs) do
        if mb.script_guid then
          local on = mb.game_object_file_id and gos[mb.game_object_file_id] or nil
          script_usage[mb.script_guid] = script_usage[mb.script_guid] or {}
          local u = script_usage[mb.script_guid]
          u[#u + 1] = {
            kind = node.kind,
            container_guid = g,
            container_path = cf.path,
            component_file_id = mb.file_id,
            game_object_name = on,
          }
        end
      end
    end
  end

  return { scripts = scripts, scenes = scenes, prefabs = prefabs, script_usage = script_usage }
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

function execute(args)
  args = args or {}
  local scope = args.scope or "summary"
  local g = build()
  if scope == "summary" then return scope_summary(g) end
  if scope == "scene" then return scope_scene(g, args.name) end
  if scope == "script" then return scope_script(g, args.name) end
  if scope == "prefab" then return scope_prefab(g, args.name) end
  if scope == "orphans" then return scope_orphans(g) end
  return { ok = false, text = "unknown scope `" .. tostring(scope) ..
    "` — expected: summary, scene, script, prefab, orphans" }
end
