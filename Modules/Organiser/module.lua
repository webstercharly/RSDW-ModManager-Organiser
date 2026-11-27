-- View and action adapter for the Organiser module.
-- Discovers storage, presents label and lock workflows, and runs deposit/trash actions.

local engine = require("rlm_engine")
local log = require("rlm_log")
local store = require("rlm_store")
local source = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
local module_dir = assert(source:match("^(.*)[/\\][^/\\]+$"), "Organiser module path is unavailable")
if not package.path:find(module_dir, 1, true) then
    package.path = module_dir .. "/?.lua;" .. package.path
end

for _, name in ipairs({ "rlm_osrs_bank_hud", "rlm_organiser_hud" }) do
    local previous = package.loaded[name]
    if type(previous) == "table" and type(previous.stop) == "function" then pcall(previous.stop) end
    package.loaded[name] = nil
end

local organiser = assert(loadfile(module_dir .. "/rlm_organiser.lua"))()
package.loaded.rlm_organiser = organiser
local chest_explorer = assert(loadfile(module_dir .. "/rlm_chest_explorer.lua"))()
package.loaded.rlm_chest_explorer = chest_explorer
local bank_chunk, bank_error = loadfile(module_dir .. "/rlm_osrs_bank_hud.lua")
if bank_chunk then
    local ok, bank = pcall(bank_chunk)
    if ok and type(bank) == "table" then package.loaded.rlm_osrs_bank_hud = bank
    else log.warn("OSRS Bank HUD load failed: " .. tostring(bank)) end
else
    log.warn("OSRS Bank HUD compile failed: " .. tostring(bank_error))
end
local hud_chunk, hud_error = loadfile(module_dir .. "/rlm_organiser_hud.lua")
if hud_chunk then
    local ok, hud = pcall(hud_chunk, organiser)
    if ok and type(hud) == "table" then package.loaded.rlm_organiser_hud = hud
    else log.warn("Organiser HUD load failed: " .. tostring(hud)) end
else
    log.warn("Organiser HUD compile failed: " .. tostring(hud_error))
end

local M = {}
local storage_error = nil
local current_view = "overview"
local selected_lock_item = nil
local last_message
local nearby_page = 1
local NEARBY_PER_PAGE = 12
local search_query = ""
local find_page = 1
local FIND_PER_PAGE = 12
local selected_hit = nil
local last_find_hits = {}
local last_nearby_chests = {}
local selected_chest_key = nil
local selected_chest_slot = nil
local chest_page = 1
local CHEST_PER_PAGE = 12

local REACH_PRESETS = { 10, 20, 30, 40, 60, 100 }

local function find_next_preset(current, presets)
    for index, val in ipairs(presets) do
        if val == current then
            return presets[(index % #presets) + 1]
        end
    end
    return presets[1]
end

local function nearby_storage()
    local settings = organiser.settings()
    local controller = engine.local_controller()
    local pawn = controller and controller.Pawn
    local pawn_pos = pawn and engine.is_valid(pawn) and pawn:K2_GetActorLocation() or nil
    local nearby = pawn_pos and organiser.labelled_storage_in_reach(pawn_pos, settings) or {}
    return nearby, settings.rangeMeters or 40
end

local function accessible_chests()
    if chest_explorer and type(chest_explorer.nearby_chests) == "function" then
        return chest_explorer.nearby_chests()
    end
    return nearby_storage()
end

local function find_chest_by_key(chests, key)
    for _, c in ipairs(chests or {}) do
        if c.key == key then return c end
    end
    return nil
end

local function link(title, view_id)
    return { title = title .. "  ›", value = "nav:" .. view_id, compact = true, destination = true }
end

local function back(title, target_view)
    return { title = "‹  " .. (title or "Organiser"), value = "nav:" .. (target_view or "overview"), compact = true }
end

local function overview_view(state)
    local nearby, range = nearby_storage()
    local all_chests = accessible_chests()
    local rows = {}
    local open_inv, open_actor = organiser.open_storage()
    if open_inv and open_actor and engine.is_valid(open_actor) then
        local label = organiser.label_of(open_actor) or "Unlabelled"
        rows[#rows + 1] = link("Open Storage  •  " .. label, "label_open")
    end
    rows[#rows + 1] = link("Find Items Across Chests", "find_items")
    rows[#rows + 1] = link(("Nearby Storage  (%d)"):format(#all_chests), "nearby")
    rows[#rows + 1] = link("Base Setup", "base_setup")
    rows[#rows + 1] = link("Base Advisor", "advisor")
    rows[#rows + 1] = link("Carried Items & Locks", "locks")
    rows[#rows + 1] = link("Settings", "settings")
    local actions = { "deposit" }
    if #nearby >= 2 then actions[#actions + 1] = "resort-nearby" end
    return {
        detail = last_message or ("%d accessible containers (%d labelled, %d m reach)"):format(#all_chests, #nearby, range),
        preview = {
            title = "Storage Organiser", compact = true,
            stats = {
                { label = "Nearby containers", value = #all_chests },
                { label = "Labelled", value = #nearby },
                { label = "Reach", value = range .. " m" },
            },
        },
        rows = rows, poolRows = true, actionIds = actions,
        inlineActions = state and state.uiInlineActions,
    }
end

local function find_items_view(state)
    local rows = { back() }
    local hits, meta = {}, { chests = 0, range = 0, query = search_query }
    if chest_explorer and type(chest_explorer.search_items) == "function" then
        hits, meta = chest_explorer.search_items(search_query, { limit = 80 })
    end
    last_find_hits = hits

    local pages = math.max(1, math.ceil(#hits / FIND_PER_PAGE))
    find_page = math.min(find_page, pages)
    local previous = find_page > 1 and "find:previous" or nil
    local following = find_page < pages and "find:next" or nil
    if not (state and state.uiPagination) then
        if previous then rows[#rows + 1] = { title = "‹  Previous", value = previous, compact = true } end
        if following then rows[#rows + 1] = { title = "Next  ›", value = following, compact = true } end
    end

    local selected_match = nil
    if selected_hit then
        for _, h in ipairs(hits) do
            if h.key == selected_hit.key then
                selected_match = h
                selected_hit = h
                break
            end
        end
        if not selected_match then selected_hit = nil end
    end

    local first = (find_page - 1) * FIND_PER_PAGE + 1
    for idx = first, math.min(first + FIND_PER_PAGE - 1, #hits) do
        local hit = hits[idx]
        local prefix = (selected_match and selected_match.key == hit.key) and "› " or ""
        local detail
        if hit.kind == "player" then
            detail = ("Already in your inventory (slot %d)."):format((hit.slot or 0) + 1)
        else
            local role_text = hit.chest_role and ("  •  Role: " .. hit.chest_role) or ""
            detail = ("%s  •  %.1f m  •  Slot %d%s"):format(
                hit.chest_title or "Chest", hit.chest_distance or 0, (hit.slot or 0) + 1, role_text)
        end
        rows[#rows + 1] = {
            title = ("%s%s  x%d  •  %s"):format(prefix, hit.item_name, hit.count or 1, hit.chest_title or "Chest"),
            value = "find_hit:" .. idx,
            detail = detail,
            icon = hit.icon,
            compact = true,
        }
    end

    local actions = { "search-items" }
    if search_query ~= "" then actions[#actions + 1] = "clear-search" end
    if selected_match and selected_match.kind == "chest" then
        actions[#actions + 1] = "withdraw-one"
        if (selected_match.count or 1) > 1 then
            actions[#actions + 1] = "withdraw-stack"
        end
        actions[#actions + 1] = "inspect-hit-chest"
        actions[#actions + 1] = "pin-chest"
    end

    local query_label = search_query ~= "" and ('"' .. search_query .. '"') or "All nearby items"
    local detail_text = last_message or meta.error
        or ("%d match(es) for %s across %d containers (%d m range)."):format(
            #hits, query_label, meta.chests or 0, meta.range or 80)
    local preview = {
        title = "Find Items Across Chests", compact = true,
        stats = {
            { label = "Query", value = search_query ~= "" and search_query or "All items" },
            { label = "Matches", value = #hits .. (meta.truncated and "+" or "") },
            { label = "Containers scanned", value = meta.chests or 0 },
        },
    }
    if selected_match then
        preview.stats[#preview.stats + 1] = {
            label = "Selected",
            value = ("%s x%d (%s)"):format(selected_match.item_name, selected_match.count or 1, selected_match.chest_title),
        }
    end

    return {
        status = "Find Items", detail = detail_text, preview = preview,
        rows = rows, poolRows = true,
        pagination = state and state.uiPagination and {
            page = find_page, pages = pages, previous = previous, next = following,
        } or nil,
        actionIds = actions,
        inlineActions = state and state.uiInlineActions,
    }
end

local function nearby_view(state)
    local chests, range = accessible_chests()
    last_nearby_chests = chests
    local pages = math.max(1, math.ceil(#chests / NEARBY_PER_PAGE))
    nearby_page = math.min(nearby_page, pages)
    local rows = { back() }
    local previous = nearby_page > 1 and "nearby:previous" or nil
    local following = nearby_page < pages and "nearby:next" or nil
    if not (state and state.uiPagination) then
        if previous then rows[#rows + 1] = { title = "‹  Previous", value = previous, compact = true } end
        if following then rows[#rows + 1] = { title = "Next  ›", value = following, compact = true } end
    end
    local first = (nearby_page - 1) * NEARBY_PER_PAGE + 1
    for index = first, math.min(first + NEARBY_PER_PAGE - 1, #chests) do
        local chest = chests[index]
        local title = chest.title or chest.label or "Storage"
        local open_tag = chest.is_open and " [OPEN]" or ""
        local role_tag = chest.role and ("Role: " .. chest.role .. "  •  ") or "Unlabelled  •  "
        rows[#rows + 1] = {
            title = ("%s%s  •  %d/%d  •  %.0f m  ›"):format(
                title, open_tag, chest.used_slots or 0, chest.max_slots or 0, chest.distance or 0),
            value = "inspect:" .. index,
            detail = ("%sSelect to browse contents, withdraw items, or pin on map."):format(role_tag),
            compact = true,
        }
    end
    local summary = last_message
        or (#chests == 0 and ("No accessible storage within %d m."):format(tonumber(range) or 80)
        or ("%d accessible containers within %d m. Click any container to inspect or withdraw."):format(#chests, tonumber(range) or 80))
    return {
        status = "Nearby Storage", detail = summary, rows = rows, poolRows = true,
        pagination = state and state.uiPagination and {
            page = nearby_page, pages = pages, previous = previous, next = following,
        } or nil,
        actionIds = #chests >= 2 and { "search-items", "resort-nearby" } or { "search-items" },
        inlineActions = state and state.uiInlineActions,
    }
end

local function chest_detail_view(state)
    local chests = accessible_chests()
    last_nearby_chests = chests
    local chest = find_chest_by_key(chests, selected_chest_key)
    if not chest then
        return nearby_view(state)
    end

    local items = chest.slots or {}
    local rows = { back("Nearby Storage", "nearby") }
    local pages = math.max(1, math.ceil(#items / CHEST_PER_PAGE))
    chest_page = math.min(chest_page, pages)
    local previous = chest_page > 1 and "chest_detail:previous" or nil
    local following = chest_page < pages and "chest_detail:next" or nil
    if not (state and state.uiPagination) then
        if previous then rows[#rows + 1] = { title = "‹  Previous", value = previous, compact = true } end
        if following then rows[#rows + 1] = { title = "Next  ›", value = following, compact = true } end
    end

    local icons = package.loaded.rlm_row_icons
    local selected_item = nil
    local first = (chest_page - 1) * CHEST_PER_PAGE + 1
    for i = first, math.min(first + CHEST_PER_PAGE - 1, #items) do
        local info = items[i]
        local prefix = (selected_chest_slot == info.slot) and "› " or ""
        if selected_chest_slot == info.slot then selected_item = info end
        local icon = icons and type(icons.path) == "function"
            and (icons.path(info.name) or icons.path(info.id)) or nil
        rows[#rows + 1] = {
            title = ("%s%s  x%d"):format(prefix, info.name or "Unknown", info.count or 1),
            value = "chest_slot:" .. tostring(info.slot),
            detail = ("Slot %d%s"):format((info.slot or 0) + 1, chest.is_open and "  •  Currently open" or ""),
            icon = icon,
            compact = true,
        }
    end

    if #items == 0 then
        rows[#rows + 1] = { title = "Container is empty", value = "noop", detail = "No stored items.", compact = true }
    end

    local actions = { "pin-chest" }
    if selected_item then
        actions[#actions + 1] = "withdraw-one"
        if (selected_item.count or 1) > 1 then
            actions[#actions + 1] = "withdraw-stack"
        end
    end

    return {
        status = chest.title or "Chest Contents",
        detail = last_message or ("%d/%d slots used  •  %.1f m away. Select an item to withdraw."):format(
            chest.used_slots or 0, chest.max_slots or 0, chest.distance or 0),
        preview = {
            title = chest.title or "Chest Contents", compact = true,
            stats = {
                { label = "Distance", value = ("%.1f m"):format(chest.distance or 0) },
                { label = "Slots", value = ("%d / %d"):format(chest.used_slots or 0, chest.max_slots or 0) },
                { label = "Role", value = chest.role or "Unlabelled" },
            },
        },
        rows = rows, poolRows = true,
        pagination = state and state.uiPagination and {
            page = chest_page, pages = pages, previous = previous, next = following,
        } or nil,
        actionIds = actions,
        inlineActions = state and state.uiInlineActions,
    }
end

local function base_setup_view(state)
    return {
        status = "Base Setup",
        detail = "Fill Unlabelled keeps existing labels. Re-plan & Rename can change labels across the base.",
        rows = { back() }, poolRows = true,
        inlineActions = state and state.uiInlineActions,
        actionIds = { "fill-unlabelled", "auto-organise" },
    }
end

local function label_open_view()
    local open_inv, open_actor = organiser.open_storage()
    local rows = {
        back(),
    }

    if not open_inv or not open_actor then
        return {
            status = "Open Storage",
            detail = "Open a chest or container to assign a label.",
            rows = rows,
            actionIds = {},
        }
    end

    local current = organiser.label_of(open_actor)
    local suggestions = organiser.label_suggestions(open_inv)

    for _, sug in ipairs(suggestions) do
        local is_cur = sug == current
        rows[#rows + 1] = {
            title = is_cur and (sug .. "  (current)") or sug,
            value = "apply_label:" .. sug,
            detail = "Set label to: " .. sug,
            compact = true,
        }
    end

    rows[#rows + 1] = {
        title = "CLEAR LABEL",
        value = "apply_label:CLEAR", action = true,
        detail = "Remove any label from this container.",
        compact = true,
    }

    return {
        status = "Open Storage  •  " .. (current or "Unlabelled"),
        detail = "Choose a suggested label or enter your own.",
        rows = rows,
        poolRows = true,
        actionIds = { "sort-open", "label", "trash" },
        inputValue = current or "",
    }
end

local function locks_view()
    local rows = {
        back(),
    }

    local controller = engine.local_controller()
    local inv = controller and controller.InventoryComponent
    local locks_table = organiser.locks()

    if inv and engine.is_valid(inv) then
        local carried_items = {}
        local slots = inv.ItemSlots
        if slots and slots.ForEach then
            slots:ForEach(function(idx, el)
                local item = el:get()
                if item and engine.is_valid(item) then
                    local data = item.ItemData
                    if data and engine.is_valid(data) then
                        local name = data.Name and data.Name:ToString() or "Unknown"
                        local count = tonumber(item.Count) or 1
                        carried_items[name] = (carried_items[name] or 0) + count
                    end
                end
            end)
        end

        local item_names = {}
        for name in pairs(carried_items) do item_names[#item_names + 1] = name end
        table.sort(item_names)

        for _, name in ipairs(item_names) do
            local lock_val = locks_table[name]
            local lock_text = "Unrestricted"
            if lock_val == "all" then
                lock_text = "Keep All"
            elseif type(lock_val) == "number" then
                lock_text = "Keep " .. lock_val
            end
            local is_selected = selected_lock_item == name
            local prefix = is_selected and "* " or ""
            rows[#rows + 1] = {
                title = prefix .. name .. "  •  " .. lock_text .. " (" .. carried_items[name] .. " carried)",
                value = "select_item_lock:" .. name,
                detail = "Click to set retention rule. Enter 'all', '0' (unlock), or a count in the input field.",
                compact = true,
            }
        end
    end

    rows[#rows + 1] = {
        title = "CLEAR ALL RETENTION LOCKS",
        value = "action:clear_all_locks", action = true,
        detail = "Remove all item keep locks, allowing all carried items to be deposited.",
        compact = true,
    }

    local prompt = selected_lock_item
        and ("Selected for lock: " .. selected_lock_item .. ". Enter keep count (all, 0, 5, 20) and press SET LOCK.")
        or "Select a carried item above to configure its retention lock."

    return {
        status = "ITEM RETENTION LOCKS",
        detail = prompt,
        rows = rows,
        poolRows = true,
        actionIds = { "lock" },
        inputValue = selected_lock_item and (locks_table[selected_lock_item] or "all") or "",
    }
end

local function settings_view()
    local s = organiser.settings()
    local rows = {
        back(),
        {
            title = "AUTO-LOAD ON CHEST OPEN: " .. (s.autoOpenOnStorage ~= false and "ON" or "OFF"),
            value = "setting_toggle:autoOpenOnStorage",
            detail = "Show Organiser when opening built storage.",
            compact = true,
        },
        {
            title = "OSRS BANK CHEST UI: " .. (s.osrsBankMode ~= false and "ON" or "OFF"),
            value = "setting_toggle:osrsBankMode",
            detail = "Replace the center chest window with the OSRS Bank view (tabs, icon grid, quick withdraw) while keeping your backpack visible.",
            compact = true,
        },
        {
            title = "AUTO-DEPOSIT ON CHEST OPEN: " .. (s.autoDepositOnOpen and "ON" or "OFF"),
            value = "setting_toggle:autoDepositOnOpen",
            detail = "Automatically deposit matching carried items into the open chest when opened.",
            compact = true,
        },
        {
            title = "REACH DISTANCE: " .. tostring(s.rangeMeters) .. " m",
            value = "setting_toggle:rangeMeters",
            detail = "Maximum distance from player to consider labelled storage for deposit.",
            compact = true,
        },
        {
            title = "LABEL ANY STORAGE: " .. (s.anyStorage and "ON" or "OFF"),
            value = "setting_toggle:anyStorage",
            detail = "When ON, crates, racks, and barrels can be labelled. When OFF, chests only.",
            compact = true,
        },
        {
            title = "TRASH CONTAINER INCINERATION: " .. (s.enableTrash and "ON" or "OFF"),
            value = "setting_toggle:enableTrash",
            detail = "Containers labelled 'Trash' destroy their contents when closed.",
            compact = true,
        },
        {
            title = "TRASH FIRE EFFECT: " .. (s.trashFire and "ON" or "OFF"),
            value = "setting_toggle:trashFire",
            detail = "Spawn fire burst VFX on trash container when incinerating.",
            compact = true,
        },
        {
            title = "DEPOSIT SPELLCAST ANIMATION: " .. (s.castAnimation and "ON" or "OFF"),
            value = "setting_toggle:castAnimation",
            detail = "Play Bank Portal spellcast animation when depositing.",
            compact = true,
        },
        {
            title = "DEPOSIT RUNE COST: " .. (s.costEnabled and (tostring(s.costAmount) .. " " .. tostring(s.costRune)) or "FREE"),
            value = "setting_toggle:costEnabled",
            detail = "Toggle rune requirement for backpack deposit.",
            compact = true,
        },
        {
            title = "TRASH RUNE COST: " .. (s.trashCostEnabled and (tostring(s.trashCostAmount) .. " " .. tostring(s.trashCostRune)) or "FREE"),
            value = "setting_toggle:trashCostEnabled",
            detail = "Toggle rune requirement for trash container incineration.",
            compact = true,
        },
    }

    return {
        status = "Organiser Settings",
        detail = "Choose a setting to toggle or cycle it.",
        rows = rows,
        poolRows = true,
        actionIds = {},
    }
end

local function advisor_view()
    local report, err = organiser.base_advisor_report()
    local rows = {
        back(),
    }

    if not report then
        return {
            status = "BASE STORAGE ADVISOR: SCAN FAILED",
            detail = err or "Failed to scan base storage.",
            rows = rows,
            actionIds = { "auto-organise", "deposit" },
        }
    end

    if #report.recommendations > 0 then
        rows[#rows + 1] = {
            heading = "Recommendations",
            compact = true,
        }
        for _, rec in ipairs(report.recommendations) do
            rows[#rows + 1] = {
                title = rec.title,
                value = "noop",
                detail = rec.detail,
                compact = true,
            }
        end
    else
        rows[#rows + 1] = {
            title = "ALL STATIONS & CATEGORIES HAVE STORAGE",
            value = "noop",
            detail = "Every detected workstation has nearby storage and all themes have dedicated capacity.",
            compact = true,
        }
    end

    if #report.workstations > 0 then
        rows[#rows + 1] = {
            heading = "Workstations",
            compact = true,
        }
        for _, ws in ipairs(report.workstations) do
            local status_text = ws.has_nearby_chest
                and string.format("%d m to chest [%s]", ws.chest_dist, ws.nearest_chest.label or "Unlabelled")
                or "NO NEARBY STORAGE (>10 m)"
            rows[#rows + 1] = {
                title = ws.station .. "  •  " .. status_text,
                value = "noop",
                detail = ws.has_nearby_chest
                    and string.format("Linked storage nearby at %d m. Dedicated theme: %s.", ws.chest_dist, ws.theme.name)
                    or string.format("Nearest chest is %d m away. Recommend placing %s nearby for %s.", ws.chest_dist, ws.theme.chest_type, ws.theme.label),
                compact = true,
            }
        end
    end

    rows[#rows + 1] = {
        heading = "Storage by category",
        compact = true,
    }
    for _, theme in ipairs(organiser.bank_themes()) do
        local stat = report.themes[theme.id]
        if stat then
            local pct_text = stat.chest_count > 0 and string.format("%d%% full", stat.util_pct or 0) or "No chest"
            rows[#rows + 1] = {
                title = string.format("%s  •  %d chest(s), %d stacks (%s)",
                    theme.name, stat.chest_count, stat.stored_stacks, pct_text),
                value = "noop",
                detail = string.format("Dedicated label: [%s]. Total capacity: %d slots across %d container(s).",
                    theme.label, stat.total_capacity, stat.chest_count),
                compact = true,
            }
        end
    end

    local rec_summary = #report.recommendations > 0
        and string.format("%d recommendation(s) available. Review above or run Auto-Organise.", #report.recommendations)
        or "Base storage is well-optimised. Run Auto-Organise to refresh sorting."

    local tier_label = report.granularity_tier and string.format(" (%s TIER)", tostring(report.granularity_tier):upper()) or ""
    return {
        status = string.format("BASE STORAGE ADVISOR  •  %d chest(s), %d station(s)%s",
            report.total_chests, #report.workstations, tier_label),
        detail = rec_summary,
        rows = rows,
        poolRows = true,
        actionIds = { "auto-organise", "deposit" },
    }
end

local function ensure_hud(state)
    local hud = package.loaded.rlm_organiser_hud
    if not hud and type(require) == "function" then
        local ok, loaded_hud = pcall(require, "rlm_organiser_hud")
        if ok and type(loaded_hud) == "table" then hud = loaded_hud end
    end
    if type(hud) == "table" and type(hud.start) == "function" then
        pcall(hud.start, state)
    end
    return hud
end

function M.start(state)
    local ready, reason = store.register("organiser", { file = "organiser.json" })
    if not ready then
        storage_error = reason or "Organiser settings could not be loaded."
        return false, storage_error
    end
    storage_error = nil
    local hud = ensure_hud(state)
    organiser.arm_hooks(hud)
    return true
end

function M.activate(state)
    if storage_error then
        return { status = "Organiser is unavailable.", detail = storage_error, rows = {} }
    end
    ensure_hud(state)

    local view
    if current_view == "advisor" then
        view = advisor_view()
    elseif current_view == "label_open" then
        view = label_open_view()
    elseif current_view == "locks" then
        view = locks_view()
    elseif current_view == "settings" then
        view = settings_view()
    elseif current_view == "nearby" then
        view = nearby_view(state)
    elseif current_view == "find_items" then
        view = find_items_view(state)
    elseif current_view == "chest_detail" then
        view = chest_detail_view(state)
    elseif current_view == "base_setup" then
        view = base_setup_view(state)
    else
        return overview_view(state)
    end
    view.poolRows, view.pinFirstRow = true, true
    return view
end

function M.select_row(state, value)
    local text = tostring(value or "")
    if text == "nav:overview" then
        current_view = "overview"
        return true
    elseif text == "nav:find_items" then
        current_view, find_page, last_message = "find_items", 1, nil
        return true
    elseif text == "nav:nearby" then
        current_view, nearby_page, last_message = "nearby", 1, nil
        return true
    elseif text == "nav:chest_detail" then
        current_view = "chest_detail"
        return true
    elseif text == "nav:base_setup" then
        current_view = "base_setup"
        return true
    elseif text == "nearby:previous" or text == "nearby:next" then
        nearby_page = math.max(1, nearby_page + (text == "nearby:next" and 1 or -1))
        return true
    elseif text == "find:previous" or text == "find:next" then
        find_page = math.max(1, find_page + (text == "find:next" and 1 or -1))
        return true
    elseif text == "chest_detail:previous" or text == "chest_detail:next" then
        chest_page = math.max(1, chest_page + (text == "chest_detail:next" and 1 or -1))
        return true
    elseif text:match("^inspect:%d+$") then
        local idx = tonumber(text:match("^inspect:(%d+)$"))
        local chest = idx and last_nearby_chests[idx] or nil
        if chest then
            selected_chest_key = chest.key
            selected_chest_slot = nil
            chest_page = 1
            last_message = nil
            current_view = "chest_detail"
        end
        return true
    elseif text:match("^find_hit:%d+$") then
        local idx = tonumber(text:match("^find_hit:(%d+)$"))
        selected_hit = idx and last_find_hits[idx] or nil
        return true
    elseif text:match("^chest_slot:%d+$") then
        selected_chest_slot = tonumber(text:match("^chest_slot:(%d+)$"))
        return true
    elseif text == "nav:label_open" then
        current_view = "label_open"
        return true
    elseif text == "nav:locks" then
        current_view = "locks"
        return true
    elseif text == "nav:settings" then
        current_view = "settings"
        return true
    elseif text == "nav:advisor" then
        current_view = "advisor"
        return true
    elseif text == "action:auto_organise" then
        local ok, message = organiser.auto_organise_base()
        last_message = message
        return true
    elseif text == "action:fill_unlabelled" then
        local ok, message = organiser.auto_organise_base({ force_replan = false })
        last_message = message
        return true
    elseif text == "action:replan_organise" then
        local ok, message = organiser.replan_organise_base()
        last_message = message
        return true
    elseif text == "action:sort_open" then
        local ok, message = organiser.sort_open_storage()
        last_message = message
        return true
    elseif text == "action:resort_nearby" then
        local ok, message = organiser.resort_nearby_storage()
        last_message = message
        return true
    elseif text == "action:toggle_trash_open" then
        local inv, actor = organiser.open_storage()
        if actor and engine.is_valid(actor) then
            local current = organiser.label_of(actor)
            local controller = engine.local_controller()
            if current == "Trash" then
                organiser.set_label(controller, actor, nil)
                last_message = "Trash label removed from container."
            else
                organiser.set_label(controller, actor, "Trash")
                last_message = "Container labelled Trash: will incinerate contents when closed."
            end
        end
        return true
    elseif text:match("^apply_label:") then
        local label = text:match("^apply_label:(.*)$")
        local inv, actor = organiser.open_storage()
        if actor and engine.is_valid(actor) then
            local controller = engine.local_controller()
            local target_label = (label == "CLEAR" or label == "") and nil or label
            organiser.set_label(controller, actor, target_label)
            last_message = target_label and ("Label applied: " .. target_label) or "Label cleared."
        else
            last_message = "No storage container open."
        end
        return true
    elseif text:match("^select_item_lock:") then
        selected_lock_item = text:match("^select_item_lock:(.*)$")
        return true
    elseif text == "action:clear_all_locks" then
        organiser.clear_all_locks()
        last_message = "All retention locks cleared."
        return true
    elseif text:match("^setting_toggle:") then
        local key = text:match("^setting_toggle:(.*)$")
        local s = organiser.settings()
        if key == "rangeMeters" then
            local next_range = find_next_preset(s.rangeMeters, REACH_PRESETS)
            organiser.set_setting("rangeMeters", next_range)
            last_message = "Reach distance set to " .. next_range .. " m."
        elseif key == "costEnabled" then
            organiser.set_setting("costEnabled", not s.costEnabled)
            last_message = "Deposit rune cost toggled: " .. (not s.costEnabled and "ENABLED" or "FREE")
        elseif key == "trashCostEnabled" then
            organiser.set_setting("trashCostEnabled", not s.trashCostEnabled)
            last_message = "Trash rune cost toggled: " .. (not s.trashCostEnabled and "ENABLED" or "FREE")
        elseif s[key] ~= nil and type(s[key]) == "boolean" then
            organiser.set_setting(key, not s[key])
            last_message = key .. " set to " .. tostring(not s[key])
        end
        return true
    end
    return false
end

function M.run_action(state, action_id, input)
    local text = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if action_id == "auto-organise" then
        local ok, message = organiser.auto_organise_base()
        last_message = message
        return ok, message
    elseif action_id == "fill-unlabelled" then
        local ok, message = organiser.auto_organise_base({ force_replan = false })
        last_message = message
        return ok, message
    elseif action_id == "replan-organise" then
        local ok, message = organiser.replan_organise_base()
        last_message = message
        return ok, message
    elseif action_id == "advisor" then
        current_view = "advisor"
        return true, "Switched to Base Storage Advisor."
    elseif action_id == "deposit" then
        local ok, message = organiser.deposit_backpack()
        last_message = message
        return ok, message
    elseif action_id == "sort-open" then
        local ok, message = organiser.sort_open_storage()
        last_message = message
        return ok, message
    elseif action_id == "resort-nearby" then
        local ok, message = organiser.resort_nearby_storage()
        last_message = message
        return ok, message
    elseif action_id == "label" then
        local inv, actor = organiser.open_storage()
        if not inv or not actor then
            return false, "Open a storage container in-game first."
        end
        local label = text
        if label == "" then
            return false, "Enter a label name (e.g. Ash Logs, All: Wood, Misc, Trash, or CLEAR)."
        end
        local target_label = (label:upper() == "CLEAR") and nil or label
        local controller = engine.local_controller()
        local ok, reason = organiser.set_label(controller, actor, target_label)
        if ok then
            local msg = target_label and ("Labelled container: " .. target_label) or "Container label cleared."
            last_message = msg
            return true, msg
        end
        return false, reason or "Failed to set label."
    elseif action_id == "lock" then
        local target = selected_lock_item
        if not target or target == "" then
            return false, "Select a carried item first from the list."
        end
        local count_val = text
        if count_val == "" then count_val = "all" end
        local ok, reason = organiser.set_lock(target, count_val)
        if ok then
            local msg = string.format("Retention lock for %s set to %s.", target, tostring(count_val))
            last_message = msg
            return true, msg
        end
        return false, reason or "Failed to set lock."
    elseif action_id == "trash" then
        local inv, actor = organiser.open_storage()
        if not inv or not actor then
            return false, "Open a storage container in-game first."
        end
        local current = organiser.label_of(actor)
        local controller = engine.local_controller()
        if current == "Trash" then
            organiser.set_label(controller, actor, nil)
            last_message = "Trash label removed from container."
            return true, "Trash label removed."
        else
            organiser.set_label(controller, actor, "Trash")
            last_message = "Container marked as Trash (will incinerate contents on close)."
            return true, "Marked as Trash container."
        end
    elseif action_id == "search-items" then
        if not chest_explorer then return false, "Chest explorer service is not loaded." end
        search_query = text
        find_page = 1
        selected_hit = nil
        current_view = "find_items"
        local hits, meta = chest_explorer.search_items(search_query, { limit = 80 })
        last_find_hits = hits
        for _, h in ipairs(hits) do
            if h.kind == "chest" then
                selected_hit = h
                break
            end
        end
        if not selected_hit and hits[1] then selected_hit = hits[1] end
        local q_label = search_query ~= "" and ('"' .. search_query .. '"') or "all items"
        local msg = ("%d match(es) for %s across %d containers."):format(#hits, q_label, meta.chests or 0)
        last_message = msg
        return true, msg
    elseif action_id == "clear-search" then
        search_query = ""
        find_page = 1
        selected_hit = nil
        last_message = nil
        return true, "Showing all nearby chest items."
    elseif action_id == "inspect-hit-chest" then
        if not selected_hit or not selected_hit.chest_key then
            return false, "Select a chest search result first."
        end
        selected_chest_key = selected_hit.chest_key
        selected_chest_slot = selected_hit.slot
        chest_page = 1
        last_message = nil
        current_view = "chest_detail"
        return true, "Opened chest inspector for " .. (selected_hit.chest_title or "chest") .. "."
    elseif action_id == "pin-chest" then
        if not chest_explorer then return false, "Chest explorer service is not loaded." end
        local target = nil
        if current_view == "chest_detail" and selected_chest_key then
            target = find_chest_by_key(accessible_chests(), selected_chest_key)
        elseif selected_hit and selected_hit.kind == "chest" then
            target = selected_hit
        end
        local ok, msg = chest_explorer.pin_chest(target)
        last_message = msg
        return ok, msg
    elseif action_id == "withdraw-one" or action_id == "withdraw-stack" then
        if not chest_explorer then return false, "Chest explorer service is not loaded." end
        local target_hit = nil
        if current_view == "chest_detail" and selected_chest_key and selected_chest_slot ~= nil then
            local chest = find_chest_by_key(accessible_chests(), selected_chest_key)
            if chest then
                for _, item in ipairs(chest.slots or {}) do
                    if item.slot == selected_chest_slot then
                        target_hit = {
                            kind = "chest",
                            chest_key = chest.key,
                            item_name = item.name,
                            item_id = item.id,
                            count = item.count,
                            slot = item.slot,
                            chest_title = chest.title,
                            chest_actor = chest.actor,
                            chest_inv = chest.inv,
                        }
                        break
                    end
                end
            end
        elseif selected_hit then
            target_hit = selected_hit
        end
        if not target_hit then
            return false, "Select a chest item first."
        end
        local amount = (action_id == "withdraw-one") and 1 or nil
        local ok, msg = chest_explorer.withdraw_to_backpack(target_hit, amount, function(done_ok, done_err)
            if done_ok then
                last_message = ("Withdrew %s from %s."):format(target_hit.item_name or "item", target_hit.chest_title or "chest")
            else
                last_message = tostring(done_err or "Withdrawal failed.")
            end
        end)
        last_message = msg
        return ok, msg
    end

    return false, "Unknown action: " .. tostring(action_id)
end

function M.stop()
    local hud = package.loaded.rlm_organiser_hud
    if type(hud) == "table" and type(hud.stop) == "function" then
        pcall(hud.stop)
    end
    organiser.stop()
    return true
end

return M
