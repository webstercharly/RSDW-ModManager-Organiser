-- Cross-chest search, inspection, pin-on-map, safe withdraw-to-backpack, and
-- native open-chest tab switching for the Organiser module and Chest Dock.

local engine = require("rlm_engine")

local M = {}

local PIN_OWNER = "chest_explorer"
local PIN_COLOR = { R = 0.25, G = 0.88, B = 0.78, A = 1.0 }
local DEFAULT_SEARCH_RANGE_MIN = 120
local LAST_PINNED = nil

local function safe_call(fn, fallback)
    local ok, res = pcall(fn)
    if ok then return res end
    return fallback
end

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function to_text_string(value)
    if value == nil then return nil end
    if type(value) == "string" then
        return (value ~= "" and value ~= "None") and value or nil
    end
    local ok, s = pcall(function() return value:ToString() end)
    if ok and type(s) == "string" and s ~= "" and s ~= "None" then
        return s
    end
    return nil
end

local function organiser_mod()
    return package.loaded.rlm_organiser or require("rlm_organiser")
end

local function icons_mod()
    local mod = package.loaded.rlm_row_icons
    if type(mod) == "table" and type(mod.path) == "function" then return mod end
    return nil
end

local function minimap_mod()
    local mod = package.loaded.rlm_minimap
    if type(mod) == "table" and type(mod.show_destinations) == "function" then
        return mod
    end
    return nil
end

local function object_address(obj)
    if not engine.is_valid(obj) then return nil end
    return safe_call(function() return obj:GetAddress() end)
end

local function actor_location(actor)
    if not engine.is_valid(actor) then return nil end
    return safe_call(function() return actor:K2_GetActorLocation() end)
end

function M.same_object(a, b)
    if not a or not b then return false end
    if a == b then return true end
    local addr_a = object_address(a)
    local addr_b = object_address(b)
    return addr_a ~= nil and addr_b ~= nil and addr_a == addr_b
end

local function clean_building_fallback(actor)
    local bname = to_text_string(safe_call(function() return actor:GetBuildingName() end))
    if bname then return bname end
    local full = safe_call(function() return actor:GetFullName() end, "")
    local short = full:match("%.([^%.]+)$") or full
    if short:find("Chest_Iron", 1, true) then return "Iron Chest" end
    if short:find("Chest_Small", 1, true) then return "Small Chest" end
    if short:find("Chest", 1, true) then return "Chest" end
    if short:find("Crate", 1, true) then return "Crate" end
    if short:find("Barrel", 1, true) then return "Barrel" end
    if short ~= "" then return short end
    return "Storage Container"
end

function M.container_title(entry)
    if type(entry) ~= "table" then return "Storage Container" end
    local role = trim(entry.label or entry.role or "")
    local native_name = trim(entry.native_name or "")
    if native_name == "" and engine.is_valid(entry.actor) then
        native_name = trim(to_text_string(safe_call(function() return entry.actor:GetCustomName() end)) or "")
    end
    local building = engine.is_valid(entry.actor) and clean_building_fallback(entry.actor) or "Storage Container"
    if role ~= "" and native_name ~= "" and native_name:lower() ~= role:lower() then
        return native_name .. " (" .. role .. ")"
    elseif role ~= "" then
        return role
    elseif native_name ~= "" then
        return native_name
    end
    return building
end

local function effective_settings(org, opts)
    local base = type(org.settings) == "function" and org.settings() or {}
    local copy = {}
    for k, v in pairs(base) do copy[k] = v end
    copy.anyStorage = true
    local base_range = tonumber(base.rangeMeters) or 40
    local min_range = opts and tonumber(opts.range_meters) or DEFAULT_SEARCH_RANGE_MIN
    if min_range > base_range then copy.rangeMeters = min_range end
    return copy
end

function M.nearby_chests(opts)
    local org = (type(opts) == "table" and opts.org) or organiser_mod()
    local controller = engine.local_controller()
    if not engine.is_valid(controller) then return {}, "Local player controller is not ready." end
    local pawn = engine.local_pawn()
    if not engine.is_valid(pawn) then return {}, "Player pawn is not ready." end
    local pos = actor_location(pawn)
    if not pos then return {}, "Player position is unavailable." end

    local settings = effective_settings(org, opts)
    local open_inv, open_actor = org.open_storage()
    local keep_actors, keep_addrs = {}, {}
    local function record_keep(a)
        if engine.is_valid(a) then
            keep_actors[#keep_actors + 1] = a
            keep_addrs[#keep_addrs + 1] = object_address(a)
        end
    end
    record_keep(opts and opts.keep_actor)
    if type(opts) == "table" and type(opts.keep_actors) == "table" then
        for _, a in ipairs(opts.keep_actors) do record_keep(a) end
    end
    local raw = org.all_storage_in_reach(pos, settings, {
        open_actor = open_actor,
        open_addr = object_address(open_actor),
        include_locked = (opts == nil or opts.include_locked ~= false),
        keep_actor = opts and opts.keep_actor or nil,
        keep_addr = opts and object_address(opts.keep_actor) or nil,
        keep_actors = keep_actors,
        keep_addrs = keep_addrs,
    }) or {}

    local out = {}
    for idx, chest in ipairs(raw) do
        local inv = chest.inv
        if engine.is_valid(inv) then
            local slots = org.read_slots(inv) or {}
            local max_slots = tonumber(chest.maxSlots) or tonumber(safe_call(function() return inv.MaxSlotCount end, 0)) or #slots
            local is_open = M.same_object(inv, open_inv) or M.same_object(chest.actor, open_actor)
            local actor_key = trim(safe_call(function() return chest.actor:GetFullName() end, ""))
            if actor_key == "" then
                local addr = object_address(chest.actor)
                actor_key = addr ~= nil and ("addr:" .. tostring(addr)) or ("idx:" .. tostring(idx))
            end
            local entry = {
                index = #out + 1,
                key = actor_key,
                actor = chest.actor,
                inv = inv,
                native_name = chest.native_name or "",
                label = chest.label,
                role = chest.label,
                rule = chest.rule,
                distance = tonumber(chest.distance) or 0,
                pos = chest.pos,
                slots = slots,
                used_slots = #slots,
                max_slots = max_slots,
                is_open = is_open,
            }
            entry.title = M.container_title(entry)
            out[#out + 1] = entry
        end
    end
    return out, settings.rangeMeters or DEFAULT_SEARCH_RANGE_MIN
end

local function item_icon_path(info)
    local ic = icons_mod()
    if not ic then return nil end
    if type(ic.resolve_item_icon) == "function" then
        return ic.resolve_item_icon(info.id, info.name)
    end
    return ic.path(info.name) or ic.path(info.id)
end

function M.format_osrs_count(count)
    local n = math.floor(tonumber(count) or 0)
    if n <= 1 then return "" end
    if n >= 10000000 then
        return tostring(math.floor(n / 1000000)) .. "M"
    end
    if n >= 100000 then
        return tostring(math.floor(n / 1000)) .. "K"
    end
    return tostring(n)
end

function M.osrs_stack_color(count)
    local n = math.floor(tonumber(count) or 0)
    if n >= 10000000 then
        return { R = 0.25, G = 0.96, B = 0.45, A = 1.0 }
    elseif n >= 100000 then
        return { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
    end
    return { R = 1.0, G = 0.89, B = 0.24, A = 1.0 }
end

function M.item_monogram(name)
    local s = trim(tostring(name or "?"))
    if s == "" then return "?" end
    local w1, w2 = s:match("^(%a)%S*%s+(%a)")
    if w1 and w2 then return (w1 .. w2):upper() end
    return s:sub(1, 3):upper()
end

local function slot_matches_query(info, q)
    if not q or q == "" then return true end
    local name_l = tostring(info.name or ""):lower()
    local id_l = tostring(info.id or ""):lower()
    return name_l:find(q, 1, true) ~= nil or id_l:find(q, 1, true) ~= nil
end

function M.search_items(query, opts)
    opts = opts or {}
    local org = organiser_mod()
    local q = trim(tostring(query or "")):lower()
    local limit = tonumber(opts.limit) or 80

    local hits = {}
    local chests, range_or_err = M.nearby_chests(opts)
    if type(range_or_err) == "string" and #chests == 0 then
        return {}, { chests = 0, range = 0, query = q, error = range_or_err }
    end

    if opts.include_player ~= false then
        local ctrl = engine.local_controller()
        local p_inv = engine.is_valid(ctrl) and safe_call(function() return ctrl.InventoryComponent end) or nil
        if engine.is_valid(p_inv) then
            for _, item in ipairs(org.read_slots(p_inv) or {}) do
                if slot_matches_query(item, q) then
                    hits[#hits + 1] = {
                        kind = "player",
                        key = "self:" .. tostring(item.slot),
                        item_name = item.name or "Unknown Item",
                        item_id = item.id or "?",
                        count = tonumber(item.count) or 1,
                        max_stack = tonumber(item.maxStack) or 1,
                        slot = item.slot,
                        icon = item_icon_path(item),
                        chest_title = "Carried in Your Inventory",
                        chest_role = "Player",
                        chest_distance = 0,
                        chest_inv = p_inv,
                    }
                    if #hits >= limit then break end
                end
            end
        end
    end

    for _, chest in ipairs(chests) do
        if #hits >= limit then break end
        for _, item in ipairs(chest.slots) do
            if slot_matches_query(item, q) then
                hits[#hits + 1] = {
                    kind = "chest",
                    key = chest.key .. ":" .. tostring(item.slot),
                    chest_key = chest.key,
                    item_name = item.name or "Unknown Item",
                    item_id = item.id or "?",
                    count = tonumber(item.count) or 1,
                    max_stack = tonumber(item.maxStack) or 1,
                    slot = item.slot,
                    icon = item_icon_path(item),
                    chest_title = chest.title,
                    chest_role = chest.role,
                    chest_distance = chest.distance,
                    chest_actor = chest.actor,
                    chest_inv = chest.inv,
                    chest_pos = chest.pos,
                    chest_entry = chest,
                }
                if #hits >= limit then break end
            end
        end
    end

    return hits, {
        chests = #chests,
        range = tonumber(range_or_err) or DEFAULT_SEARCH_RANGE_MIN,
        query = q,
        count = #hits,
        truncated = #hits >= limit,
    }
end

local function build_slot_lookup(org, inv)
    local occupied = {}
    local slots = org.read_slots(inv) or {}
    for _, info in ipairs(slots) do
        occupied[info.slot] = info
    end
    return occupied
end

function M.plan_withdraw_to_backpack(src_inv, src_slot, dst_inv, amount)
    local org = organiser_mod()
    if not engine.is_valid(src_inv) or not engine.is_valid(dst_inv) then
        return { ok = false, reason = "Storage or player inventory is not ready." }
    end
    if M.same_object(src_inv, dst_inv) then
        return { ok = false, reason = "Item is already in your inventory." }
    end

    local src_occupied = build_slot_lookup(org, src_inv)
    local src_item = src_occupied[src_slot]
    if not src_item or (tonumber(src_item.count) or 0) <= 0 then
        return { ok = false, reason = "Source chest slot is empty or moved." }
    end

    local available = tonumber(src_item.count) or 1
    local want = tonumber(amount) and math.floor(tonumber(amount)) or available
    want = math.max(1, math.min(available, want))
    local max_stack = math.max(1, tonumber(src_item.maxStack) or 1)

    local ranges = org.backpack_slot_ranges(dst_inv, { includeRunes = false, includeAmmo = false }) or {}
    local dst_occupied = build_slot_lookup(org, dst_inv)

    -- First preference: top up an existing partial stack in the backpack page.
    for _, r in ipairs(ranges) do
        for slot = r[1], r[2] do
            local existing = dst_occupied[slot]
            if existing and existing.id == src_item.id then
                local existing_max = math.max(max_stack, tonumber(existing.maxStack) or 1)
                local room = existing_max - (tonumber(existing.count) or 0)
                if room > 0 then
                    local move_count = math.min(want, room)
                    return {
                        ok = true,
                        src_slot = src_slot,
                        dst_slot = slot,
                        count = move_count,
                        is_split = move_count < available,
                        merge = true,
                        item_name = src_item.name or "item",
                        item_id = src_item.id or "?",
                    }
                end
            end
        end
    end

    -- Second preference: first empty backpack slot.
    for _, r in ipairs(ranges) do
        for slot = r[1], r[2] do
            if not dst_occupied[slot] then
                local move_count = math.min(want, max_stack)
                return {
                    ok = true,
                    src_slot = src_slot,
                    dst_slot = slot,
                    count = move_count,
                    is_split = move_count < available,
                    merge = false,
                    item_name = src_item.name or "item",
                    item_id = src_item.id or "?",
                }
            end
        end
    end

    return { ok = false, reason = "Backpack items page is full (0 free slots)." }
end

local function validate_container_accessible(org, actor, inv)
    if not engine.is_valid(actor) or not engine.is_valid(inv) then
        return false, "Target chest is no longer loaded."
    end
    local open_inv, open_actor = org.open_storage()
    local is_local_open = M.same_object(inv, open_inv) or M.same_object(actor, open_actor)

    local linked = safe_call(function() return actor.LinkedInventoryComponent end)
    if org.is_remote_client() and engine.is_valid(linked) and safe_call(function() return linked.bIsLocked end, false) == true and not is_local_open then
        return false, "Chest is currently locked by another player."
    end

    if org.is_remote_client() then
        local ownership = safe_call(function() return actor.OwnershipComponent end)
        if org.is_private_locked_from_local(ownership) then
            return false, "Chest is privately locked by another player."
        end
    end
    return true
end

function M.withdraw_to_backpack(hit, amount, on_done)
    if type(hit) ~= "table" or hit.kind == "player" then
        return false, "That item is already in your inventory."
    end
    local org = organiser_mod()
    local pc = engine.local_controller()
    if not engine.is_valid(pc) then return false, "Local player controller is not ready." end
    local ctrl = safe_call(function() return pc.InventoryController end)
    if not engine.is_valid(ctrl) then return false, "Inventory controller is unavailable." end
    local player_inv = safe_call(function() return pc.InventoryComponent end)
    if not engine.is_valid(player_inv) then return false, "Player inventory component is unavailable." end

    local ok_access, access_err = validate_container_accessible(org, hit.chest_actor, hit.chest_inv)
    if not ok_access then return false, access_err end

    local plan = M.plan_withdraw_to_backpack(hit.chest_inv, hit.slot, player_inv, amount)
    if not plan.ok then return false, plan.reason end

    local ok, err = org.transfer_single_slot(
        ctrl, hit.chest_inv, plan.src_slot, player_inv, plan.dst_slot,
        plan.count, plan.is_split, on_done)
    if not ok then return false, err or "Failed to transfer item." end

    local label = hit.chest_title or "chest"
    if org.is_remote_client() then
        return true, ("Withdrawing %dx %s from %s..."):format(plan.count, plan.item_name, label)
    end
    return true, ("Withdrew %dx %s from %s."):format(plan.count, plan.item_name, label)
end

function M.plan_move_to_chest(entry, target_chest, amount, org_override)
    if type(entry) ~= "table" or entry.kind == "player" then
        return { ok = false, reason = "Select a chest item first." }
    end
    if type(target_chest) ~= "table" or not engine.is_valid(target_chest.inv) then
        return { ok = false, reason = "Target chest is unavailable." }
    end
    local org = org_override or organiser_mod()
    if not engine.is_valid(entry.chest_inv) then
        return { ok = false, reason = "Source chest is no longer loaded." }
    end
    if M.same_object(entry.chest_inv, target_chest.inv) then
        return { ok = false, reason = "Item is already in that chest." }
    end

    local src_occupied = build_slot_lookup(org, entry.chest_inv)
    local src_item = src_occupied[entry.slot]
    if not src_item or (tonumber(src_item.count) or 0) <= 0 then
        return { ok = false, reason = "Source chest slot is empty or moved." }
    end

    local available = tonumber(src_item.count) or 1
    local want = tonumber(amount) and math.floor(tonumber(amount)) or available
    want = math.max(1, math.min(available, want))
    local max_stack = math.max(1, tonumber(src_item.maxStack) or 1)
    local dst_cap = tonumber(safe_call(function() return target_chest.inv.MaxSlotCount end, 0))
        or tonumber(target_chest.max_slots) or 0
    if dst_cap <= 0 then
        return { ok = false, reason = "Target chest slot capacity is unavailable." }
    end

    local dst_occupied = build_slot_lookup(org, target_chest.inv)
    for slot_idx = 0, dst_cap - 1 do
        local existing = dst_occupied[slot_idx]
        if existing and existing.id == src_item.id then
            local existing_max = math.max(max_stack, tonumber(existing.maxStack) or 1)
            local room = existing_max - (tonumber(existing.count) or 0)
            if room > 0 then
                local move_count = math.min(want, room)
                return {
                    ok = true,
                    src_slot = entry.slot,
                    dst_slot = slot_idx,
                    count = move_count,
                    is_split = move_count < available,
                    item_name = src_item.name or entry.item_name or "item",
                }
            end
        end
    end
    for slot_idx = 0, dst_cap - 1 do
        if not dst_occupied[slot_idx] then
            local move_count = math.min(want, max_stack)
            return {
                ok = true,
                src_slot = entry.slot,
                dst_slot = slot_idx,
                count = move_count,
                is_split = move_count < available,
                item_name = src_item.name or entry.item_name or "item",
            }
        end
    end
    return { ok = false, reason = (target_chest.title or "Target chest") .. " is full (0 free slots)." }
end

function M.move_entry_to_chest(entry, target_chest, amount, on_done, org_override)
    local org = org_override or organiser_mod()
    local pc = engine.local_controller()
    if not engine.is_valid(pc) then return false, "Local player controller is not ready." end
    local ctrl = safe_call(function() return pc.InventoryController end)
    if not engine.is_valid(ctrl) then return false, "Inventory controller is unavailable." end

    local plan = M.plan_move_to_chest(entry, target_chest, amount, org)
    if not plan.ok then return false, plan.reason end

    local ok, err = org.transfer_single_slot(
        ctrl, entry.chest_inv, plan.src_slot, target_chest.inv, plan.dst_slot,
        plan.count, plan.is_split, on_done)
    if not ok then return false, err or "Failed to transfer item." end

    local dst_label = target_chest.title or "chest"
    if type(org.is_remote_client) == "function" and org.is_remote_client() then
        return true, ("Moving %dx %s -> %s..."):format(plan.count, plan.item_name, dst_label)
    end
    return true, ("Moved %dx %s -> %s."):format(plan.count, plan.item_name, dst_label)
end

function M.pin_chest(entry)
    if type(entry) ~= "table" then return false, "Select a chest or item first." end
    local pos = entry.pos or entry.chest_pos
    if type(pos) ~= "table" and engine.is_valid(entry.actor or entry.chest_actor) then
        pos = actor_location(entry.actor or entry.chest_actor)
    end
    if type(pos) ~= "table" then return false, "Chest coordinates are unavailable." end

    local map = minimap_mod()
    if not map then return false, "Minimap service is unavailable." end
    local title = entry.title or entry.chest_title or "Chest"
    local owner = type(map.claim) == "function" and map.claim(PIN_OWNER) or PIN_OWNER
    LAST_PINNED = owner
    local ok = map.show_destinations({
        {
            id = "chest:" .. tostring(entry.key or title),
            kind = "Chest",
            name = title,
            location = pos,
        },
    }, PIN_COLOR, { owner = owner, minimap = true, seconds = 60 })
    if ok == false then
        return false, "Could not place minimap pin for " .. title .. "."
    end
    return true, ("Pinned %s on your map and minimap (60 s)."):format(title)
end

function M.clear_pin()
    local map = minimap_mod()
    if map and LAST_PINNED and type(map.clear_destinations) == "function" then
        map.clear_destinations(LAST_PINNED)
        LAST_PINNED = nil
        return true
    end
    return false
end

function M.deposit_from_bank(active_chest, org_override)
    local org = org_override or organiser_mod()
    local controller = engine.local_controller()
    if not engine.is_valid(controller) then return false, "Local player controller is not ready." end
    local player_inv = safe_call(function() return controller.InventoryComponent end)
    local ctrl = safe_call(function() return controller.InventoryController end)
    if not engine.is_valid(player_inv) or not engine.is_valid(ctrl) then
        return false, "Player inventory controller is unavailable."
    end

    local settings = type(org.settings) == "function" and org.settings() or {}
    local pawn = safe_call(function() return controller.Pawn end)
    local pawn_pos = actor_location(pawn)
    local labelled = (type(org.labelled_storage_in_reach) == "function" and pawn_pos)
        and (org.labelled_storage_in_reach(pawn_pos, settings) or {}) or {}
    if #labelled > 0 and type(org.deposit_backpack) == "function" then
        local ok, msg = org.deposit_backpack()
        if ok and msg and msg:find("left in", 1, true) then
            msg = msg .. " (Full chests spill automatically into matching chests or 'All: Misc'.)"
        end
        return ok, msg
    end

    -- When zero chests are labelled, deposit directly into the active chest and
    -- automatically spill over to the next nearest unlocked chest when one fills up.
    if type(org.is_remote_client) == "function" and org.is_remote_client() then
        return false, "Label at least one chest (e.g. 'All: Misc') to auto-deposit on a remote server."
    end
    local chests = M.nearby_chests({
        keep_actor = active_chest and active_chest.actor or nil,
        org = org,
    }) or {}
    if #chests == 0 then
        return false, "No nearby chests within reach."
    end
    local ordered = {}
    if type(active_chest) == "table" and engine.is_valid(active_chest.inv) then
        for _, c in ipairs(chests) do
            if M.same_object(c.inv, active_chest.inv) then ordered[#ordered + 1] = c end
        end
    end
    for _, c in ipairs(chests) do
        if not (type(active_chest) == "table" and M.same_object(c.inv, active_chest.inv)) then
            ordered[#ordered + 1] = c
        end
    end

    local ranges = type(org.backpack_slot_ranges) == "function"
        and (org.backpack_slot_ranges(player_inv, settings) or {}) or {}
    local carried = {}
    for _, r in ipairs(ranges) do
        for _, info in ipairs(org.read_slots(player_inv, r[1], r[2]) or {}) do
            carried[#carried + 1] = info
        end
    end
    if #carried == 0 then return true, "Backpack is already empty." end
    table.sort(carried, function(a, b) return (a.slot or 0) > (b.slot or 0) end)

    local locks = type(org.locks) == "function" and (org.locks() or {}) or {}
    local totals = {}
    for _, info in ipairs(carried) do
        totals[info.name] = (totals[info.name] or 0) + (tonumber(info.count) or 0)
    end
    local to_send = {}
    for name, total in pairs(totals) do
        local lr = locks[name]
        local keep = (lr == "all" or lr == math.huge) and total or (tonumber(lr) or 0)
        to_send[name] = math.max(0, total - keep)
    end

    local space_cache = {}
    local moved, used_chests, leftover = 0, {}, 0
    for _, info in ipairs(carried) do
        local want = math.min(tonumber(info.count) or 0, to_send[info.name] or 0)
        local left = want
        local max_stack = math.max(1, tonumber(info.maxStack) or 1)
        for ci, chest in ipairs(ordered) do
            if left <= 0 then break end
            local ok_acc = validate_container_accessible(org, chest.actor, chest.inv)
            if ok_acc then
                local slots = space_cache[ci]
                if not slots then
                    slots = {}
                    local cap = tonumber(safe_call(function() return chest.inv.MaxSlotCount end, 0)) or 0
                    for si = 0, cap - 1 do slots[si] = { empty = true } end
                    for _, occ in ipairs(org.read_slots(chest.inv) or {}) do
                        slots[occ.slot] = {
                            id = occ.id,
                            free = math.max(0, (tonumber(occ.maxStack) or 1) - (tonumber(occ.count) or 0)),
                        }
                    end
                    space_cache[ci] = slots
                end
                local targets = {}
                for si, st in pairs(slots) do
                    if st.id == info.id and st.free > 0 then targets[#targets + 1] = { slot = si, rank = 0 }
                    elseif st.empty then targets[#targets + 1] = { slot = si, rank = 1 } end
                end
                table.sort(targets, function(a, b)
                    if a.rank ~= b.rank then return a.rank < b.rank end
                    return a.slot < b.slot
                end)
                for _, t in ipairs(targets) do
                    if left <= 0 then break end
                    local st = slots[t.slot]
                    local room = st.empty and max_stack or st.free
                    local n = math.min(left, room)
                    local ok_tx
                    if n == info.count then
                        ok_tx = pcall(function() ctrl:MoveItemBetweenInventories(player_inv, info.slot, chest.inv, t.slot) end)
                    else
                        ok_tx = pcall(function() ctrl:SplitAndPutStack(player_inv, info.slot, n, chest.inv, t.slot) end)
                    end
                    if ok_tx then
                        slots[t.slot] = { id = info.id, free = room - n }
                        left = left - n
                        moved = moved + n
                        info.count = info.count - n
                        used_chests[chest.key or ci] = true
                    end
                end
            end
        end
        to_send[info.name] = math.max(0, (to_send[info.name] or 0) - (want - left))
        if left > 0 then leftover = leftover + left end
    end

    local c_count = 0
    for _ in pairs(used_chests) do c_count = c_count + 1 end
    if moved == 0 and leftover > 0 then
        return false, "All nearby chests are full."
    elseif leftover > 0 then
        return true, ("Deposited %d item(s) across %d chest(s); %d leftover (chests full)."):format(moved, c_count, leftover)
    end
    return true, ("Deposited %d item(s) into %d chest(s)."):format(moved, c_count)
end

function M.switch_open_chest(api, target_inv)
    if not engine.is_valid(api) or not engine.is_valid(target_inv) then
        return false, "Chest panel API or target inventory is invalid."
    end
    local ok_set = pcall(function() api:SetInventory(target_inv) end)
    if not ok_set then
        return false, "Native chest switch rejected."
    end
    local current = safe_call(function() return api:GetInventoryComponent() end)
    if not M.same_object(current, target_inv) then
        return false, "Native panel did not switch to target chest."
    end
    return true
end

local function short_tab_label(chest)
    local raw = trim((type(chest) == "table" and (chest.role or chest.title)) or "Chest")
    raw = raw:gsub("^[Aa][Ll][Ll]:%s*", "")
    if #raw <= 7 then return raw:upper() end
    return raw:sub(1, 7):upper()
end

function M.build_bank_view_model(chests, selected_tab_key, search_query, opts)
    local raw_chests = type(chests) == "table" and chests or {}
    local ordered = {}
    for _, c in ipairs(raw_chests) do ordered[#ordered + 1] = c end
    local order_map = type(opts) == "table" and opts.order_map or nil
    if type(order_map) == "table" then
        local max_ord = 0
        for _, v in pairs(order_map) do
            if type(v) == "number" and v > max_ord then max_ord = v end
        end
        for _, c in ipairs(ordered) do
            if c.key and order_map[c.key] == nil then
                max_ord = max_ord + 1
                order_map[c.key] = max_ord
            end
        end
        table.sort(ordered, function(a, b)
            local oa = (a.key and order_map[a.key]) or 999999
            local ob = (b.key and order_map[b.key]) or 999999
            if oa == ob then return (tonumber(a.index) or 0) < (tonumber(b.index) or 0) end
            return oa < ob
        end)
    end

    local q = trim(tostring(search_query or "")):lower()
    local tabs = {}
    local total_used, total_max = 0, 0
    local sig_parts = {}

    for idx, chest in ipairs(ordered) do
        local used = tonumber(chest.used_slots) or #(chest.slots or {})
        local cap = tonumber(chest.max_slots) or used
        total_used = total_used + used
        total_max = total_max + cap
        local lead, lead_icon = nil, nil
        for _, slot_item in ipairs(chest.slots or {}) do
            if not lead then lead = slot_item end
            local icon_hit = item_icon_path(slot_item)
            if icon_hit then
                lead = slot_item
                lead_icon = icon_hit
                break
            end
        end
        sig_parts[#sig_parts + 1] = tostring(chest.key or idx) .. ":" .. tostring(used) .. ":" .. tostring(chest.role or "")
        tabs[idx] = {
            key = chest.key,
            index = idx,
            title = chest.title or "Chest",
            short_label = short_tab_label(chest),
            role = chest.role,
            distance = tonumber(chest.distance) or 0,
            used_slots = used,
            max_slots = cap,
            lead_icon = lead_icon,
            lead_monogram = lead and M.item_monogram(lead.name) or "CH",
            chest = chest,
        }
    end

    local use_all = (selected_tab_key == "__all__") or (q ~= "")
    local active_chest, active_tab_index = nil, 0
    if not use_all then
        for idx, c in ipairs(ordered) do
            if c.key == selected_tab_key then
                active_chest = c
                active_tab_index = idx
                break
            end
        end
        if not active_chest then
            active_chest = ordered[1]
            active_tab_index = active_chest and 1 or 0
        end
    end

    local source_chests = use_all and ordered or (active_chest and { active_chest } or {})
    local entries = {}
    for _, chest in ipairs(source_chests) do
        for _, info in ipairs(chest.slots or {}) do
            if slot_matches_query(info, q) then
                entries[#entries + 1] = {
                    kind = "chest",
                    key = tostring(chest.key) .. ":" .. tostring(info.slot),
                    chest_key = chest.key,
                    chest_title = chest.title,
                    chest_role = chest.role,
                    chest_distance = chest.distance,
                    chest_actor = chest.actor,
                    chest_inv = chest.inv,
                    chest_pos = chest.pos,
                    slot = info.slot,
                    item_name = info.name or "Unknown",
                    item_id = info.id or "?",
                    count = tonumber(info.count) or 1,
                    max_stack = tonumber(info.maxStack) or 1,
                    count_text = M.format_osrs_count(info.count or 1),
                    count_color = M.osrs_stack_color(info.count or 1),
                    monogram = M.item_monogram(info.name),
                    icon = item_icon_path(info),
                }
            end
        end
    end

    local header_title, counter_used, counter_max
    if use_all then
        header_title = (q ~= "") and ('Search: "' .. trim(tostring(search_query)) .. '"') or "All Nearby Chests"
        counter_used = total_used
        counter_max = total_max
    elseif active_chest then
        header_title = active_chest.title or "Chest"
        counter_used = tonumber(active_chest.used_slots) or #(active_chest.slots or {})
        counter_max = tonumber(active_chest.max_slots) or counter_used
    else
        header_title = "No Chests"
        counter_used, counter_max = 0, 0
    end

    return {
        tabs = tabs,
        entries = entries,
        use_all = use_all,
        active_key = use_all and "__all__" or (active_chest and active_chest.key or nil),
        active_tab_index = active_tab_index,
        active_chest = active_chest,
        title = header_title,
        used_slots = counter_used,
        max_slots = counter_max,
        total_chests = #ordered,
        tab_list_sig = table.concat(sig_parts, "|"),
        query = q,
    }
end

return M
