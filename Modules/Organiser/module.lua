-- View and action adapter for the Organiser module.
-- Discovers storage, presents label and lock workflows, and runs deposit/trash actions.

local engine = require("rlm_engine")
local log = require("rlm_log")
local store = require("rlm_store")

local M = { VERSION = "0.3.4" }
local source = debug.getinfo(1, "S").source
local module_dir = assert(source:match("^@(.*)[/\\][^/\\]+$"), "Organiser module path is unavailable")
local organiser = assert(loadfile(module_dir .. "/rlm_organiser.lua"))()
assert(organiser.VERSION == M.VERSION, "Organiser service version mismatch")
local hud = assert(loadfile(module_dir .. "/rlm_organiser_hud.lua"))(organiser)

local current_view = "overview"
local selected_lock_item = nil
local last_message = "Manage container labels, retention locks, and quick deposit."
local storage_error

local REACH_PRESETS = { 10, 20, 30, 40, 60, 100 }

local function find_next_preset(current, presets)
    for index, val in ipairs(presets) do
        if val == current then
            return presets[(index % #presets) + 1]
        end
    end
    return presets[1]
end

local function overview_view()
    local s = organiser.settings()
    local controller = engine.local_controller()
    local pawn = controller and controller.Pawn
    local pawn_pos = pawn and engine.is_valid(pawn) and pawn:K2_GetActorLocation() or nil

    local _, open_actor = organiser.open_storage()
    local nearby = pawn_pos and organiser.labelled_storage_in_reach(pawn_pos, s) or {}

    local rows = {}
    if open_actor and engine.is_valid(open_actor) then
        local open_label = organiser.label_of(open_actor)
        rows[#rows + 1] = {
            title = "OPEN STORAGE: " .. (open_label and ("[" .. open_label .. "]") or "UNLABELLED"),
            value = "nav:label_open",
            detail = "Open storage is ready. Click to label this container.",
            compact = true,
        }
        rows[#rows + 1] = {
            title = "LABEL THIS CONTAINER  >",
            value = "nav:label_open",
            detail = "Select a label suggestion or type a custom label.",
            compact = true,
        }
        rows[#rows + 1] = {
            title = "SORT OPEN CONTAINER",
            value = "action:sort_open",
            detail = "Consolidate partial stacks and sort contents inside this container.",
            compact = true,
        }
        rows[#rows + 1] = {
            title = (open_label == "Trash") and "REMOVE TRASH LABEL" or "MARK AS TRASH (INCINERATOR)",
            value = "action:toggle_trash_open",
            detail = "Trash containers delete their contents when closed.",
            compact = true,
        }
    end

    if #nearby > 0 then
        if #nearby >= 2 then
            rows[#rows + 1] = {
                title = "RESORT ALL NEARBY CHESTS",
                value = "action:resort_nearby",
                detail = "Redistribute misplaced items across all labelled chests within reach.",
                compact = true,
            }
        end
        for _, st in ipairs(nearby) do
            local dist_m = math.floor(st.distance or 0)
            local label_tag = st.label or "Unlabelled"
            rows[#rows + 1] = {
                title = label_tag .. "  •  " .. dist_m .. " m away",
                value = "inspect:" .. label_tag,
                detail = "Labelled container within reach (" .. tostring(s.rangeMeters) .. " m max).",
                compact = true,
            }
        end
    else
        rows[#rows + 1] = {
            title = "NO LABELLED STORAGE IN REACH",
            value = "noop",
            detail = "Open any built chest or container and set a label to enable deposit.",
            compact = true,
        }
    end

    rows[#rows + 1] = {
        title = "AUTO-ORGANISE BASE (FULL RE-PLAN & RENAME)  *",
        value = "action:auto_organise",
        detail = "Full base bank sort: re-plan, rename non-Trash chests (overriding existing names), and re-sort.",
        compact = true,
    }
    rows[#rows + 1] = {
        title = "FILL UNLABELLED CHESTS ONLY",
        value = "action:fill_unlabelled",
        detail = "Assign bank roles only to unlabelled chests while keeping existing names, then re-sort.",
        compact = true,
    }
    rows[#rows + 1] = {
        title = "STORAGE & WORKSTATION ADVISOR  >",
        value = "nav:advisor",
        detail = "Inspect base layout, check workstation storage proximity, and view chest recommendations.",
        compact = true,
    }
    rows[#rows + 1] = {
        title = "CARRIED ITEMS & LOCKS  >",
        value = "nav:locks",
        detail = "View carried items and configure retention keep amounts.",
        compact = true,
    }
    rows[#rows + 1] = {
        title = "SETTINGS  >",
        value = "nav:settings",
        detail = "Configure deposit reach, rune costs, trash rules, and animations.",
        compact = true,
    }
    local status = string.format("STORAGE ORGANISER  •  %d labelled container(s) in reach (%d m)",
        #nearby, s.rangeMeters or 40)
    return {
        status = status,
        detail = last_message,
        rows = rows,
    }
end

local function label_open_view()
    local open_inv, open_actor = organiser.open_storage()
    local rows = {
        {
            title = "<  BACK TO OVERVIEW",
            value = "nav:overview",
            detail = "Return to the storage organiser overview.",
            compact = true,
        },
    }

    if not open_inv or not open_actor then
        rows[#rows + 1] = {
            title = "NO STORAGE OPEN",
            value = "nav:overview",
            detail = "Open a chest or container in-game to assign labels.",
            compact = true,
        }
        return {
            status = "LABEL CONTAINER: NO STORAGE OPEN",
            detail = "Please open a storage container first.",
            rows = rows,
        }
    end

    local current = organiser.label_of(open_actor)
    local suggestions = organiser.label_suggestions(open_inv)

    rows[#rows + 1] = {
        title = "CURRENT LABEL: " .. (current and ("[" .. current .. "]") or "NONE"),
        value = "noop",
        detail = "Current label applied to this container.",
        compact = true,
    }

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
        title = "SORT OPEN CONTAINER",
        value = "action:sort_open",
        detail = "Consolidate partial stacks and sort contents inside this container.",
        compact = true,
    }
    rows[#rows + 1] = {
        title = "CLEAR LABEL",
        value = "apply_label:CLEAR",
        detail = "Remove any label from this container.",
        compact = true,
    }

    return {
        status = "LABEL OPEN STORAGE  •  " .. (current or "Unlabelled"),
        detail = "Click a suggestion below or type a label into the input field and press LABEL STORAGE.",
        rows = rows,
    }
end

local function locks_view()
    local rows = {
        {
            title = "<  BACK TO OVERVIEW",
            value = "nav:overview",
            detail = "Return to the storage organiser overview.",
            compact = true,
        },
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
        value = "action:clear_all_locks",
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
    }
end

local function settings_view()
    local s = organiser.settings()
    local rows = {
        {
            title = "<  BACK TO OVERVIEW",
            value = "nav:overview",
            detail = "Return to the storage organiser overview.",
            compact = true,
        },
        {
            title = "AUTO-LOAD ON CHEST OPEN: " .. (s.autoOpenOnStorage ~= false and "ON" or "OFF"),
            value = "setting_toggle:autoOpenOnStorage",
            detail = "Show Organiser when opening built storage.",
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
        status = "ORGANISER SETTINGS",
        detail = "Click any setting row to toggle or cycle values.",
        rows = rows,
    }
end

local function advisor_view()
    local report, err = organiser.base_advisor_report()
    local rows = {
        {
            title = "<  BACK TO OVERVIEW",
            value = "nav:overview",
            detail = "Return to the storage organiser overview.",
            compact = true,
        },
        {
            title = "AUTO-ORGANISE BASE (BANK SORT)  *",
            value = "action:auto_organise",
            detail = "Automatically assign bank-sorted roles to chests and re-sort all base storage.",
            compact = true,
        },
    }

    if not report then
        rows[#rows + 1] = {
            title = "ADVISOR SCAN FAILED",
            value = "noop",
            detail = err or "Could not scan local base storage.",
            compact = true,
        }
        return {
            status = "BASE STORAGE ADVISOR: SCAN FAILED",
            detail = err or "Failed to scan base storage.",
            rows = rows,
        }
    end

    if #report.recommendations > 0 then
        rows[#rows + 1] = {
            title = string.format("RECOMMENDED ACTIONS (%d):", #report.recommendations),
            value = "noop",
            detail = "Suggested chest placements and label reassignments for optimal base flow.",
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
            title = string.format("DETECTED WORKSTATIONS (%d):", #report.workstations),
            value = "noop",
            detail = "Crafting and processing stations detected within base reach radius.",
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
        title = "BANK THEME STORAGE BREAKDOWN:",
        value = "noop",
        detail = "Item stack allocation across bank-sorted themes.",
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
    }
end

function M.start(state)
    local ready, reason = store.register("organiser", { file = "organiser.json" })
    if not ready then
        storage_error = reason or "Organiser settings could not be loaded."
        return false, storage_error
    end
    storage_error = nil
    local started, hud_error = hud.start(state)
    if not started then
        log.warn("Organiser dock unavailable: " .. tostring(hud_error))
    end
    organiser.arm_hooks(hud)
    return true
end

function M.activate()
    if storage_error then
        return { status = "Organiser is unavailable.", detail = storage_error, rows = {} }
    elseif current_view == "advisor" then
        return advisor_view()
    elseif current_view == "label_open" then
        return label_open_view()
    elseif current_view == "locks" then
        return locks_view()
    elseif current_view == "settings" then
        return settings_view()
    end
    return overview_view()
end

function M.select_row(state, value)
    if storage_error then return false end
    local text = tostring(value or "")
    if text == "nav:overview" then
        current_view = "overview"
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
    if storage_error then return false, storage_error end
    local text = tostring(input or ""):gsub("^%s+", ""):gsub("%s+$", "")

    if action_id == "auto-organise" then
        local ok, message = organiser.auto_organise_base()
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
    end

    return false, "Unknown action: " .. tostring(action_id)
end

function M.stop()
    organiser.stop()
    hud.stop()
    return true
end

return M
