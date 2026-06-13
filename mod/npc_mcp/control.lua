--[[
  npc_mcp / control.lua  (multi-NPC edition)

  Each NPC is keyed by name in storage.npcs[name]. Every remote function
  takes `npc_name` as the first argument so that multiple MCP clients
  (e.g. several Claude Desktops, each bound to its own character) can
  share one Factorio world.

  Backwards compat: any old single-NPC save's storage.npc is migrated
  to storage.npcs["Botty"] on configuration_changed / on_init.
]]

-- ============================================================================
-- json helpers
-- ============================================================================
local function jenc(t) return helpers.table_to_json(t) end
local function ok_resp(t) t = t or {}; t.ok = true; return jenc(t) end
local function err_resp(msg, extra)
  local t = extra or {}; t.ok = false; t.error = msg; return jenc(t)
end

-- ============================================================================
-- storage
-- ============================================================================
local DEFAULT_SURFACE = "nauvis"
local EVENT_CAP = 200

local function fresh_npc_state()
  return {
    entity         = nil,
    intent         = { kind = "idle" },
    path           = nil,
    path_request   = nil,
    path_goal      = nil,
    mine_target    = nil,
    last_mine_tick = 0,
    craft_queue    = {},
    events         = {},
    -- combat: auto-engage enemies in range from the per-tick driver.
    combat         = { enabled = false, range = 20, retreat_hp_pct = 30, target_un = nil, retreated = false },
    -- drive_goal: when set and entity.vehicle exists, steer the vehicle here.
    drive_goal     = nil,
  }
end

local function ensure_storage()
  storage.npcs          = storage.npcs or {}
  storage.path_requests = storage.path_requests or {}   -- req_id -> npc name
  storage.surface_name  = storage.surface_name or DEFAULT_SURFACE
  -- migrate from single-NPC schema if present
  if storage.npc and not next(storage.npcs) then
    local legacy = storage.npc
    local name = (legacy.config and legacy.config.nameplate) or "Botty"
    storage.npcs[name] = {
      entity         = legacy.entity,
      intent         = legacy.intent or { kind = "idle" },
      path           = legacy.path,
      path_request   = legacy.path_request,
      path_goal      = legacy.path_goal,
      mine_target    = legacy.mine_target,
      last_mine_tick = legacy.last_mine_tick or 0,
      craft_queue    = legacy.craft_queue or {},
      events         = legacy.events or {},
    }
    storage.npc = nil
  end
end

local function get_npc(name)
  if not name or type(name) ~= "string" or name == "" then
    return nil, "npc_name is required (non-empty string)"
  end
  ensure_storage()
  local self = storage.npcs[name]
  if not self then
    return nil, "unknown npc '" .. name .. "' — call npc_spawn('" .. name .. "') first"
  end
  return self, nil
end

local function ent_of(self)
  if self and self.entity and self.entity.valid then return self.entity end
  return nil
end

local function push_event(self, kind, data)
  if not self then return end
  table.insert(self.events, { tick = game.tick, kind = kind, data = data })
  while #self.events > EVENT_CAP do table.remove(self.events, 1) end
end

-- forward declarations for helpers defined further down but referenced
-- inside on_tick driver functions (drive_place_seq etc).
local describe_blockers
local suggest_from_blockers

local function clear_intent(self)
  self.intent    = { kind = "idle" }
  self.path      = nil
  if self.path_request then
    storage.path_requests[self.path_request] = nil
    self.path_request = nil
  end
  self.path_goal   = nil
  self.mine_target = nil
  if ent_of(self) then
    self.entity.walking_state  = { walking = false, direction = defines.direction.north }
    self.entity.mining_state   = { mining = false }
    self.entity.shooting_state = { state = defines.shooting.not_shooting, position = {0,0} }
  end
end

-- ============================================================================
-- direction math (0..15, 0=north, clockwise)
-- ============================================================================
local function dir_to(from, to)
  local dx, dy = to.x - from.x, to.y - from.y
  if math.abs(dx) < 0.15 and math.abs(dy) < 0.15 then return nil end
  local angle = math.atan2(dx, -dy)
  if angle < 0 then angle = angle + 2 * math.pi end
  return math.floor(angle / (2 * math.pi) * 16 + 0.5) % 16
end

local _CARDINAL = {
  north = defines.direction.north,
  east  = defines.direction.east,
  south = defines.direction.south,
  west  = defines.direction.west,
}

-- ============================================================================
-- perception helpers (no global state)
-- ============================================================================
local function inv_contents(entity)
  if not (entity and entity.valid) then return {} end
  local inv = entity.get_main_inventory()
  if not inv then return {} end
  local out = {}
  for _, st in pairs(inv.get_contents()) do
    table.insert(out, { name = st.name, count = st.count, quality = st.quality })
  end
  return out
end

local function ammo_armor_guns(entity)
  if not (entity and entity.valid) then return {} end
  local function dump(inv_id)
    local inv = entity.get_inventory(inv_id); if not inv then return nil end
    local out = {}
    for _, st in pairs(inv.get_contents()) do
      table.insert(out, { name = st.name, count = st.count, quality = st.quality })
    end
    return out
  end
  return {
    armor = dump(defines.inventory.character_armor),
    guns  = dump(defines.inventory.character_guns),
    ammo  = dump(defines.inventory.character_ammo),
    trash = dump(defines.inventory.character_trash),
  }
end

-- 16-direction enum (2.0): cardinals at 0/4/8/12, diagonals 2/6/10/14.
local DIR_NAME = {
  [0]="N",  [1]="NNE",[2]="NE", [3]="ENE",
  [4]="E",  [5]="ESE",[6]="SE", [7]="SSE",
  [8]="S",  [9]="SSW",[10]="SW",[11]="WSW",
  [12]="W", [13]="WNW",[14]="NW",[15]="NNW",
}

local function r1(v) return math.floor(v * 10 + 0.5) / 10 end

local function summarize_entity(e)
  -- Compact summary. Position rounded to 0.1 tile. `mineable` dropped
  -- (LLM can infer from type/name). `type` dropped when equal to `name`'s
  -- group key (already provided by grouping).
  local t = { name = e.name, type = e.type, position = { x = r1(e.position.x), y = r1(e.position.y) } }
  if e.type == "resource" then t.amount = e.amount end
  if e.health and e.type ~= "resource" and e.health < (e.max_health or 1e9) then
    t.health = math.floor(e.health)
  end
  if e.unit_number then t.unit_number = e.unit_number end

  -- Direction-aware perception. The agent needs this to reason about inserter
  -- arms and belt flow without having to guess from tile-level pictures.
  local etype = e.type
  if etype == "inserter" then
    -- `direction` is the side the inserter's ARM REACHES TO GRAB from
    -- (the pickup side). The drop is the OPPOSITE side. Verified empirically:
    -- direction=south + position=(-17.5,-118.5) -> pickup y=-117.5 (south),
    -- drop y=-119.7 (north). pickup_position/drop_position are world coords
    -- so the agent can read them directly without computing offsets.
    t.facing = DIR_NAME[e.direction] or e.direction
    local pp = e.pickup_position; if pp then t.pickup = { x = r1(pp.x), y = r1(pp.y) } end
    local dp = e.drop_position;   if dp then t.drop   = { x = r1(dp.x), y = r1(dp.y) } end
    local held = e.held_stack
    if held and held.valid_for_read then
      t.holding = { name = held.name, count = held.count }
    end
  elseif etype == "transport-belt" then
    -- `direction` is the direction items MOVE (the belt's output side).
    t.flow = DIR_NAME[e.direction] or e.direction
    local lanes = {}
    local n = e.get_max_transport_line_index and e.get_max_transport_line_index() or 0
    for i = 1, n do
      local line = e.get_transport_line(i)
      if line and #line > 0 then
        lanes[i] = { count = #line, item = line[1] and line[1].name or nil }
      end
    end
    if next(lanes) then t.lanes = lanes end
  elseif etype == "underground-belt" then
    t.flow = DIR_NAME[e.direction] or e.direction
    t.ug_type = e.belt_to_ground_type  -- "input" (goes underground) / "output"
    local nb = e.neighbours
    if nb and nb.valid then t.ug_pair = { x = r1(nb.position.x), y = r1(nb.position.y) } end
  elseif etype == "splitter" or etype == "loader" or etype == "loader-1x1"
      or etype == "pipe-to-ground" or etype == "assembling-machine"
      or etype == "furnace" or etype == "mining-drill" or etype == "pump"
      or etype == "offshore-pump" or etype == "boiler" or etype == "lab"
      or etype == "wall" or etype == "gate" then
    if e.supports_direction then
      t.facing = DIR_NAME[e.direction] or e.direction
    end
  end
  if etype == "assembling-machine" or etype == "furnace" then
    local rec = e.get_recipe and e.get_recipe()
    if rec then t.recipe = rec.name end
  end
  return t
end

local function nearby_summary(pos, radius, surface)
  local entities = surface.find_entities_filtered{ position = pos, radius = radius }
  local groups, enemy_count = {}, 0
  -- Resources and trees come as dense tile-grids; aggregate by name instead
  -- of listing every tile (cuts payload by ~10x near patches/forests).
  local agg = {}  -- key "type|name" -> {type, name, count, total_amount, nearest, nearest_d2}
  for _, e in ipairs(entities) do
    if e.valid then
      local etype = e.type
      if etype == "resource" or etype == "tree" or etype == "simple-entity" then
        local key = etype .. "|" .. e.name
        local a = agg[key]
        local d2 = (e.position.x - pos.x)^2 + (e.position.y - pos.y)^2
        if not a then
          a = { type = etype, name = e.name, count = 0, total_amount = 0,
                nearest = { x = r1(e.position.x), y = r1(e.position.y) },
                nearest_d2 = d2 }
          agg[key] = a
        end
        a.count = a.count + 1
        if etype == "resource" then a.total_amount = a.total_amount + (e.amount or 0) end
        if d2 < a.nearest_d2 then
          a.nearest_d2 = d2
          a.nearest = { x = r1(e.position.x), y = r1(e.position.y) }
        end
        if e.force and e.force.name == "enemy" then enemy_count = enemy_count + 1 end
      else
        local g = etype
        groups[g] = groups[g] or {}
        table.insert(groups[g], summarize_entity(e))
        if e.force and e.force.name == "enemy" then enemy_count = enemy_count + 1 end
      end
    end
  end
  -- Emit aggregated buckets as compact rows.
  for _, a in pairs(agg) do
    groups[a.type] = groups[a.type] or {}
    local row = { name = a.name, count = a.count, nearest = a.nearest }
    if a.total_amount > 0 then row.total_amount = a.total_amount end
    table.insert(groups[a.type], row)
  end
  for k, list in pairs(groups) do
    if #list > 10 then
      groups[k] = { __truncated_from = #list, sample = {} }
      for i = 1, 10 do groups[k].sample[i] = list[i] end
    end
  end
  return groups, enemy_count
end

-- ============================================================================
-- spawn / despawn / list
-- ============================================================================
local function fn_spawn(name, opts)
  if not name or type(name) ~= "string" or name == "" then
    return err_resp("spawn requires a non-empty npc_name")
  end
  ensure_storage()
  opts = opts or {}
  local surface_name = opts.surface or storage.surface_name or DEFAULT_SURFACE
  local surface = game.surfaces[surface_name]
  if not surface then return err_resp("surface not found: " .. surface_name) end

  local self = storage.npcs[name]
  if self and ent_of(self) then
    local e = self.entity
    return ok_resp({
      message = "already spawned", name = name,
      position = { x = e.position.x, y = e.position.y }, surface = e.surface.name,
    })
  end

  local pos
  if opts.x ~= nil and opts.y ~= nil then
    pos = { x = opts.x, y = opts.y }
  else
    -- offset each subsequent NPC east of spawn so they don't stack
    local sp = game.forces.player.get_spawn_position(surface)
    local n_existing = 0
    for _, st in pairs(storage.npcs) do if ent_of(st) then n_existing = n_existing + 1 end end
    pos = { x = sp.x + (opts.dx or (n_existing * 3.0)), y = sp.y + (opts.dy or 0.0) }
  end

  local safe = surface.find_non_colliding_position("character", pos, 16, 0.5)
  if not safe then return err_resp("no free space near requested position", { requested = pos }) end

  local ent = surface.create_entity{ name = "character", position = safe, force = "player" }
  if not ent then return err_resp("create_entity returned nil") end

  storage.npcs[name] = storage.npcs[name] or fresh_npc_state()
  self = storage.npcs[name]
  self.entity = ent
  clear_intent(self)
  push_event(self, "spawn", { position = { x = ent.position.x, y = ent.position.y } })
  game.print("[npc_mcp] " .. name .. " spawned at (" ..
             math.floor(ent.position.x) .. ", " .. math.floor(ent.position.y) .. ")")
  return ok_resp({
    message = "spawned", name = name,
    position = { x = ent.position.x, y = ent.position.y }, surface = ent.surface.name,
  })
end

local function fn_despawn(name)
  local self, err = get_npc(name); if err then return err_resp(err) end
  if ent_of(self) then self.entity.destroy() end
  storage.npcs[name] = nil
  return ok_resp({ message = "despawned", name = name })
end

local function fn_list()
  ensure_storage()
  local out = {}
  for name, self in pairs(storage.npcs) do
    local e = ent_of(self)
    table.insert(out, {
      name     = name,
      alive    = e ~= nil,
      position = e and { x = e.position.x, y = e.position.y } or nil,
      intent   = (self.intent and self.intent.kind) or "idle",
    })
  end
  return ok_resp({ npcs = out })
end

-- ============================================================================
-- lifecycle hooks
-- ============================================================================
script.on_init(function()
  ensure_storage()
  -- Spawn a default "Botty" so a single-agent session works with no setup.
  fn_spawn("Botty", {})
end)

script.on_load(function() end)

script.on_configuration_changed(function()
  ensure_storage()
end)

-- ============================================================================
-- drive_* — each takes self; on_tick iterates over all NPCs
-- ============================================================================
local function drive_walk_continuous(self)
  local i = self.intent
  if i.kind ~= "walk" then return end
  self.entity.walking_state = { walking = true, direction = i.direction or 0 }
end

local function drive_walk_to(self)
  local i = self.intent
  if i.kind ~= "walk_to" then return end
  local p = self.path
  if not p then return end -- still waiting for async path
  if p.i > #p.waypoints then
    clear_intent(self)
    push_event(self, "arrived", { position = { x = self.entity.position.x, y = self.entity.position.y } })
    return
  end
  local target = p.waypoints[p.i]
  local cur = self.entity.position
  local d = dir_to(cur, target.position)
  if not d then p.i = p.i + 1; return end
  self.entity.walking_state = { walking = true, direction = d }
end

local function drive_walk_toward(self)
  local i = self.intent
  if i.kind ~= "walk_toward" then return end
  local cur = self.entity.position
  local goal = i.goal
  local dx, dy = goal.x - cur.x, goal.y - cur.y
  local dist = math.sqrt(dx*dx + dy*dy)
  if dist <= (i.arrive_radius or 1.5) then
    self.entity.walking_state = { walking = false, direction = 0 }
    clear_intent(self)
    push_event(self, "arrived", { position = { x = cur.x, y = cur.y }, mode = "greedy" })
    return
  end
  if i.last_pos then
    local moved = math.sqrt((cur.x - i.last_pos.x)^2 + (cur.y - i.last_pos.y)^2)
    if moved < 0.05 then
      i.stall = (i.stall or 0) + 1
      if i.stall >= (i.stall_limit or 60) then
        self.entity.walking_state = { walking = false, direction = 0 }
        clear_intent(self)
        push_event(self, "walk_stuck", { position = { x = cur.x, y = cur.y }, goal = goal })
        return
      end
    else
      i.stall = 0
    end
  end
  i.last_pos = { x = cur.x, y = cur.y }
  local d = dir_to(cur, goal)
  if d then self.entity.walking_state = { walking = true, direction = d } end
end

-- Auto-walking placement queue. Each tick we try to advance up to
-- PLACE_PER_TICK ops: if the current op is in build reach we place it and
-- advance; otherwise we set a walking_state toward it and bail until next
-- tick. Stall detection mirrors drive_walk_toward.
local PLACE_PER_TICK = 6
local function drive_place_seq(self)
  local i = self.intent
  if not (i and i.kind == "place_seq") then return end
  local e = self.entity
  for _ = 1, PLACE_PER_TICK do
    if i.cur > #i.ops then
      e.walking_state = { walking = false, direction = defines.direction.north }
      push_event(self, "place_seq_done", { count = #i.ops })
      clear_intent(self)
      return
    end
    local op = i.ops[i.cur]
    local cur = e.position
    local dist = math.sqrt((cur.x - op.pos.x) ^ 2 + (cur.y - op.pos.y) ^ 2)
    local reach = (e.prototype.build_distance or 10) - 0.5
    if dist > reach then
      local d = dir_to(cur, op.pos)
      if d then e.walking_state = { walking = true, direction = d } end
      -- stall detection per-op
      i.stall = i.stall or { x = cur.x, y = cur.y, tick = game.tick }
      if game.tick - i.stall.tick > 180 then
        local moved = math.sqrt((cur.x - i.stall.x) ^ 2 + (cur.y - i.stall.y) ^ 2)
        if moved < 0.5 then
          push_event(self, "place_failed", {
            code = "walk_stuck", target = op.pos, item = op.item, seq = i.cur,
          })
          i.cur = i.cur + 1
          i.stall = nil
          return  -- give up the rest of this tick; try next op next tick
        end
        i.stall = { x = cur.x, y = cur.y, tick = game.tick }
      end
      return
    end
    -- in reach: attempt the placement
    e.walking_state = { walking = false, direction = defines.direction.north }
    i.stall = nil
    local inv = e.get_main_inventory()
    local have = inv and inv.get_item_count(op.item) or 0
    if have < 1 then
      push_event(self, "place_failed", {
        code = "missing_item", item = op.item, target = op.pos, seq = i.cur,
      })
      i.cur = i.cur + 1
    elseif not e.surface.can_place_entity{
        name = op.target_name, position = op.pos, direction = op.dir, force = e.force,
      } then
      local blockers = describe_blockers(e.surface, op.pos)
      push_event(self, "place_failed", {
        code = "tile_blocked", target = op.pos, item = op.item, seq = i.cur,
        blockers = blockers, suggestion = suggest_from_blockers(blockers, op.item),
      })
      i.cur = i.cur + 1
    else
      local placed = e.surface.create_entity{
        name = op.target_name, position = op.pos, direction = op.dir,
        force = e.force, raise_built = true,
      }
      if placed then
        inv.remove({ name = op.item, count = 1 })
        push_event(self, "placed", { name = placed.name, position = op.pos, seq = i.cur })
      else
        push_event(self, "place_failed", {
          code = "engine_refused", target = op.pos, item = op.item, seq = i.cur,
        })
      end
      i.cur = i.cur + 1
    end
  end
end

local function drive_mining(self)
  local i = self.intent
  if i.kind ~= "mine" then return end
  if not i.position then clear_intent(self); return end
  local cur = self.entity.position
  local dist = math.sqrt((cur.x - i.position.x)^2 + (cur.y - i.position.y)^2)
  local reach = self.entity.prototype.reach_resource_distance or 2.7
  if dist > reach then
    local d = dir_to(cur, i.position)
    if d then self.entity.walking_state = { walking = true, direction = d } end
    return
  end
  self.entity.walking_state = { walking = false, direction = 0 }
  local surface = self.entity.surface
  local ents = surface.find_entities_filtered{ position = i.position, radius = 0.5 }
  local target = nil
  for _, e in ipairs(ents) do
    if e.valid and e.prototype.mineable_properties and e.prototype.mineable_properties.minable then
      target = e; break
    end
  end
  if not target then
    push_event(self, "mined_out", { position = i.position })
    clear_intent(self)
    return
  end
  local mine_props = target.prototype.mineable_properties
  local mine_time  = (mine_props and mine_props.mining_time) or 1.0
  local char_speed = 0.5
  local ticks_per_mine = math.max(1, math.floor(mine_time / char_speed * 60))
  if game.tick - (self.last_mine_tick or 0) >= ticks_per_mine then
    self.last_mine_tick = game.tick
    self.entity.mine_entity(target, true)
  end
end

local function drive_crafting(self)
  local q = self.craft_queue
  if not q or #q == 0 then return end
  local head = q[1]
  if not head.started then
    local recipe = prototypes.recipe[head.recipe]
    if not recipe then
      table.remove(q, 1)
      push_event(self, "craft_failed", { recipe = head.recipe, reason = "unknown recipe" })
      return
    end
    local inv = self.entity.get_main_inventory()
    for _, ing in ipairs(recipe.ingredients) do
      if ing.type == "item" then
        if inv.get_item_count(ing.name) < ing.amount then
          table.remove(q, 1)
          push_event(self, "craft_failed", { recipe = head.recipe, reason = "missing " .. ing.name })
          return
        end
      end
    end
    for _, ing in ipairs(recipe.ingredients) do
      if ing.type == "item" then inv.remove({ name = ing.name, count = ing.amount }) end
    end
    head.started   = true
    head.time_left = math.max(1, math.ceil(recipe.energy * 60))
  end
  head.time_left = head.time_left - 1
  if head.time_left <= 0 then
    local recipe = prototypes.recipe[head.recipe]
    local inv = self.entity.get_main_inventory()
    for _, prod in ipairs(recipe.products) do
      if prod.type == "item" then
        local amt = prod.amount or ((prod.amount_min or 1) + (prod.amount_max or 1)) / 2
        inv.insert({ name = prod.name, count = math.floor(amt) })
      end
    end
    head.count = head.count - 1
    push_event(self, "craft_done", { recipe = head.recipe, remaining = head.count })
    if head.count <= 0 then table.remove(q, 1) else head.started = false end
  end
end

-- combat: auto-engage nearest enemy within configured range. Works whether the
-- NPC is on foot (sets character.shooting_state) or driving a vehicle with
-- guns (sets vehicle.shooting_state). When HP drops below retreat threshold
-- on foot, stops firing and emits a "combat_retreat" event once so the LLM
-- can react; combat re-arms when HP recovers above the threshold.
local function drive_combat(self)
  if not self.combat then
    self.combat = { enabled = false, range = 20, retreat_hp_pct = 30, target_un = nil, retreated = false }
  end
  local c = self.combat
  if not (c and c.enabled) then return end
  local e = self.entity
  local vehicle = e.vehicle
  local shooter = vehicle or e
  if not (shooter and shooter.valid) then return end

  -- Retreat gate (character only; vehicles have their own HP UX).
  if not vehicle then
    local max_hp = e.max_health or 250
    local hp_pct = (e.health or 0) / max_hp * 100
    if hp_pct < (c.retreat_hp_pct or 30) then
      if not c.retreated then
        c.retreated = true
        push_event(self, "combat_retreat", { hp_pct = hp_pct, threshold = c.retreat_hp_pct })
      end
      e.shooting_state = { state = defines.shooting.not_shooting, position = { 0, 0 } }
      c.target_un = nil
      return
    elseif c.retreated and hp_pct > (c.retreat_hp_pct or 30) + 10 then
      c.retreated = false
      push_event(self, "combat_rearmed", { hp_pct = hp_pct })
    end
  end

  local range = c.range or 20
  local target = e.surface.find_nearest_enemy{
    position = e.position, max_distance = range, force = e.force,
  }
  if not (target and target.valid) then
    if c.target_un then
      push_event(self, "combat_target_lost", { unit_number = c.target_un })
      c.target_un = nil
    end
    shooter.shooting_state = { state = defines.shooting.not_shooting, position = { 0, 0 } }
    return
  end

  if c.target_un ~= target.unit_number then
    c.target_un = target.unit_number
    push_event(self, "combat_engage", {
      unit_number = target.unit_number, name = target.name,
      position = { x = target.position.x, y = target.position.y },
    })
  end
  shooter.shooting_state = {
    state    = defines.shooting.shooting_enemies,
    position = { x = target.position.x, y = target.position.y },
  }
end

-- vehicle driving: steers entity.vehicle toward self.drive_goal. Spidertrons
-- use the engine autopilot (set once at fn_drive_to time, just monitor); cars
-- and tanks get a naive heading-toward-goal controller with a brake zone.
local function drive_vehicle(self)
  local g = self.drive_goal
  if not g then return end
  local e = self.entity
  local v = e.vehicle
  if not (v and v.valid) then
    push_event(self, "drive_aborted", { reason = "not in a vehicle", goal = g })
    self.drive_goal = nil
    return
  end

  local cur  = v.position
  local dx, dy = g.x - cur.x, g.y - cur.y
  local dist = math.sqrt(dx*dx + dy*dy)
  if dist <= (g.arrive_radius or 4.0) then
    if v.type ~= "spider-vehicle" then
      v.riding_state = { acceleration = defines.riding.acceleration.braking, direction = defines.riding.direction.straight }
    end
    push_event(self, "drive_arrived", { goal = g, vehicle = v.name, position = { x = cur.x, y = cur.y } })
    self.drive_goal = nil
    return
  end

  if v.type == "spider-vehicle" then
    -- Autopilot was set in fn_drive_to; nothing to do per-tick beyond monitoring.
    return
  end

  -- Car/tank: compute desired heading [0, 2pi) where 0 = north, increases clockwise.
  local want = math.atan2(dx, -dy)
  if want < 0 then want = want + 2 * math.pi end
  local have = v.orientation * 2 * math.pi  -- LuaEntity.orientation is 0..1
  local diff = want - have
  while diff >  math.pi do diff = diff - 2 * math.pi end
  while diff < -math.pi do diff = diff + 2 * math.pi end

  local dir
  if diff >  0.18 then dir = defines.riding.direction.right
  elseif diff < -0.18 then dir = defines.riding.direction.left
  else dir = defines.riding.direction.straight end

  -- Slow down when close OR when steering hard, otherwise accelerate.
  local accel
  if dist < 10 or math.abs(diff) > 1.2 then
    accel = defines.riding.acceleration.nothing
  else
    accel = defines.riding.acceleration.accelerating
  end
  v.riding_state = { acceleration = accel, direction = dir }

  -- Stall detection: if vehicle hasn't moved much in ~3s, abort.
  g._last_pos = g._last_pos or { x = cur.x, y = cur.y, tick = game.tick }
  if game.tick - g._last_pos.tick > 180 then
    local moved = math.sqrt((cur.x - g._last_pos.x)^2 + (cur.y - g._last_pos.y)^2)
    if moved < 2.0 then
      v.riding_state = { acceleration = defines.riding.acceleration.braking, direction = defines.riding.direction.straight }
      push_event(self, "drive_stuck", { goal = g, position = { x = cur.x, y = cur.y } })
      self.drive_goal = nil
      return
    end
    g._last_pos = { x = cur.x, y = cur.y, tick = game.tick }
  end
end

script.on_event(defines.events.on_tick, function(_)
  if not storage.npcs then return end
  local drivers = {
    "drive_walk_continuous", "drive_walk_to", "drive_walk_toward",
    "drive_place_seq", "drive_mining", "drive_crafting",
    "drive_combat", "drive_vehicle",
  }
  local fns = {
    drive_walk_continuous, drive_walk_to, drive_walk_toward,
    drive_place_seq, drive_mining, drive_crafting,
    drive_combat, drive_vehicle,
  }
  for _, self in pairs(storage.npcs) do
    if not ent_of(self) then
      if self.entity ~= nil then
        self.entity = nil
        clear_intent(self)
        push_event(self, "died", {})
      end
    else
      for idx, fn in ipairs(fns) do
        local ok, err = pcall(fn, self)
        if not ok then
          -- Capture the failure as an event, clear the bot's intent so the
          -- driver doesn't re-fault next tick, and KEEP THE GAME RUNNING.
          -- Without this pcall any Lua error in a driver kills the whole
          -- multiplayer scenario (state Failed) and silently hangs RCON.
          push_event(self, "driver_crashed", {
            driver = drivers[idx], error = tostring(err),
            intent_kind = (self.intent and self.intent.kind) or "idle",
          })
          clear_intent(self)
          if self.entity and self.entity.valid then
            self.entity.walking_state = { walking = false, direction = 0 }
          end
          log("[npc_mcp] driver " .. drivers[idx] .. " crashed: " .. tostring(err))
          break  -- skip remaining drivers this tick for this NPC
        end
      end
    end
  end
end)

-- Periodic auto-snapshot: every 10 minutes (36000 ticks at 60 UPS), save
-- the world under a rotating 6-slot name so the last ~hour of progress is
-- always recoverable from .factorio-server/saves/auto-10min-N.zip.
-- This runs server-side; agents do not need to call npc_save themselves.
script.on_nth_tick(36000, function(_)
  storage.auto_save_idx = ((storage.auto_save_idx or 0) % 6) + 1
  local name = "auto-10min-" .. storage.auto_save_idx
  game.server_save(name)
  game.print("[npc_mcp] auto-snapshot saved as " .. name)
end)

script.on_event(defines.events.on_script_path_request_finished, function(e)
  if not storage.path_requests then return end
  local name = storage.path_requests[e.id]
  if not name then return end
  storage.path_requests[e.id] = nil
  local self = storage.npcs[name]
  if not self then return end
  self.path_request = nil
  local goal = self.path_goal
  local start = ent_of(self) and self.entity.position or nil
  if e.try_again_later then
    push_event(self, "path_busy", { goal = goal, start = start })
    clear_intent(self); return
  end
  if not e.path then
    push_event(self, "path_failed", { goal = goal, start = start,
      hint = "pathfinder returned no path; try a nearer waypoint or use walk_toward (greedy)" })
    clear_intent(self); return
  end
  self.path = { waypoints = e.path, i = 1 }
  push_event(self, "path_ready", { goal = goal, waypoints = #e.path })
end)

-- Research is force-wide; fan out to every NPC's event queue.
script.on_event(defines.events.on_research_finished, function(e)
  if not storage.npcs then return end
  for _, self in pairs(storage.npcs) do
    push_event(self, "research_finished", { name = e.research.name })
  end
end)

script.on_event(defines.events.on_chunk_charted, function(e)
  if not (e.force and e.force.name == "player") then return end
  if not storage.npcs then return end
  for _, self in pairs(storage.npcs) do
    push_event(self, "chunk_charted", { position = e.position })
  end
end)

-- ============================================================================
-- macro: look up NPC and ensure entity is alive
-- ============================================================================
local function require_npc(name)
  local self, err = get_npc(name); if err then return nil, err_resp(err) end
  if not ent_of(self) then return nil, err_resp("npc '" .. name .. "' is not spawned (or has died)") end
  return self, nil
end

-- ============================================================================
-- remote-interface functions — first argument is always npc_name
-- ============================================================================
local function fn_status(name)
  local self, err = get_npc(name); if err then return err_resp(err) end
  if not ent_of(self) then return ok_resp({ exists = false, name = name }) end
  local e = self.entity
  return ok_resp({
    exists   = true, name = name,
    position = { x = e.position.x, y = e.position.y },
    surface  = e.surface.name, health = e.health, intent = self.intent,
    walking  = e.walking_state and e.walking_state.walking or false,
    mining   = e.mining_state and e.mining_state.mining or false,
    tick     = game.tick,
  })
end

local function fn_observe(name, radius)
  local self, err = get_npc(name); if err then return err_resp(err) end
  radius = math.max(1, math.min(tonumber(radius) or 16, 24))  -- cap to 24
  if not ent_of(self) then return ok_resp({ exists = false, name = name }) end
  local e = self.entity
  local groups, enemy_count = nearby_summary(e.position, radius, e.surface)
  return ok_resp({
    exists      = true, name = name,
    position    = { x = r1(e.position.x), y = r1(e.position.y) },
    surface     = e.surface.name, health = e.health, intent = self.intent,
    inventory   = inv_contents(e), equipment = ammo_armor_guns(e),
    nearby      = groups, enemy_count = enemy_count,
    daytime     = e.surface.daytime, tick = game.tick,
  })
end

local function fn_look(name, radius)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  radius = math.max(1, math.min(tonumber(radius) or 16, 24))
  local e = self.entity
  local groups, enemy_count = nearby_summary(e.position, radius, e.surface)
  return ok_resp({ position = { x = r1(e.position.x), y = r1(e.position.y) },
                   nearby = groups, enemy_count = enemy_count })
end

local function fn_look_at(name, x, y, radius)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  -- Tighter cap than look/observe: look_at is for inspecting a specific tile,
  -- not surveying — large radii bloat the payload with no benefit.
  radius = math.max(1, math.min(tonumber(radius) or 4, 8))
  local groups, enemy_count = nearby_summary({x=x,y=y}, radius, self.entity.surface)
  return ok_resp({ anchor = {x=x,y=y}, radius = radius, nearby = groups, enemy_count = enemy_count })
end

local function fn_inventory(name)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  return ok_resp({ main = inv_contents(self.entity), equipment = ammo_armor_guns(self.entity) })
end

local function fn_walk(name, direction)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  local d
  if type(direction) == "string" then d = _CARDINAL[direction]
  elseif type(direction) == "number" then d = math.floor(direction) % 16 end
  if d == nil then return err_resp("direction must be north|east|south|west or 0..15") end
  clear_intent(self)
  self.intent = { kind = "walk", direction = d }
  return ok_resp({ direction = d })
end

local function fn_walk_to(name, x, y)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  x, y = tonumber(x), tonumber(y)
  if not (x and y) then return err_resp("walk_to requires numeric x,y") end
  local e = self.entity
  clear_intent(self)
  self.intent = { kind = "walk_to", goal = { x = x, y = y } }
  local proto = prototypes.entity["character"]
  local req_id = e.surface.request_path{
    bounding_box   = proto.collision_box,
    collision_mask = proto.collision_mask,
    start          = e.position,
    goal           = { x = x, y = y },
    force          = e.force,
    radius         = 2.0,
    can_open_gates = true,
    path_resolution_modifier = 0,
    pathfind_flags = { cache = false, allow_destroy_friendly_entities = false,
                       allow_paths_through_own_entities = true, low_priority = false },
  }
  self.path_request = req_id
  self.path_goal    = { x = x, y = y }
  storage.path_requests[req_id] = name
  return ok_resp({ message = "pathfind requested", request_id = req_id, goal = { x = x, y = y } })
end

local function fn_walk_toward(name, x, y, arrive_radius, stall_limit)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  x, y = tonumber(x), tonumber(y)
  if not (x and y) then return err_resp("walk_toward requires numeric x,y") end
  clear_intent(self)
  self.intent = {
    kind = "walk_toward", goal = { x = x, y = y },
    arrive_radius = tonumber(arrive_radius) or 1.5,
    stall_limit   = tonumber(stall_limit) or 60,
  }
  return ok_resp({ message = "greedy walking", goal = { x = x, y = y } })
end

local function fn_stop(name)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  clear_intent(self)
  return ok_resp({ message = "stopped" })
end

local function fn_mine_at(name, x, y)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  x, y = tonumber(x), tonumber(y)
  if not (x and y) then return err_resp("mine_at requires numeric x,y") end
  clear_intent(self)
  self.intent = { kind = "mine", position = { x = x, y = y } }
  return ok_resp({ target = { x = x, y = y } })
end

local function fn_give(name, item, count, quality)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  count = tonumber(count) or 1
  if not prototypes.item[item] then return err_resp("unknown item: " .. tostring(item)) end
  local inv = self.entity.get_main_inventory()
  if not inv then return err_resp("no main inventory") end
  local stack = { name = item, count = count }
  if quality and prototypes.quality and prototypes.quality[quality] then stack.quality = quality end
  local inserted = inv.insert(stack)
  return ok_resp({ inserted = inserted, requested = count })
end

local function fn_say(name, text)
  if not text then return err_resp("say requires text") end
  game.print("[" .. tostring(name or "?") .. "] " .. tostring(text))
  return ok_resp({})
end

local function fn_rename(name, new_name)
  local self, err = get_npc(name); if err then return err_resp(err) end
  if not new_name or new_name == "" then return err_resp("rename requires new_name") end
  if storage.npcs[new_name] then return err_resp("name already taken: " .. new_name) end
  storage.npcs[new_name] = self
  storage.npcs[name] = nil
  if self.path_request then storage.path_requests[self.path_request] = new_name end
  return ok_resp({ old_name = name, new_name = new_name })
end

-- crafting ---------------------------------------------------------------------
local function fn_craft(name, recipe_name, count)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  count = tonumber(count) or 1
  local recipe = prototypes.recipe[recipe_name]
  if not recipe then return err_resp("unknown recipe: " .. tostring(recipe_name)) end
  if not self.entity.force.recipes[recipe_name].enabled then
    return err_resp("recipe not researched: " .. recipe_name)
  end
  table.insert(self.craft_queue, {
    recipe = recipe_name, count = count, started = false, time_left = 0,
  })
  return ok_resp({ queued = count, recipe = recipe_name, position_in_queue = #self.craft_queue })
end

local function fn_craft_status(name)
  local self, err = get_npc(name); if err then return err_resp(err) end
  local out = {}
  for _, entry in ipairs(self.craft_queue or {}) do
    table.insert(out, {
      recipe = entry.recipe, remaining = entry.count,
      started = entry.started, time_left = entry.time_left,
    })
  end
  return ok_resp({ queue = out })
end

local function fn_cancel_craft(name, index)
  local self, err = get_npc(name); if err then return err_resp(err) end
  index = tonumber(index) or 1
  local q = self.craft_queue
  if not q[index] then return err_resp("no craft entry at index " .. index) end
  table.remove(q, index)
  return ok_resp({ cancelled_index = index })
end

-- building / placement --------------------------------------------------------

-- Inspect a tile and report what's blocking placement, so the LLM can
-- decide whether to mine a rock, pick up its own misplaced entity, etc.
-- (forward-declared near top of file)
function describe_blockers(surface, pos, radius)
  local found = surface.find_entities_filtered{ position = pos, radius = radius or 0.45 }
  local out = {}
  for _, ent in ipairs(found) do
    if ent.valid then
      table.insert(out, {
        name = ent.name, type = ent.type,
        position = { x = ent.position.x, y = ent.position.y },
        minable  = (ent.prototype.mineable_properties and ent.prototype.mineable_properties.minable) or false,
      })
    end
  end
  -- water/cliff/void: tiles, not entities
  local tile = surface.get_tile(math.floor(pos.x), math.floor(pos.y))
  if tile and tile.valid then
    local n = tile.name
    if n:find("water") or n == "out-of-map" or n:find("void") then
      table.insert(out, { tile = n, position = { x = math.floor(pos.x), y = math.floor(pos.y) } })
    end
  end
  return out
end

-- Returns a short, machine-readable suggestion derived from a blocker list.
-- (forward-declared near top of file)
function suggest_from_blockers(blockers, item)
  for _, b in ipairs(blockers or {}) do
    if b.tile then
      return "tile_terrain: " .. b.tile .. " — pick a different position"
    end
    if b.minable then
      return "mine " .. b.name .. " first (npc_mine_at)"
    end
    if b.name then
      return "pickup or pickup-then-replace existing " .. b.name .. " (npc_pickup)"
    end
  end
  return nil
end

local function fn_place(name, item, x, y, direction)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  x, y = tonumber(x), tonumber(y)
  if not (x and y) then return err_resp("place requires numeric x,y", { code = "bad_args" }) end
  local item_proto = prototypes.item[item]
  if not item_proto then return err_resp("unknown item: " .. tostring(item), { code = "unknown_item", item = item }) end
  local place_result = item_proto.place_result
  if not place_result then
    return err_resp(item .. " has no place_result (not a placeable item)",
      { code = "not_placeable", item = item })
  end
  local e = self.entity
  local inv = e.get_main_inventory()
  local have = inv and inv.get_item_count(item) or 0
  if have < 1 then
    return err_resp("missing item in inventory: " .. item,
      { code = "missing_item", item = item, needed = 1, have = have })
  end
  local dir = tonumber(direction) or defines.direction.north
  local pos = { x = x, y = y }
  local target_name = place_result.name

  local reach = (e.prototype.build_distance or 10) - 0.5
  local dist  = math.sqrt((e.position.x - x) ^ 2 + (e.position.y - y) ^ 2)

  -- Fast path: in reach and not already executing a queue → place synchronously
  -- so callers see the result on the same RCON round-trip.
  if dist <= reach and (not self.intent or self.intent.kind == "idle") then
    if not e.surface.can_place_entity{ name = target_name, position = pos, direction = dir, force = e.force } then
      local blockers = describe_blockers(e.surface, pos)
      return err_resp("tile blocked", {
        code     = "tile_blocked",
        target   = pos,
        entity   = target_name,
        blockers = blockers,
        suggestion = suggest_from_blockers(blockers, item),
      })
    end
    local placed = e.surface.create_entity{
      name = target_name, position = pos, direction = dir, force = e.force, raise_built = true,
    }
    if not placed then
      return err_resp("engine refused placement",
        { code = "engine_refused", target = pos, entity = target_name })
    end
    inv.remove({ name = item, count = 1 })
    push_event(self, "placed", { name = placed.name, position = pos })
    return ok_resp({ placed = placed.name, position = pos, direction = dir, async = false })
  end

  -- Slow path: queue an async place-seq with one op. The on_tick driver will
  -- walk into reach, then place; the result is delivered via events
  -- (`placed` / `place_failed` / `place_seq_done`). Pull with npc_turn.
  clear_intent(self)
  self.intent = {
    kind = "place_seq",
    ops  = { { item = item, pos = pos, dir = dir, target_name = target_name } },
    cur  = 1,
  }
  return ok_resp({
    async    = true,
    queued   = 1,
    target   = pos,
    direction = dir,
    entity   = target_name,
    distance = dist,
    reach    = reach,
    hint     = "out of reach; auto-walking to placement. Watch events for `placed`/`place_failed`/`place_seq_done`.",
  })
end

-- Sign helper for axis derivation.
local function _sign(v) if v > 0 then return 1 elseif v < 0 then return -1 else return 0 end end

-- Place a straight axis-aligned line of belts (or any 1x1 directional
-- entity item) from `from` to `to` inclusive. Direction is derived from
-- the segment's axis so the agent never has to compute defines.direction
-- values manually. Async via place_seq.
local function fn_belt(name, from, to, item)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  item = item or "transport-belt"
  if not (from and to and from.x and from.y and to.x and to.y) then
    return err_resp("belt requires from={x,y} and to={x,y}", { code = "bad_args" })
  end
  local item_proto = prototypes.item[item]
  if not item_proto or not item_proto.place_result then
    return err_resp("not a placeable item: " .. tostring(item), { code = "not_placeable", item = item })
  end
  local target_name = item_proto.place_result.name
  local fx = math.floor(tonumber(from.x))
  local fy = math.floor(tonumber(from.y))
  local tx = math.floor(tonumber(to.x))
  local ty = math.floor(tonumber(to.y))
  if fx ~= tx and fy ~= ty then
    return err_resp("belt segment must be axis-aligned (dx=0 or dy=0)", {
      code = "not_axis_aligned", from = { x = fx, y = fy }, to = { x = tx, y = ty },
      hint = "call fn_belt twice for an L-corner: first leg, then second leg",
    })
  end
  local dx, dy = _sign(tx - fx), _sign(ty - fy)
  local dir
  if     dx > 0 then dir = defines.direction.east
  elseif dx < 0 then dir = defines.direction.west
  elseif dy > 0 then dir = defines.direction.south
  elseif dy < 0 then dir = defines.direction.north
  else               dir = defines.direction.north  -- single tile
  end
  local ops = {}
  local cx, cy = fx, fy
  while true do
    table.insert(ops, {
      item = item, dir = dir, target_name = target_name,
      pos  = { x = cx + 0.5, y = cy + 0.5 },
    })
    if cx == tx and cy == ty then break end
    cx = cx + dx; cy = cy + dy
    if #ops > 256 then
      return err_resp("belt segment too long (>256 tiles)", { code = "too_long", from = from, to = to })
    end
  end
  local inv = self.entity.get_main_inventory()
  local have = inv and inv.get_item_count(item) or 0
  if have < #ops then
    return err_resp("not enough " .. item .. " in inventory",
      { code = "missing_item", item = item, needed = #ops, have = have })
  end
  clear_intent(self)
  self.intent = { kind = "place_seq", ops = ops, cur = 1 }
  return ok_resp({
    async = true, queued = #ops, item = item,
    from = { x = fx + 0.5, y = fy + 0.5 }, to = { x = tx + 0.5, y = ty + 0.5 },
    direction = dir,
    hint = "watch events: `placed` per tile, `place_seq_done` at the end",
  })
end

-- Place ONE inserter at the tile centered between `pickup` and `drop`, with
-- its direction set so the in-game `pickup_position` lands on the pickup tile
-- and `drop_position` on the drop tile. Eliminates the entire class of
-- "inserter facing the wrong way" cycles.
--
-- For long-handed inserters (`long-handed-inserter`) the pickup tile is 2
-- tiles from base, so pass pickup/drop that are 4 tiles apart on the same
-- axis; the base will end up correctly between them.
local function fn_inserter(name, pickup, drop, variant)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  variant = variant or "inserter"
  if not (pickup and drop and pickup.x and pickup.y and drop.x and drop.y) then
    return err_resp("inserter requires pickup={x,y} and drop={x,y}", { code = "bad_args" })
  end
  local item_proto = prototypes.item[variant]
  if not item_proto or not item_proto.place_result then
    return err_resp("not a placeable inserter item: " .. tostring(variant),
      { code = "not_placeable", item = variant })
  end
  local px, py = tonumber(pickup.x), tonumber(pickup.y)
  local gx, gy = tonumber(drop.x),   tonumber(drop.y)
  -- Base sits at the midpoint, snapped to tile center.
  local bx = math.floor((px + gx) / 2) + 0.5
  local by = math.floor((py + gy) / 2) + 0.5
  -- Inserter `direction` is the PICKUP side. Pick the dominant axis from
  -- base → pickup.
  local vx, vy = px - bx, py - by
  local dir
  if math.abs(vy) >= math.abs(vx) then
    dir = (vy < 0) and defines.direction.north or defines.direction.south
  else
    dir = (vx < 0) and defines.direction.west  or defines.direction.east
  end
  local inv = self.entity.get_main_inventory()
  local have = inv and inv.get_item_count(variant) or 0
  if have < 1 then
    return err_resp("missing inserter in inventory: " .. variant,
      { code = "missing_item", item = variant, needed = 1, have = have })
  end
  clear_intent(self)
  self.intent = {
    kind = "place_seq",
    ops  = { { item = variant, dir = dir, target_name = item_proto.place_result.name,
               pos  = { x = bx, y = by } } },
    cur  = 1,
  }
  return ok_resp({
    async = true, queued = 1, variant = variant,
    base = { x = bx, y = by }, direction = dir,
    pickup = { x = px, y = py }, drop = { x = gx, y = gy },
    hint = "watch events for `placed` to confirm; rotate twice to swap pickup<->drop later if needed",
  })
end


local function fn_pickup(name, x, y)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  x, y = tonumber(x), tonumber(y)
  local e = self.entity
  local ents = e.surface.find_entities_filtered{ position = {x=x,y=y}, radius = 0.6, force = e.force }
  if #ents == 0 then return err_resp("nothing of yours at that point") end
  local target = ents[1]
  local ent_name = target.name
  local mined = e.mine_entity(target, true)
  if not mined then return err_resp("mine_entity refused") end
  push_event(self, "picked_up", { name = ent_name, position = {x=x,y=y} })
  return ok_resp({ name = ent_name })
end

local function fn_rotate(name, x, y, direction)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  local e = self.entity
  local ents = e.surface.find_entities_filtered{ position = {x=x,y=y}, radius = 0.6 }
  if #ents == 0 then return err_resp("no entity at that point") end
  local target = ents[1]
  if not target.supports_direction then return err_resp(target.name .. " is not rotatable") end
  target.direction = tonumber(direction) or 0
  return ok_resp({ name = target.name, direction = target.direction })
end

local function fn_set_recipe(name, x, y, recipe_name)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  local e = self.entity
  local ents = e.surface.find_entities_filtered{ position = {x=x,y=y}, radius = 0.6, type = "assembling-machine" }
  if #ents == 0 then return err_resp("no assembling machine there") end
  local r = prototypes.recipe[recipe_name]
  if not r then return err_resp("unknown recipe: " .. tostring(recipe_name)) end
  ents[1].set_recipe(recipe_name)
  return ok_resp({ machine = ents[1].name, recipe = recipe_name })
end

-- logistics -------------------------------------------------------------------
local function _find_container(surface, pos)
  local ents = surface.find_entities_filtered{ position = pos, radius = 0.6 }
  for _, e in ipairs(ents) do
    if e.valid and (e.get_inventory(defines.inventory.chest)
                  or e.get_inventory(defines.inventory.furnace_source)
                  or e.get_inventory(defines.inventory.assembling_machine_input)
                  or e.get_inventory(defines.inventory.fuel)) then
      return e
    end
  end
  return nil
end

local function fn_insert_into(name, x, y, item, count)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  count = tonumber(count) or 1
  local e = self.entity
  local target = _find_container(e.surface, {x=x,y=y})
  if not target then return err_resp("no container at that point") end
  local inv = e.get_main_inventory()
  local have = inv.get_item_count(item)
  if have < 1 then return err_resp("don't have any " .. item) end
  local to_send = math.min(have, count)
  local inserted = target.insert{ name = item, count = to_send }
  inv.remove{ name = item, count = inserted }
  return ok_resp({ target = target.name, inserted = inserted })
end

local function fn_take_from(name, x, y, item, count)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  count = tonumber(count) or 1
  local e = self.entity
  local target = _find_container(e.surface, {x=x,y=y})
  if not target then return err_resp("no container at that point") end
  local taken, remaining = 0, count
  for _, inv_id in pairs({
    defines.inventory.chest,
    defines.inventory.furnace_result,
    defines.inventory.assembling_machine_output,
  }) do
    local src = target.get_inventory(inv_id)
    if src then
      local available = src.get_item_count(item)
      if available > 0 then
        local n = math.min(available, remaining)
        src.remove{ name = item, count = n }
        local got = e.get_main_inventory().insert{ name = item, count = n }
        taken = taken + got; remaining = remaining - got
        if remaining <= 0 then break end
      end
    end
  end
  return ok_resp({ target = target.name, taken = taken })
end

local function fn_fuel(name, x, y, fuel_item, count)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  fuel_item = fuel_item or "coal"; count = tonumber(count) or 5
  local e = self.entity
  local ents = e.surface.find_entities_filtered{ position = {x=x,y=y}, radius = 0.6 }
  local target
  for _, ent in ipairs(ents) do
    if ent.valid and ent.get_inventory(defines.inventory.fuel) then target = ent; break end
  end
  if not target then return err_resp("no fuel-burning entity at that point") end
  local inv = e.get_main_inventory()
  local have = inv.get_item_count(fuel_item)
  if have < 1 then return err_resp("no " .. fuel_item .. " in inventory") end
  local fuel_inv = target.get_inventory(defines.inventory.fuel)
  local n = math.min(have, count)
  local inserted = fuel_inv.insert{ name = fuel_item, count = n }
  inv.remove{ name = fuel_item, count = inserted }
  return ok_resp({ target = target.name, fuel = fuel_item, inserted = inserted })
end

-- research --------------------------------------------------------------------
local function fn_research(name, tech_name)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  local force = self.entity.force
  if not force.technologies[tech_name] then return err_resp("unknown tech: " .. tostring(tech_name)) end
  local q = force.research_queue
  table.insert(q, tech_name)
  force.research_queue = q
  return ok_resp({ queued = tech_name, queue_length = #force.research_queue })
end

local function fn_research_status(name)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  local force = self.entity.force
  local current = force.current_research and force.current_research.name or nil
  local progress = force.research_progress
  local queue = {}
  for _, t in ipairs(force.research_queue or {}) do table.insert(queue, t.name or t) end
  return ok_resp({ current = current, progress = progress, queue = queue })
end

local function fn_tech_tree(name, only_available)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  local force = self.entity.force
  local out = {}
  for tname, tech in pairs(force.technologies) do
    if not tech.researched then
      local ready = true
      for _, pre in pairs(tech.prerequisites) do if not pre.researched then ready = false; break end end
      if (not only_available) or ready then
        local ings = {}
        for _, u in ipairs(tech.research_unit_ingredients) do
          table.insert(ings, { name = u.name, amount = u.amount })
        end
        table.insert(out, { name = tname, ready = ready, ingredients = ings })
      end
    end
  end
  return ok_resp({ technologies = out })
end

-- combat / equip --------------------------------------------------------------
local function _set_single_slot(inv, item_name, quality)
  if not inv then return false end
  inv.clear()
  if not item_name then return true end
  local stack = { name = item_name, count = 1 }
  if quality then stack.quality = quality end
  inv.insert(stack)
  return true
end

local function fn_equip(name, opts)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  opts = opts or {}
  local e = self.entity
  if opts.armor ~= nil then _set_single_slot(e.get_inventory(defines.inventory.character_armor), opts.armor) end
  if opts.gun   ~= nil then _set_single_slot(e.get_inventory(defines.inventory.character_guns),  opts.gun)   end
  if opts.ammo  ~= nil then
    local ammo_inv = e.get_inventory(defines.inventory.character_ammo)
    if ammo_inv then ammo_inv.clear(); ammo_inv.insert{ name = opts.ammo, count = tonumber(opts.ammo_count) or 10 } end
  end
  return ok_resp({ equipment = ammo_armor_guns(e) })
end

local function fn_shoot_at(name, x, y)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  x, y = tonumber(x), tonumber(y)
  if not (x and y) then return err_resp("shoot_at requires numeric x,y") end
  self.entity.shooting_state = { state = defines.shooting.shooting_selected, position = { x = x, y = y } }
  self.intent = { kind = "shoot", target = { x = x, y = y } }
  return ok_resp({ target = { x = x, y = y } })
end

-- map / chart -----------------------------------------------------------------
local function fn_chart(name, x, y, radius)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  radius = tonumber(radius) or 32
  local force = self.entity.force
  local surface = self.entity.surface
  force.chart(surface, { { x - radius, y - radius }, { x + radius, y + radius } })
  return ok_resp({ charted_area = { lt = { x - radius, y - radius }, rb = { x + radius, y + radius } } })
end

local function fn_map_summary(name)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  local e = self.entity
  local resources = e.surface.find_entities_filtered{ position = e.position, radius = 128, type = "resource" }
  local agg = {}
  for _, r in ipairs(resources) do
    agg[r.name] = agg[r.name] or { count = 0, total_amount = 0, sample_position = { x = r.position.x, y = r.position.y } }
    agg[r.name].count = agg[r.name].count + 1
    agg[r.name].total_amount = agg[r.name].total_amount + (r.amount or 0)
  end
  return ok_resp({ resources_within_128 = agg })
end

-- find: clustered patches of a resource (or trees) within `radius`.
-- Returns sorted-by-distance patches, each with center / bounding_box /
-- tile_count / total_amount / nearest_tile (the closest integer-tile
-- coordinate to your character — ready to hand straight to walk_to/mine_at).
local function fn_find(name, resource, radius, max_gap)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  if not resource or type(resource) ~= "string" or resource == "" then
    return err_resp("find requires a resource name (e.g. 'stone', 'iron-ore', 'tree')")
  end
  radius  = math.min(math.max(tonumber(radius)  or 128, 8), 512)
  max_gap = math.max(tonumber(max_gap) or 2, 1)
  local e = self.entity
  local surface = e.surface

  local query
  if resource == "tree" or resource == "trees" then
    query = { position = e.position, radius = radius, type = "tree" }
  else
    query = { position = e.position, radius = radius, name = resource }
  end
  local ents = surface.find_entities_filtered(query)
  if #ents == 0 then
    return ok_resp({ resource = resource, radius = radius, patches = {} })
  end

  -- spatial buckets sized by max_gap+1; flood-fill via union-find.
  local bs = max_gap + 1
  local buckets, items = {}, {}
  for i, ent in ipairs(ents) do
    if ent.valid then
      local x, y = ent.position.x, ent.position.y
      local bx, by = math.floor(x / bs), math.floor(y / bs)
      local k = bx .. "," .. by
      buckets[k] = buckets[k] or {}
      table.insert(buckets[k], i)
      -- amount is only defined on resource entities; reading it on a tree errors.
      local amt = 0
      if ent.type == "resource" then amt = ent.amount or 0 end
      items[i] = { x = x, y = y, parent = i, ent = ent, amount = amt }
    end
  end

  local function find_root(i)
    while items[i].parent ~= i do
      items[i].parent = items[items[i].parent].parent
      i = items[i].parent
    end
    return i
  end
  local function union(a, b)
    local ra, rb = find_root(a), find_root(b)
    if ra ~= rb then items[ra].parent = rb end
  end

  for i, it in pairs(items) do
    local bx, by = math.floor(it.x / bs), math.floor(it.y / bs)
    for ddx = -1, 1 do
      for ddy = -1, 1 do
        local nb = buckets[(bx + ddx) .. "," .. (by + ddy)]
        if nb then
          for _, j in ipairs(nb) do
            if j ~= i then
              local dx = items[j].x - it.x
              local dy = items[j].y - it.y
              if math.abs(dx) <= max_gap and math.abs(dy) <= max_gap then
                union(i, j)
              end
            end
          end
        end
      end
    end
  end

  local clusters = {}
  for i, it in pairs(items) do
    local r = find_root(i)
    local c = clusters[r]
    if not c then
      c = { count = 0, sum_x = 0, sum_y = 0, sum_amount = 0,
            min_x = it.x, max_x = it.x, min_y = it.y, max_y = it.y,
            nearest = nil, nearest_d2 = math.huge }
      clusters[r] = c
    end
    c.count       = c.count + 1
    c.sum_x       = c.sum_x + it.x
    c.sum_y       = c.sum_y + it.y
    c.sum_amount  = c.sum_amount + (it.amount or 0)
    if it.x < c.min_x then c.min_x = it.x end
    if it.x > c.max_x then c.max_x = it.x end
    if it.y < c.min_y then c.min_y = it.y end
    if it.y > c.max_y then c.max_y = it.y end
    local dx = it.x - e.position.x
    local dy = it.y - e.position.y
    local d2 = dx * dx + dy * dy
    if d2 < c.nearest_d2 then
      c.nearest_d2 = d2
      c.nearest    = { x = math.floor(it.x + 0.5), y = math.floor(it.y + 0.5) }
    end
  end

  local function round1(v) return math.floor(v * 10 + 0.5) / 10 end
  local patches = {}
  for _, c in pairs(clusters) do
    table.insert(patches, {
      tile_count   = c.count,
      total_amount = c.sum_amount,
      center       = { x = round1(c.sum_x / c.count), y = round1(c.sum_y / c.count) },
      bounding_box = { lt = { x = round1(c.min_x), y = round1(c.min_y) },
                       rb = { x = round1(c.max_x), y = round1(c.max_y) } },
      nearest_tile = c.nearest,
      distance     = round1(math.sqrt(c.nearest_d2)),
    })
  end
  table.sort(patches, function(a, b) return a.distance < b.distance end)

  return ok_resp({ resource = resource, radius = radius, patches = patches })
end

-- text_map: ASCII grid of (2r+1)² tiles around your character.-- One character per tile, suitable for direct LLM consumption.
local function fn_text_map(name, radius)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  radius = math.min(math.max(tonumber(radius) or 24, 4), 40)
  local e = self.entity
  local surface = e.surface
  local cx = math.floor(e.position.x + 0.5)
  local cy = math.floor(e.position.y + 0.5)

  -- Bucket entities by integer tile, keep highest-priority glyph per tile.
  local grid = {}
  local function place(tx, ty, ch, prio)
    local k = tx .. "," .. ty
    local cur = grid[k]
    if not cur or prio > cur.prio then grid[k] = { ch = ch, prio = prio } end
  end
  -- Stamp every tile inside an entity's selection_box (handles 3x3 assemblers,
  -- 2x2 furnaces, etc.) so the agent doesn't think gaps exist where there are none.
  local function place_footprint(ent, ch, prio)
    local sb = ent.selection_box
    if not sb then place(math.floor(ent.position.x + 0.5), math.floor(ent.position.y + 0.5), ch, prio); return end
    local lx = math.floor(sb.left_top.x + 0.5)
    local ly = math.floor(sb.left_top.y + 0.5)
    local rx = math.floor(sb.right_bottom.x - 0.5)
    local ry = math.floor(sb.right_bottom.y - 0.5)
    for tx = lx, rx do
      for ty = ly, ry do place(tx, ty, ch, prio) end
    end
  end

  local ents = surface.find_entities_filtered{ position = e.position, radius = radius + 2 }
  for _, ent in ipairs(ents) do
    if ent.valid and ent ~= e then
      local tx = math.floor(ent.position.x + 0.5)
      local ty = math.floor(ent.position.y + 0.5)
      local t  = ent.type
      local n  = ent.name
      local force_name = ent.force and ent.force.name or nil
      if t == "cliff" then
        place_footprint(ent, "C", 8)
      elseif force_name == "enemy" then
        place(tx, ty, "*", 9)
      elseif t == "character" then
        place(tx, ty, "P", 8)
      elseif t == "resource" then
        local ch = "r"
        if     n == "stone"        then ch = "s"
        elseif n == "iron-ore"     then ch = "i"
        elseif n == "copper-ore"   then ch = "c"
        elseif n == "coal"         then ch = "k"
        elseif n == "uranium-ore"  then ch = "u"
        elseif n == "crude-oil"    then ch = "o"
        end
        place(tx, ty, ch, 5)
      elseif t == "tree" then
        place(tx, ty, "T", 4)
      elseif t == "simple-entity" then
        place(tx, ty, "R", 3)
      elseif force_name == "player" then
        -- Walkable player-built (priority 6): belts, pipes, rails, poles.
        -- Solid player-built (priority 7): everything you can't stand on.
        if t == "transport-belt" or t == "underground-belt" then
          local d = ent.direction or 0
          local ch = "#"
          if     d == 0  then ch = "^"
          elseif d == 4  then ch = ">"
          elseif d == 8  then ch = "v"
          elseif d == 12 then ch = "<"
          end
          place(tx, ty, ch, 6)
        elseif t == "splitter" then
          place_footprint(ent, "S", 6)
        elseif t == "pipe" or t == "pipe-to-ground" then
          place(tx, ty, "=", 6)
        elseif t == "rail" or t == "straight-rail" or t == "curved-rail"
            or t == "elevated-straight-rail" or t == "elevated-curved-rail" then
          place(tx, ty, "+", 6)
        elseif t == "electric-pole" or t == "radar" then
          place(tx, ty, "+", 6)
        elseif t == "inserter" then
          place(tx, ty, "I", 7)
        elseif t == "wall" or t == "gate" then
          place(tx, ty, "W", 7)
        elseif t == "mining-drill" then
          place_footprint(ent, "M", 7)
        elseif t == "assembling-machine" then
          place_footprint(ent, "A", 7)
        elseif t == "furnace" then
          place_footprint(ent, "F", 7)
        elseif t == "lab" then
          place_footprint(ent, "L", 7)
        elseif t == "container" or t == "logistic-container" or t == "infinity-container" then
          place_footprint(ent, "B", 7)
        elseif t == "boiler" or t == "generator" or t == "reactor"
            or t == "solar-panel" or t == "accumulator" then
          place_footprint(ent, "G", 7)
        elseif t == "car" or t == "spider-vehicle" or t == "locomotive"
            or t == "cargo-wagon" or t == "fluid-wagon" then
          place_footprint(ent, "V", 7)
        else
          place(tx, ty, "#", 7)
        end
      end
    end
  end

  local lines = {}
  for dy = -radius, radius do
    local row = {}
    for dx = -radius, radius do
      local ch
      if dx == 0 and dy == 0 then
        ch = "@"
      else
        local tx, ty = cx + dx, cy + dy
        local g = grid[tx .. "," .. ty]
        if g then
          ch = g.ch
        else
          local tile = surface.get_tile(tx, ty)
          if tile and tile.valid then
            local tn = tile.name
            if tn:find("water") or tn:find("deepwater") then
              ch = "~"
            else
              ch = "."
            end
          else
            ch = "?"
          end
        end
      end
      row[#row + 1] = ch
    end
    lines[#lines + 1] = table.concat(row)
  end

  return ok_resp({
    center = { x = cx, y = cy },
    radius = radius,
    legend = "@ self  ~ water  . passable  T tree  R rock  C cliff  s stone  i iron  c copper  k coal  u uranium  o oil  ^v<> belt(walk)  = pipe(walk)  + pole/rail(walk)  I inserter  S splitter  W wall  M drill  A assembler  F furnace  L lab  B chest  G power-gen  V vehicle  # other-built  * enemy  P other-npc  ? uncharted",
    map    = table.concat(lines, "\n"),
  })
end

-- render: structured tile + entity data for Python-side PNG rasterization.
-- Tiles encoded as a (2r+1)² character string (row-major, dy ascending).
-- Glyphs: W deepwater, w water, g grass, d dirt, s sand, r red-desert,
-- p built-path, n nuclear-ground, ? uncharted.
local function fn_render(name, opts)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  opts = opts or {}
  local radius = math.min(math.max(tonumber(opts.radius) or 32, 4), 64)
  local e = self.entity
  local surface = e.surface
  local cx, cy
  if opts.x ~= nil and opts.y ~= nil then
    cx = math.floor(tonumber(opts.x) + 0.5)
    cy = math.floor(tonumber(opts.y) + 0.5)
  else
    cx = math.floor(e.position.x + 0.5)
    cy = math.floor(e.position.y + 0.5)
  end

  local sz = 2 * radius + 1
  local tile_chars = {}
  for dy = -radius, radius do
    for dx = -radius, radius do
      local tile = surface.get_tile(cx + dx, cy + dy)
      local ch = "?"
      if tile and tile.valid then
        local tn = tile.name
        if     tn:find("deepwater")    then ch = "W"
        elseif tn:find("water")        then ch = "w"
        elseif tn:find("grass")        then ch = "g"
        elseif tn:find("sand")         then ch = "s"
        elseif tn:find("desert")       then ch = "r"
        elseif tn:find("dirt") or tn:find("dry") then ch = "d"
        elseif tn:find("stone%-path") or tn:find("concrete") or tn:find("refined") then ch = "p"
        elseif tn:find("nuclear")      then ch = "n"
        elseif tn:find("landfill")     then ch = "d"
        else                                ch = "g"
        end
      end
      tile_chars[#tile_chars + 1] = ch
    end
  end

  local out_ents = {}
  local ents = surface.find_entities_filtered{ position = { x = cx, y = cy }, radius = radius + 2 }
  for _, ent in ipairs(ents) do
    if ent.valid then
      local force_name = ent.force and ent.force.name or ""
      local kind
      if ent == e then
        kind = "self"
      elseif ent.type == "character" then
        kind = "npc"
      elseif force_name == "enemy" then
        kind = "enemy"
      elseif ent.type == "resource" then
        kind = "ore:" .. ent.name
      elseif ent.type == "tree" then
        kind = "tree"
      elseif ent.type == "simple-entity" then
        kind = "rock"
      elseif force_name == "player" then
        kind = "built:" .. ent.type
      else
        kind = "other"
      end
      table.insert(out_ents, {
        x = ent.position.x,
        y = ent.position.y,
        k = kind,
      })
      if #out_ents >= 4000 then break end
    end
  end

  return ok_resp({
    center   = { x = cx, y = cy },
    radius   = radius,
    size     = sz,
    tiles    = table.concat(tile_chars),
    entities = out_ents,
    daytime  = surface.daytime,
  })
end

-- combat / vehicles -----------------------------------------------------------

-- Toggle per-tick auto-engage. Tick code (drive_combat) does the actual
-- targeting and shooting; the LLM only sets policy.
local function fn_combat_mode(name, opts)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  if not self.combat then
    self.combat = { enabled = false, range = 20, retreat_hp_pct = 30, target_un = nil, retreated = false }
  end
  opts = opts or {}
  local c = self.combat
  if opts.enabled ~= nil then c.enabled = opts.enabled and true or false end
  if opts.range ~= nil then c.range = math.max(2, math.min(tonumber(opts.range) or 20, 60)) end
  if opts.retreat_hp_pct ~= nil then
    c.retreat_hp_pct = math.max(0, math.min(tonumber(opts.retreat_hp_pct) or 30, 100))
  end
  if not c.enabled then
    if self.entity.vehicle then
      self.entity.vehicle.shooting_state = { state = defines.shooting.not_shooting, position = { 0, 0 } }
    end
    self.entity.shooting_state = { state = defines.shooting.not_shooting, position = { 0, 0 } }
    c.target_un = nil
    c.retreated = false
  end
  return ok_resp({ combat = c })
end

-- One-shot focus fire: target a specific entity (by unit_number) or position.
-- Sets shooting_state directly; persists until cleared or a new target picked
-- (or, if combat_mode is on, until the per-tick driver overrides).
local function fn_attack_target(name, opts)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  opts = opts or {}
  local e = self.entity
  local shooter = e.vehicle or e
  local pos
  if opts.unit_number then
    local target
    for _, ent in ipairs(e.surface.find_entities_filtered{ position = e.position, radius = 200 }) do
      if ent.valid and ent.unit_number == opts.unit_number then target = ent; break end
    end
    if not target then return err_resp("no entity with unit_number " .. tostring(opts.unit_number) .. " within 200 tiles") end
    pos = { x = target.position.x, y = target.position.y }
  elseif opts.x and opts.y then
    pos = { x = tonumber(opts.x), y = tonumber(opts.y) }
  else
    return err_resp("attack_target requires {unit_number=...} or {x=,y=}")
  end
  shooter.shooting_state = { state = defines.shooting.shooting_selected, position = pos }
  return ok_resp({ shooting_at = pos })
end

-- Mount a vehicle. Pass {unit_number=N} for an exact pick, or {x=,y=} to
-- mount the nearest drivable vehicle within `radius` (default 3) tiles.
local function fn_drive(name, opts)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  opts = opts or {}
  local e = self.entity
  if e.vehicle then return err_resp("already driving " .. e.vehicle.name) end
  local vehicle
  if opts.unit_number then
    for _, ent in ipairs(e.surface.find_entities_filtered{ position = e.position, radius = 50 }) do
      if ent.valid and ent.unit_number == opts.unit_number then vehicle = ent; break end
    end
  else
    local cx = tonumber(opts.x) or e.position.x
    local cy = tonumber(opts.y) or e.position.y
    local r  = tonumber(opts.radius) or 3
    local cands = e.surface.find_entities_filtered{ position = { x = cx, y = cy }, radius = r }
    local best_d = math.huge
    for _, ent in ipairs(cands) do
      if ent.valid and (ent.type == "car" or ent.type == "spider-vehicle" or ent.type == "locomotive")
         and ent.get_driver() == nil then
        local dx, dy = ent.position.x - e.position.x, ent.position.y - e.position.y
        local d = dx*dx + dy*dy
        if d < best_d then best_d = d; vehicle = ent end
      end
    end
  end
  if not (vehicle and vehicle.valid) then return err_resp("no drivable vehicle found") end
  vehicle.set_driver(e)
  if e.vehicle ~= vehicle then return err_resp("set_driver failed (vehicle may be occupied or out of reach)") end
  return ok_resp({
    vehicle = { name = vehicle.name, type = vehicle.type, unit_number = vehicle.unit_number,
                position = { x = vehicle.position.x, y = vehicle.position.y } },
  })
end

local function fn_dismount(name)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  local v = self.entity.vehicle
  if not v then return err_resp("not in a vehicle") end
  v.set_driver(nil)
  self.drive_goal = nil
  return ok_resp({ dismounted = v.name })
end

-- Drive the currently-mounted vehicle to (x, y). Spidertrons use the engine
-- autopilot; cars/tanks use a naive per-tick steering controller.
local function fn_drive_to(name, x, y, opts)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  opts = opts or {}
  x, y = tonumber(x), tonumber(y)
  if not (x and y) then return err_resp("drive_to requires numeric x, y") end
  local v = self.entity.vehicle
  if not v then return err_resp("not in a vehicle (call drive first)") end
  local goal = { x = x, y = y, arrive_radius = tonumber(opts.arrive_radius) or 4.0 }
  self.drive_goal = goal
  if v.type == "spider-vehicle" then
    v.autopilot_destination = { x = x, y = y }
    return ok_resp({ mode = "autopilot", vehicle = v.name, goal = goal })
  end
  return ok_resp({ mode = "manual", vehicle = v.name, goal = goal })
end

-- events / save / screenshot --------------------------------------------------
local function fn_drain_events(name)
  local self, err = get_npc(name); if err then return err_resp(err) end
  local ev = self.events
  self.events = {}
  return ok_resp({ events = ev })
end

-- Compound per-turn perception. ONE RCON round-trip returns everything an
-- agent normally needs at the start of a turn: observation (which already
-- folds in status/inventory/nearby), the drained event queue, and the
-- current craft queue. Saves 3-4 separate tool calls -> 3-4 fewer LLM
-- round-trips and permission prompts per turn.
local function fn_turn(name, radius)
  local self, err = get_npc(name); if err then return err_resp(err) end
  if not ent_of(self) then return ok_resp({ exists = false, name = name }) end
  local obs_raw = fn_observe(name, radius)
  local craft_raw = fn_craft_status(name)
  local ev = self.events; self.events = {}
  return ok_resp({
    observation = helpers.json_to_table(obs_raw),
    events      = ev,
    craft       = helpers.json_to_table(craft_raw),
  })
end

-- Execute a list of operations in ONE Factorio tick. Each op is
-- { fn = "<name>", args = {...} } where <name> is the bare remote interface
-- function (e.g. "place", "fuel", "walk_to"). The NPC name is the same for
-- every op (the outer `name` arg). Returns per-op results in order.
-- Self-recursion ("batch" / "turn") is blocked to keep semantics simple.
-- Argument-name spec for each batchable fn. Used so callers can pass
-- `kwargs = { x=.., y=.., item=.., count=.. }` instead of having to remember
-- positional order. Positional `args` still works and takes precedence.
local _arg_specs = {
  observe       = {"radius"},
  look          = {"radius"},
  look_at       = {"x", "y", "radius"},
  turn          = {"radius"},
  drain_events  = {},
  inventory     = {},
  chart         = {"x", "y", "radius"},
  map_summary   = {},
  find          = {"resource", "radius", "max_gap"},
  text_map      = {"radius"},
  walk          = {"direction"},
  walk_to       = {"x", "y"},
  walk_toward   = {"x", "y", "radius", "speed"},
  stop          = {},
  mine_at       = {"x", "y"},
  craft         = {"recipe", "count"},
  craft_status  = {},
  cancel_craft  = {"index"},
  place         = {"item", "x", "y", "direction"},
  belt          = {"from", "to", "item"},
  inserter      = {"pickup", "drop", "variant"},
  pickup        = {"x", "y"},
  rotate        = {"x", "y", "direction"},
  set_recipe    = {"x", "y", "recipe"},
  insert_into   = {"x", "y", "item", "count"},
  take_from     = {"x", "y", "item", "count"},
  fuel          = {"x", "y", "item", "count"},
  research      = {"tech"},
  equip         = {"opts"},
  shoot_at      = {"x", "y"},
  combat_mode   = {"opts"},
  attack_target = {"opts"},
  drive         = {"opts"},
  dismount      = {},
  drive_to      = {"x", "y", "opts"},
  rename        = {"new_name"},
  spawn         = {"opts"},
  despawn       = {},
  status        = {},
  give          = {"item", "count"},
  say           = {"msg"},
  research_status = {},
  tech_tree     = {"only_available"},
}

local function _kwargs_to_args(fn_name, kwargs)
  local spec = _arg_specs[fn_name]
  if not spec then return nil, "no kwargs spec for " .. fn_name end
  local out = {}
  for i, key in ipairs(spec) do out[i] = kwargs[key] end
  return out
end

local function fn_batch(name, ops)
  if type(ops) ~= "table" then return err_resp("ops must be an array") end
  local iface = remote.interfaces["npc"]
  local results = {}
  for i, op in ipairs(ops) do
    local fn_name = op.fn or op[1]
    local args = op.args
    if (not args) and op.kwargs then
      local built, err = _kwargs_to_args(fn_name, op.kwargs)
      if err then
        results[i] = { ok = false, error = err }
        goto continue
      end
      args = built
    end
    args = args or {}
    if type(fn_name) ~= "string" then
      results[i] = { ok = false, error = "op.fn missing" }
    elseif fn_name == "batch" or fn_name == "turn" then
      results[i] = { ok = false, error = "cannot nest " .. fn_name .. " inside batch" }
    elseif not iface[fn_name] then
      results[i] = { ok = false, error = "unknown op: " .. fn_name }
    else
      local ok, raw = pcall(remote.call, "npc", fn_name, name, table.unpack(args))
      if not ok then
        results[i] = { ok = false, error = tostring(raw) }
      else
        local parsed = helpers.json_to_table(raw)
        results[i] = parsed or { ok = false, error = "non-json result", raw = raw }
      end
    end
    ::continue::
  end
  return ok_resp({ count = #results, results = results })
end

local function fn_screenshot(name, opts)
  local self, e_resp = require_npc(name); if e_resp then return e_resp end
  opts = opts or {}
  local e = self.entity
  local fname = opts.name or (name .. "-" .. game.tick .. ".png")
  local path = "botty/" .. fname
  game.take_screenshot{
    surface          = e.surface,
    position         = opts.position or e.position,
    resolution       = opts.resolution or { 1024, 1024 },
    zoom             = opts.zoom or 0.5,
    path             = path,
    show_entity_info = (opts.show_entity_info ~= false),
    show_gui         = false,
    show_cursor_building_preview = false,
    daytime          = opts.daytime,
    anti_alias       = true,
  }
  return ok_resp({ path = path, url_hint = "/screenshot/" .. fname })
end

local function fn_save(_, save_name)
  -- save is world-wide; npc_name is accepted but ignored.
  if save_name and type(save_name) == "string" and #save_name > 0 then
    game.server_save(save_name)
  else
    game.server_save("auto-" .. game.tick)
  end
  return ok_resp({ saved = true, tick = game.tick })
end

-- ============================================================================
-- remote interface registration
-- Every function takes npc_name as its FIRST argument (except `list` and `save`,
-- which are world-scoped but accept name for signature uniformity).
-- ============================================================================
remote.add_interface("npc", {
  -- multi-NPC management
  spawn          = function(name, opts)            return fn_spawn(name, opts) end,
  despawn        = function(name)                  return fn_despawn(name) end,
  list           = function()                      return fn_list() end,
  status         = function(name)                  return fn_status(name) end,
  rename         = function(name, new_name)        return fn_rename(name, new_name) end,
  save           = function(name, save_name)       return fn_save(name, save_name) end,

  -- perception
  observe        = function(name, r)               return fn_observe(name, r) end,
  look           = function(name, r)               return fn_look(name, r) end,
  look_at        = function(name, x, y, r)         return fn_look_at(name, x, y, r) end,
  inventory      = function(name)                  return fn_inventory(name) end,
  drain_events   = function(name)                  return fn_drain_events(name) end,
  turn           = function(name, r)               return fn_turn(name, r) end,
  batch          = function(name, ops)             return fn_batch(name, ops) end,
  screenshot     = function(name, opts)            return fn_screenshot(name, opts) end,
  chart          = function(name, x, y, r)         return fn_chart(name, x, y, r) end,
  map_summary    = function(name)                  return fn_map_summary(name) end,
  find           = function(name, res, rad, gap)   return fn_find(name, res, rad, gap) end,
  text_map       = function(name, rad)             return fn_text_map(name, rad) end,
  render         = function(name, opts)            return fn_render(name, opts) end,
  research_status= function(name)                  return fn_research_status(name) end,
  tech_tree      = function(name, avail)           return fn_tech_tree(name, avail) end,

  -- movement
  walk           = function(name, dir)             return fn_walk(name, dir) end,
  walk_to        = function(name, x, y)            return fn_walk_to(name, x, y) end,
  walk_toward    = function(name, x, y, r, s)      return fn_walk_toward(name, x, y, r, s) end,
  stop           = function(name)                  return fn_stop(name) end,

  -- gathering
  mine_at        = function(name, x, y)            return fn_mine_at(name, x, y) end,

  -- crafting
  craft          = function(name, r, n)            return fn_craft(name, r, n) end,
  craft_status   = function(name)                  return fn_craft_status(name) end,
  cancel_craft   = function(name, i)               return fn_cancel_craft(name, i) end,

  -- building
  place          = function(name, item, x, y, d)   return fn_place(name, item, x, y, d) end,
  belt           = function(name, from, to, item)  return fn_belt(name, from, to, item) end,
  inserter       = function(name, pickup, drop, v) return fn_inserter(name, pickup, drop, v) end,
  pickup         = function(name, x, y)            return fn_pickup(name, x, y) end,
  rotate         = function(name, x, y, d)         return fn_rotate(name, x, y, d) end,
  set_recipe     = function(name, x, y, r)         return fn_set_recipe(name, x, y, r) end,

  -- logistics
  insert_into    = function(name, x, y, it, n)     return fn_insert_into(name, x, y, it, n) end,
  take_from      = function(name, x, y, it, n)     return fn_take_from(name, x, y, it, n) end,
  fuel           = function(name, x, y, it, n)     return fn_fuel(name, x, y, it, n) end,

  -- research
  research       = function(name, t)               return fn_research(name, t) end,

  -- combat
  equip          = function(name, o)               return fn_equip(name, o) end,
  shoot_at       = function(name, x, y)            return fn_shoot_at(name, x, y) end,
  combat_mode    = function(name, opts)            return fn_combat_mode(name, opts) end,
  attack_target  = function(name, opts)            return fn_attack_target(name, opts) end,

  -- vehicles
  drive          = function(name, opts)            return fn_drive(name, opts) end,
  dismount       = function(name)                  return fn_dismount(name) end,
  drive_to       = function(name, x, y, opts)      return fn_drive_to(name, x, y, opts) end,

  -- chat / cheats
  say            = function(name, t)               return fn_say(name, t) end,
  give           = function(name, it, n, q)        return fn_give(name, it, n, q) end,
})
