--[[
  npc_mcp / control.lua

  Headless agent backend. Owns the detached Botty character, persistent
  state in `storage.npc`, and an on_tick dispatcher that drains queues
  (walk, mine, craft). Exposes everything to the MCP server via
  `remote.add_interface("npc", ...)`. Every interface function returns
  a JSON string; the MCP server's _call() ships it through
  `/sc rcon.print(remote.call("npc", fn, ...))` and json-decodes the
  response.

  Design rule: never crash on bad input. Every public fn returns
  {ok=false, error=...} instead of erroring, so the LLM sees a
  recoverable response instead of an opaque RCON failure.
]]

-- ============================================================================
-- json helpers
-- ============================================================================
local function jenc(t)
  return helpers.table_to_json(t)
end

local function ok_resp(t)
  t = t or {}
  t.ok = true
  return jenc(t)
end

local function err_resp(msg, extra)
  local t = extra or {}
  t.ok = false
  t.error = msg
  return jenc(t)
end

-- ============================================================================
-- storage init
-- ============================================================================
local function ensure_storage()
  storage.npc = storage.npc or {}
  local s = storage.npc
  s.entity        = s.entity or nil
  s.intent        = s.intent or { kind = "idle" }
  s.path          = s.path or nil
  s.path_request  = s.path_request or nil
  s.mine_target   = s.mine_target or nil
  s.craft_queue   = s.craft_queue or {}
  s.events        = s.events or {}
  s.config        = s.config or {
    auto_flee_radius = 0,    -- 0 disables auto-flee; agent decides
    surface_name     = "nauvis",
    nameplate        = "Botty",
  }
  s.map            = s.map or { charted = {} }
end

-- ============================================================================
-- entity helpers
-- ============================================================================
local function npc()
  return storage.npc and storage.npc.entity
end

local function valid_npc()
  local e = npc()
  return e ~= nil and e.valid
end

local function surface_for_npc()
  if valid_npc() then return storage.npc.entity.surface end
  return game.surfaces[storage.npc.config.surface_name] or game.surfaces["nauvis"]
end

local function clear_intent()
  storage.npc.intent      = { kind = "idle" }
  storage.npc.path        = nil
  storage.npc.path_request = nil
  storage.npc.mine_target = nil
  if valid_npc() then
    storage.npc.entity.walking_state = { walking = false, direction = defines.direction.north }
    storage.npc.entity.mining_state  = { mining = false }
    storage.npc.entity.shooting_state = { state = defines.shooting.not_shooting, position = {0,0} }
  end
end

-- ============================================================================
-- direction math
-- ============================================================================
-- Factorio 2.0 uses 0..15 (16-way). 0 = north, increasing clockwise.
local function dir_to(from, to)
  local dx, dy = to.x - from.x, to.y - from.y
  if math.abs(dx) < 0.15 and math.abs(dy) < 0.15 then return nil end
  -- atan2(dx, -dy): 0 = north, +pi/2 = east, etc.
  local angle = math.atan2(dx, -dy)
  if angle < 0 then angle = angle + 2 * math.pi end
  local d = math.floor(angle / (2 * math.pi) * 16 + 0.5) % 16
  return d
end

local _CARDINAL = {
  north = defines.direction.north,
  east  = defines.direction.east,
  south = defines.direction.south,
  west  = defines.direction.west,
}

-- ============================================================================
-- events ring buffer
-- ============================================================================
local EVENT_CAP = 200

local function push_event(kind, data)
  if not storage.npc then return end
  table.insert(storage.npc.events, { tick = game.tick, kind = kind, data = data })
  while #storage.npc.events > EVENT_CAP do
    table.remove(storage.npc.events, 1)
  end
end

-- ============================================================================
-- perception helpers
-- ============================================================================
local function inv_contents(entity)
  if not (entity and entity.valid) then return {} end
  local inv = entity.get_main_inventory()
  if not inv then return {} end
  local raw = inv.get_contents() -- 2.0: array of {name, count, quality}
  local out = {}
  for _, st in pairs(raw) do
    table.insert(out, { name = st.name, count = st.count, quality = st.quality })
  end
  return out
end

local function ammo_armor_guns(entity)
  if not (entity and entity.valid) then return {} end
  local function dump(inv_id)
    local inv = entity.get_inventory(inv_id)
    if not inv then return nil end
    local r = inv.get_contents()
    local out = {}
    for _, st in pairs(r) do
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

local function summarize_entity(e)
  local t = { name = e.name, type = e.type, position = { x = e.position.x, y = e.position.y } }
  if e.type == "resource" then t.amount = e.amount end
  if e.type == "tree" then t.amount = (e.health and math.floor(e.health)) or nil end
  if e.health and e.type ~= "resource" then t.health = math.floor(e.health) end
  if e.unit_number then t.unit_number = e.unit_number end
  if e.prototype and e.prototype.mineable_properties and e.prototype.mineable_properties.minable then
    t.mineable = true
  end
  return t
end

local function nearby_summary(pos, radius, surface)
  surface = surface or surface_for_npc()
  local entities = surface.find_entities_filtered{ position = pos, radius = radius }
  local groups = {}
  local enemy_count = 0
  for _, e in ipairs(entities) do
    if e.valid then
      local g = e.type
      groups[g] = groups[g] or {}
      table.insert(groups[g], summarize_entity(e))
      if e.force and e.force.name == "enemy" then
        enemy_count = enemy_count + 1
      end
    end
  end
  -- truncate giant groups so the response stays small-ish
  for k, list in pairs(groups) do
    if #list > 25 then
      groups[k] = { __truncated_from = #list, sample = {} }
      for i = 1, 25 do groups[k].sample[i] = list[i] end
    end
  end
  return groups, enemy_count
end

-- ============================================================================
-- core lifecycle
-- ============================================================================
local function spawn_botty(opts)
  opts = opts or {}
  local surface_name = opts.surface or storage.npc.config.surface_name or "nauvis"
  local surface = game.surfaces[surface_name]
  if not surface then return err_resp("surface not found: " .. surface_name) end

  if valid_npc() then
    local e = storage.npc.entity
    return ok_resp({
      message  = "already spawned",
      position = { x = e.position.x, y = e.position.y },
      surface  = e.surface.name,
      name     = storage.npc.config.nameplate,
    })
  end

  local pos
  if opts.x ~= nil and opts.y ~= nil then
    pos = { x = opts.x, y = opts.y }
  else
    -- prefer player 1 if anyone happens to be connected, else force spawn
    local p = game.players[1]
    if p and p.connected and p.character then
      local pp = p.character.position
      pos = { x = pp.x + (opts.dx or 3.0), y = pp.y + (opts.dy or 0.0) }
    else
      local sp = game.forces.player.get_spawn_position(surface)
      pos = { x = sp.x + (opts.dx or 0.0), y = sp.y + (opts.dy or 0.0) }
    end
  end

  local safe = surface.find_non_colliding_position("character", pos, 8, 0.5)
  if not safe then return err_resp("no free space near requested position", { requested = pos }) end

  local ent = surface.create_entity{
    name     = "character",
    position = safe,
    force    = "player",
  }
  if not ent then return err_resp("create_entity returned nil") end

  storage.npc.entity = ent
  storage.npc.config.nameplate = opts.name or storage.npc.config.nameplate or "Botty"
  clear_intent()
  push_event("spawn", { position = { x = ent.position.x, y = ent.position.y } })

  game.print("[npc_mcp] " .. storage.npc.config.nameplate ..
             " spawned at (" .. math.floor(ent.position.x) .. ", " ..
             math.floor(ent.position.y) .. ")")

  return ok_resp({
    message  = "spawned",
    position = { x = ent.position.x, y = ent.position.y },
    surface  = ent.surface.name,
    name     = storage.npc.config.nameplate,
  })
end

local function despawn_botty()
  if not valid_npc() then return ok_resp({ message = "already absent" }) end
  storage.npc.entity.destroy()
  storage.npc.entity = nil
  clear_intent()
  push_event("despawn", {})
  return ok_resp({ message = "despawned" })
end

-- ============================================================================
-- on_init / on_load / on_configuration_changed
-- ============================================================================
script.on_init(function()
  ensure_storage()
  -- Auto-spawn so the agent is alive the moment the server boots.
  spawn_botty({})
end)

script.on_load(function()
  -- Storage refs survive; nothing to rebind.
end)

script.on_configuration_changed(function()
  ensure_storage()
end)

-- ============================================================================
-- on_tick dispatcher
-- ============================================================================
local function drive_walk_to()
  local i = storage.npc.intent
  if i.kind ~= "walk_to" then return end
  local p = storage.npc.path
  if not p then
    -- waiting for async path
    return
  end
  if p.i > #p.waypoints then
    clear_intent()
    push_event("arrived", { position = { x = npc().position.x, y = npc().position.y } })
    return
  end
  local target = p.waypoints[p.i]
  local cur = npc().position
  local d = dir_to(cur, target.position)
  if not d then
    p.i = p.i + 1
    return
  end
  npc().walking_state = { walking = true, direction = d }
end

local function drive_walk_continuous()
  local i = storage.npc.intent
  if i.kind ~= "walk" then return end
  npc().walking_state = { walking = true, direction = i.direction or 0 }
end

local function drive_mining()
  local i = storage.npc.intent
  if i.kind ~= "mine" then return end
  if not i.position then clear_intent(); return end
  local cur = npc().position
  local dist = math.sqrt((cur.x - i.position.x)^2 + (cur.y - i.position.y)^2)
  local reach = npc().prototype.reach_resource_distance or 2.7
  if dist > reach then
    -- need to walk closer; degrade to walk_to first then resume mining
    local d = dir_to(cur, i.position)
    if d then npc().walking_state = { walking = true, direction = d } end
    return
  end
  npc().walking_state = { walking = false, direction = 0 }
  npc().mining_state  = { mining = true, position = i.position }

  -- check if target still exists; if not, pop
  local surface = npc().surface
  local ents = surface.find_entities_filtered{ position = i.position, radius = 0.5 }
  local any_mineable = false
  for _, e in ipairs(ents) do
    if e.valid and e.prototype.mineable_properties and e.prototype.mineable_properties.minable then
      any_mineable = true
      break
    end
  end
  if not any_mineable then
    npc().mining_state = { mining = false }
    push_event("mined_out", { position = i.position })
    clear_intent()
  end
end

local function drive_crafting()
  local q = storage.npc.craft_queue
  if not q or #q == 0 then return end
  local head = q[1]
  if not head.started then
    -- consume ingredients up-front for ONE unit
    local recipe = prototypes.recipe[head.recipe]
    if not recipe then
      table.remove(q, 1)
      push_event("craft_failed", { recipe = head.recipe, reason = "unknown recipe" })
      return
    end
    local inv = npc().get_main_inventory()
    -- verify all ingredients present
    for _, ing in ipairs(recipe.ingredients) do
      if ing.type == "item" then
        if inv.get_item_count(ing.name) < ing.amount then
          table.remove(q, 1)
          push_event("craft_failed", { recipe = head.recipe, reason = "missing " .. ing.name })
          return
        end
      end
    end
    for _, ing in ipairs(recipe.ingredients) do
      if ing.type == "item" then
        inv.remove({ name = ing.name, count = ing.amount })
      end
    end
    head.started   = true
    head.time_left = math.max(1, math.ceil(recipe.energy * 60))
  end

  head.time_left = head.time_left - 1
  if head.time_left <= 0 then
    local recipe = prototypes.recipe[head.recipe]
    local inv = npc().get_main_inventory()
    for _, prod in ipairs(recipe.products) do
      if prod.type == "item" then
        local amt = prod.amount or ((prod.amount_min or 1) + (prod.amount_max or 1)) / 2
        inv.insert({ name = prod.name, count = math.floor(amt) })
      end
    end
    head.count = head.count - 1
    push_event("craft_done", { recipe = head.recipe, remaining = head.count })
    if head.count <= 0 then
      table.remove(q, 1)
    else
      head.started = false  -- start next unit
    end
  end
end

script.on_event(defines.events.on_tick, function(_)
  if not storage.npc then return end
  if not valid_npc() then
    -- Botty died or was destroyed externally
    if storage.npc.entity ~= nil then
      storage.npc.entity = nil
      clear_intent()
      push_event("died", {})
    end
    return
  end
  drive_walk_continuous()
  drive_walk_to()
  drive_mining()
  drive_crafting()
end)

-- async pathfind result
script.on_event(defines.events.on_script_path_request_finished, function(e)
  if not storage.npc or storage.npc.path_request ~= e.id then return end
  storage.npc.path_request = nil
  if e.try_again_later then
    -- transient; mark and let the next walk_to retry
    push_event("path_busy", {})
    clear_intent()
    return
  end
  if not e.path then
    push_event("path_failed", {})
    clear_intent()
    return
  end
  storage.npc.path = { waypoints = e.path, i = 1 }
end)

-- event subscribers (lightweight; just append to ring buffer)
script.on_event(defines.events.on_research_finished, function(e)
  push_event("research_finished", { name = e.research.name })
end)

script.on_event(defines.events.on_chunk_charted, function(e)
  -- Don't spam — only push for the agent's force
  if e.force and e.force.name == "player" then
    push_event("chunk_charted", { position = e.position })
  end
end)

-- ============================================================================
-- remote-interface functions
-- ============================================================================

local function fn_status()
  ensure_storage()
  if not valid_npc() then
    return ok_resp({ exists = false })
  end
  local e = storage.npc.entity
  return ok_resp({
    exists   = true,
    name     = storage.npc.config.nameplate,
    position = { x = e.position.x, y = e.position.y },
    surface  = e.surface.name,
    health   = e.health,
    intent   = storage.npc.intent,
    walking  = e.walking_state and e.walking_state.walking or false,
    mining   = e.mining_state and e.mining_state.mining or false,
    tick     = game.tick,
  })
end

local function fn_observe(radius)
  ensure_storage()
  radius = tonumber(radius) or 16
  if not valid_npc() then return ok_resp({ exists = false }) end
  local e = storage.npc.entity
  local groups, enemy_count = nearby_summary(e.position, radius, e.surface)
  return ok_resp({
    exists      = true,
    name        = storage.npc.config.nameplate,
    position    = { x = e.position.x, y = e.position.y },
    surface     = e.surface.name,
    health      = e.health,
    intent      = storage.npc.intent,
    inventory   = inv_contents(e),
    equipment   = ammo_armor_guns(e),
    nearby      = groups,
    enemy_count = enemy_count,
    daytime     = e.surface.daytime,
    tick        = game.tick,
  })
end

local function fn_look(radius)
  if not valid_npc() then return err_resp("npc not spawned") end
  radius = tonumber(radius) or 16
  local e = storage.npc.entity
  local groups, enemy_count = nearby_summary(e.position, radius, e.surface)
  return ok_resp({ position = e.position, nearby = groups, enemy_count = enemy_count })
end

local function fn_look_at(x, y, radius)
  if not valid_npc() then return err_resp("npc not spawned") end
  radius = tonumber(radius) or 16
  local groups, enemy_count = nearby_summary({x=x,y=y}, radius, storage.npc.entity.surface)
  return ok_resp({ anchor = {x=x,y=y}, nearby = groups, enemy_count = enemy_count })
end

local function fn_inventory()
  if not valid_npc() then return err_resp("npc not spawned") end
  return ok_resp({
    main      = inv_contents(storage.npc.entity),
    equipment = ammo_armor_guns(storage.npc.entity),
  })
end

local function fn_walk(direction)
  if not valid_npc() then return err_resp("npc not spawned") end
  local d
  if type(direction) == "string" then
    d = _CARDINAL[direction]
  elseif type(direction) == "number" then
    d = math.floor(direction) % 16
  end
  if d == nil then return err_resp("direction must be north|east|south|west or 0..15") end
  clear_intent()
  storage.npc.intent = { kind = "walk", direction = d }
  return ok_resp({ direction = d })
end

local function fn_walk_to(x, y)
  if not valid_npc() then return err_resp("npc not spawned") end
  x, y = tonumber(x), tonumber(y)
  if not (x and y) then return err_resp("walk_to requires numeric x,y") end
  local e = storage.npc.entity
  clear_intent()
  storage.npc.intent = { kind = "walk_to", goal = { x = x, y = y } }
  local proto = prototypes.entity["character"]
  local req_id = e.surface.request_path{
    bounding_box   = proto.collision_box,
    collision_mask = proto.collision_mask,
    start          = e.position,
    goal           = { x = x, y = y },
    force          = e.force,
    radius         = 1.0,
    pathfind_flags = { cache = true, allow_destroy_friendly_entities = false, prefer_straight_paths = true },
  }
  storage.npc.path_request = req_id
  return ok_resp({ message = "pathfind requested", request_id = req_id, goal = { x = x, y = y } })
end

local function fn_stop()
  if not valid_npc() then return err_resp("npc not spawned") end
  clear_intent()
  return ok_resp({ message = "stopped" })
end

local function fn_mine_at(x, y)
  if not valid_npc() then return err_resp("npc not spawned") end
  x, y = tonumber(x), tonumber(y)
  if not (x and y) then return err_resp("mine_at requires numeric x,y") end
  clear_intent()
  storage.npc.intent = { kind = "mine", position = { x = x, y = y } }
  return ok_resp({ target = { x = x, y = y } })
end

local function fn_give(item, count, quality)
  if not valid_npc() then return err_resp("npc not spawned") end
  count = tonumber(count) or 1
  if not prototypes.item[item] then return err_resp("unknown item: " .. tostring(item)) end
  local inv = storage.npc.entity.get_main_inventory()
  if not inv then return err_resp("no main inventory") end
  local stack = { name = item, count = count }
  if quality and prototypes.quality and prototypes.quality[quality] then stack.quality = quality end
  local inserted = inv.insert(stack)
  return ok_resp({ inserted = inserted, requested = count })
end

local function fn_say(text)
  if not text then return err_resp("say requires text") end
  local name = (storage.npc and storage.npc.config and storage.npc.config.nameplate) or "Botty"
  game.print("[" .. name .. "] " .. tostring(text))
  return ok_resp({})
end

local function fn_rename(name)
  ensure_storage()
  if not name then return err_resp("rename requires name") end
  storage.npc.config.nameplate = name
  return ok_resp({ name = name })
end

-- crafting ---------------------------------------------------------------------
local function fn_craft(recipe_name, count)
  if not valid_npc() then return err_resp("npc not spawned") end
  count = tonumber(count) or 1
  local recipe = prototypes.recipe[recipe_name]
  if not recipe then return err_resp("unknown recipe: " .. tostring(recipe_name)) end
  if not storage.npc.entity.force.recipes[recipe_name].enabled then
    return err_resp("recipe not researched: " .. recipe_name)
  end
  table.insert(storage.npc.craft_queue, {
    recipe    = recipe_name,
    count     = count,
    started   = false,
    time_left = 0,
  })
  return ok_resp({ queued = count, recipe = recipe_name, position_in_queue = #storage.npc.craft_queue })
end

local function fn_craft_status()
  ensure_storage()
  local out = {}
  for _, entry in ipairs(storage.npc.craft_queue or {}) do
    table.insert(out, {
      recipe    = entry.recipe,
      remaining = entry.count,
      started   = entry.started,
      time_left = entry.time_left,
    })
  end
  return ok_resp({ queue = out })
end

local function fn_cancel_craft(index)
  ensure_storage()
  index = tonumber(index) or 1
  local q = storage.npc.craft_queue
  if not q[index] then return err_resp("no craft entry at index " .. index) end
  table.remove(q, index)
  return ok_resp({ cancelled_index = index })
end

-- building / placement ---------------------------------------------------------
local function fn_place(item, x, y, direction)
  if not valid_npc() then return err_resp("npc not spawned") end
  x, y = tonumber(x), tonumber(y)
  if not (x and y) then return err_resp("place requires numeric x,y") end
  local item_proto = prototypes.item[item]
  if not item_proto then return err_resp("unknown item: " .. tostring(item)) end
  local place_result = item_proto.place_result
  if not place_result then return err_resp(item .. " has no place_result (not a placeable item)") end

  local e = storage.npc.entity
  local inv = e.get_main_inventory()
  if inv.get_item_count(item) < 1 then return err_resp("inventory has no " .. item) end

  local dir = tonumber(direction) or defines.direction.north
  local pos = { x = x, y = y }
  if not e.surface.can_place_entity{ name = place_result.name, position = pos, direction = dir, force = e.force } then
    return err_resp("cannot place " .. place_result.name .. " at (" .. x .. "," .. y .. ")")
  end
  local placed = e.surface.create_entity{
    name      = place_result.name,
    position  = pos,
    direction = dir,
    force     = e.force,
    raise_built = true,
  }
  if not placed then return err_resp("create_entity returned nil") end
  inv.remove({ name = item, count = 1 })
  push_event("placed", { name = placed.name, position = pos })
  return ok_resp({ placed = placed.name, position = pos })
end

local function fn_pickup(x, y)
  if not valid_npc() then return err_resp("npc not spawned") end
  x, y = tonumber(x), tonumber(y)
  local e = storage.npc.entity
  local ents = e.surface.find_entities_filtered{ position = {x=x,y=y}, radius = 0.6, force = e.force }
  if #ents == 0 then return err_resp("nothing of yours at that point") end
  local target = ents[1]
  local name = target.name
  local mined = e.mine_entity(target, true)  -- force = true => to character inventory
  if not mined then return err_resp("mine_entity refused") end
  push_event("picked_up", { name = name, position = {x=x,y=y} })
  return ok_resp({ name = name })
end

local function fn_rotate(x, y, direction)
  if not valid_npc() then return err_resp("npc not spawned") end
  local e = storage.npc.entity
  local ents = e.surface.find_entities_filtered{ position = {x=x,y=y}, radius = 0.6 }
  if #ents == 0 then return err_resp("no entity at that point") end
  local target = ents[1]
  if not target.supports_direction then return err_resp(target.name .. " is not rotatable") end
  target.direction = tonumber(direction) or 0
  return ok_resp({ name = target.name, direction = target.direction })
end

local function fn_set_recipe(x, y, recipe_name)
  if not valid_npc() then return err_resp("npc not spawned") end
  local e = storage.npc.entity
  local ents = e.surface.find_entities_filtered{ position = {x=x,y=y}, radius = 0.6, type = "assembling-machine" }
  if #ents == 0 then return err_resp("no assembling machine there") end
  local r = prototypes.recipe[recipe_name]
  if not r then return err_resp("unknown recipe: " .. tostring(recipe_name)) end
  ents[1].set_recipe(recipe_name)
  return ok_resp({ machine = ents[1].name, recipe = recipe_name })
end

-- logistics --------------------------------------------------------------------
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

local function fn_insert_into(x, y, item, count)
  if not valid_npc() then return err_resp("npc not spawned") end
  count = tonumber(count) or 1
  local e = storage.npc.entity
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

local function fn_take_from(x, y, item, count)
  if not valid_npc() then return err_resp("npc not spawned") end
  count = tonumber(count) or 1
  local e = storage.npc.entity
  local target = _find_container(e.surface, {x=x,y=y})
  if not target then return err_resp("no container at that point") end
  local taken = 0
  local remaining = count
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
        taken = taken + got
        remaining = remaining - got
        if remaining <= 0 then break end
      end
    end
  end
  return ok_resp({ target = target.name, taken = taken })
end

local function fn_fuel(x, y, fuel_item, count)
  if not valid_npc() then return err_resp("npc not spawned") end
  fuel_item = fuel_item or "coal"
  count = tonumber(count) or 5
  local e = storage.npc.entity
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

-- research ---------------------------------------------------------------------
local function fn_research(tech_name)
  if not valid_npc() then return err_resp("npc not spawned") end
  local force = storage.npc.entity.force
  if not force.technologies[tech_name] then return err_resp("unknown tech: " .. tostring(tech_name)) end
  local q = force.research_queue
  table.insert(q, tech_name)
  force.research_queue = q
  return ok_resp({ queued = tech_name, queue_length = #force.research_queue })
end

local function fn_research_status()
  if not valid_npc() then return err_resp("npc not spawned") end
  local force = storage.npc.entity.force
  local current = force.current_research and force.current_research.name or nil
  local progress = force.research_progress
  local queue = {}
  for _, t in ipairs(force.research_queue or {}) do
    table.insert(queue, t.name or t)
  end
  return ok_resp({ current = current, progress = progress, queue = queue })
end

local function fn_tech_tree(only_available)
  if not valid_npc() then return err_resp("npc not spawned") end
  local force = storage.npc.entity.force
  local out = {}
  for name, tech in pairs(force.technologies) do
    if not tech.researched then
      local ready = true
      for _, pre in pairs(tech.prerequisites) do
        if not pre.researched then ready = false; break end
      end
      if (not only_available) or ready then
        table.insert(out, { name = name, ready = ready, ingredients = (function()
          local r = {}
          for _, u in ipairs(tech.research_unit_ingredients) do
            table.insert(r, { name = u.name, amount = u.amount })
          end
          return r
        end)() })
      end
    end
  end
  return ok_resp({ technologies = out })
end

-- combat / equip ---------------------------------------------------------------
local function _set_single_slot(inv, item_name, quality)
  if not inv then return false end
  inv.clear()
  if not item_name then return true end
  local stack = { name = item_name, count = 1 }
  if quality then stack.quality = quality end
  inv.insert(stack)
  return true
end

local function fn_equip(opts)
  if not valid_npc() then return err_resp("npc not spawned") end
  opts = opts or {}
  local e = storage.npc.entity
  if opts.armor ~= nil then
    _set_single_slot(e.get_inventory(defines.inventory.character_armor), opts.armor)
  end
  if opts.gun ~= nil then
    _set_single_slot(e.get_inventory(defines.inventory.character_guns), opts.gun)
  end
  if opts.ammo ~= nil then
    local ammo_inv = e.get_inventory(defines.inventory.character_ammo)
    if ammo_inv then
      ammo_inv.clear()
      ammo_inv.insert{ name = opts.ammo, count = tonumber(opts.ammo_count) or 10 }
    end
  end
  return ok_resp({ equipment = ammo_armor_guns(e) })
end

local function fn_shoot_at(x, y)
  if not valid_npc() then return err_resp("npc not spawned") end
  x, y = tonumber(x), tonumber(y)
  if not (x and y) then return err_resp("shoot_at requires numeric x,y") end
  storage.npc.entity.shooting_state = {
    state    = defines.shooting.shooting_selected,
    position = { x = x, y = y },
  }
  storage.npc.intent = { kind = "shoot", target = { x = x, y = y } }
  return ok_resp({ target = { x = x, y = y } })
end

-- map / chart ------------------------------------------------------------------
local function fn_chart(x, y, radius)
  if not valid_npc() then return err_resp("npc not spawned") end
  radius = tonumber(radius) or 32
  local force = storage.npc.entity.force
  local surface = storage.npc.entity.surface
  force.chart(surface, { { x - radius, y - radius }, { x + radius, y + radius } })
  return ok_resp({ charted_area = { lt = { x - radius, y - radius }, rb = { x + radius, y + radius } } })
end

local function fn_map_summary()
  if not valid_npc() then return err_resp("npc not spawned") end
  -- Cheap aggregate: scan a wide radius around Botty for resource patches.
  local e = storage.npc.entity
  local resources = e.surface.find_entities_filtered{
    position = e.position, radius = 128, type = "resource",
  }
  local agg = {}
  for _, r in ipairs(resources) do
    agg[r.name] = agg[r.name] or { count = 0, total_amount = 0, sample_position = { x = r.position.x, y = r.position.y } }
    agg[r.name].count = agg[r.name].count + 1
    agg[r.name].total_amount = agg[r.name].total_amount + (r.amount or 0)
  end
  return ok_resp({ resources_within_128 = agg })
end

-- events / save ----------------------------------------------------------------
local function fn_drain_events()
  ensure_storage()
  local ev = storage.npc.events
  storage.npc.events = {}
  return ok_resp({ events = ev })
end

local function fn_screenshot(opts)
  opts = opts or {}
  if not valid_npc() then return err_resp("npc not spawned") end
  local e = storage.npc.entity
  local name = opts.name or ("shot-" .. game.tick .. ".png")
  local path = "botty/" .. name
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
  return ok_resp({ path = path, url_hint = "/screenshot/" .. name })
end

local function fn_save(name)
  if name and type(name) == "string" and #name > 0 then
    game.server_save(name)
  else
    game.server_save("auto-" .. game.tick)
  end
  return ok_resp({ saved = true, tick = game.tick })
end

-- ============================================================================
-- remote interface registration
-- ============================================================================
remote.add_interface("npc", {
  -- lifecycle
  spawn          = function(opts)         return spawn_botty(opts) end,
  despawn        = function()             return despawn_botty() end,
  status         = function()             return fn_status() end,
  rename         = function(name)         return fn_rename(name) end,
  save           = function(name)         return fn_save(name) end,

  -- perception
  observe        = function(r)            return fn_observe(r) end,
  look           = function(r)            return fn_look(r) end,
  look_at        = function(x,y,r)        return fn_look_at(x,y,r) end,
  inventory      = function()             return fn_inventory() end,
  drain_events   = function()             return fn_drain_events() end,
  screenshot     = function(opts)         return fn_screenshot(opts) end,
  chart          = function(x,y,r)        return fn_chart(x,y,r) end,
  map_summary    = function()             return fn_map_summary() end,
  research_status= function()             return fn_research_status() end,
  tech_tree      = function(avail)        return fn_tech_tree(avail) end,

  -- movement
  walk           = function(dir)          return fn_walk(dir) end,
  walk_to        = function(x,y)          return fn_walk_to(x,y) end,
  stop           = function()             return fn_stop() end,

  -- gathering
  mine_at        = function(x,y)          return fn_mine_at(x,y) end,

  -- crafting
  craft          = function(r,n)          return fn_craft(r,n) end,
  craft_status   = function()             return fn_craft_status() end,
  cancel_craft   = function(i)            return fn_cancel_craft(i) end,

  -- building
  place          = function(item,x,y,d)   return fn_place(item,x,y,d) end,
  pickup         = function(x,y)          return fn_pickup(x,y) end,
  rotate         = function(x,y,d)        return fn_rotate(x,y,d) end,
  set_recipe     = function(x,y,r)        return fn_set_recipe(x,y,r) end,

  -- logistics
  insert_into    = function(x,y,it,n)     return fn_insert_into(x,y,it,n) end,
  take_from      = function(x,y,it,n)     return fn_take_from(x,y,it,n) end,
  fuel           = function(x,y,it,n)     return fn_fuel(x,y,it,n) end,

  -- research
  research       = function(t)            return fn_research(t) end,

  -- combat
  equip          = function(o)            return fn_equip(o) end,
  shoot_at       = function(x,y)          return fn_shoot_at(x,y) end,

  -- chat / cheats
  say            = function(t)            return fn_say(t) end,
  give           = function(it,n,q)       return fn_give(it,n,q) end,
})
