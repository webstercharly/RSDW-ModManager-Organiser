"""Mocked Lua tests for rlm_chest_explorer, Organiser Explorer views, and Chest Dock tabs."""
from __future__ import annotations

import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

_lupa_path = os.environ.get("RSDW_LUPA_PATH")
if _lupa_path:
    sys.path.insert(0, _lupa_path)
try:
    from lupa.lua54 import LuaRuntime
except ImportError:  # pragma: no cover
    LuaRuntime = None


def _setup_runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    g = lua.globals()
    g.SCRIPTS_DIR = (ROOT / "Modules" / "Organiser").as_posix()
    g.MODULE_REL_PATH = "Modules/Organiser/module.lua"
    os.chdir(ROOT)
    lua.execute(r"""
        package.path = SCRIPTS_DIR .. "/?.lua;" .. package.path
        _G.FText = function(s) return tostring(s) end
        _G.FName = function(s) return tostring(s) end

        local fake_timers = {}
        local fake_clock = 100.0
        os.clock = function() return fake_clock end
        _G.__advance_clock = function(dt)
            fake_clock = fake_clock + dt
            local pending = fake_timers
            fake_timers = {}
            for _, t in ipairs(pending) do
                if fake_clock >= t.due then
                    t.cb()
                else
                    fake_timers[#fake_timers + 1] = t
                end
            end
        end

        package.loaded.rlm_log = {
            info = function() end,
            warn = function() end,
            debug = function() end,
        }
        package.loaded.rlm_async = {
            after = function(sec, cb)
                fake_timers[#fake_timers + 1] = { due = fake_clock + (sec or 0), cb = cb }
                return true
            end,
        }
        package.loaded.rlm_ui_kit = {
            style_button_label = function() return true end,
        }
        package.loaded.rlm_store = {
            get = function() return {} end,
            save = function() return true end,
        }
        package.loaded.rlm_row_icons = {
            load = function() return nil end,
            path = function(name)
                if tostring(name or ""):lower():find("crucible", 1, true) then
                    return "/Game/Art/UI/Icons/Icons_0_12_UmS/Icons/T_Icon_Nightmare_Crucible_Keys_01_Red.T_Icon_Nightmare_Crucible_Keys_01_Red"
                end
                return nil
            end,
        }

        _G.__PIN_CALLS = {}
        package.loaded.rlm_minimap = {
            claim = function(owner) return "claimed:" .. tostring(owner) end,
            show_destinations = function(entries, color, opts)
                _G.__PIN_CALLS[#_G.__PIN_CALLS + 1] = { entries = entries, color = color, opts = opts }
                return true
            end,
            clear_destinations = function() return true end,
        }
    """)
    return lua


@unittest.skipIf(LuaRuntime is None, "lupa is not installed")
class ChestExplorerTests(unittest.TestCase):
    def test_search_plan_withdraw_pin_and_tab_switch(self):
        lua = _setup_runtime()
        out = lua.execute(r"""
            local function is_valid(o) return type(o) == "table" and o._valid ~= false end
            local state = {
                is_remote = false,
                moves = {},
                splits = {},
            }

            local function make_item(id, name, count, max_stack)
                return {
                    _valid = true,
                    IsValid = function() return true end,
                    id = id,
                    name = name,
                    count = count,
                    maxStack = max_stack or 50,
                    ItemData = {
                        _valid = true,
                        IsValid = function() return true end,
                        GetFullName = function() return "ItemData /Game/Items/" .. id .. "." .. id end,
                        Name = { ToString = function() return name end },
                        MaxStackSize = max_stack or 50,
                    },
                    Count = count,
                }
            end

            local function make_inv(name, max_slots, initial_items, pages)
                local items_by_slot = {}
                for slot, item in pairs(initial_items or {}) do
                    items_by_slot[slot] = item
                end
                local inv
                inv = {
                    _valid = true,
                    _addr = "inv_" .. name,
                    MaxSlotCount = max_slots,
                    NumberOfQuickActionSlots = 2,
                    IsValid = function() return true end,
                    GetAddress = function() return inv._addr end,
                    GetFullName = function() return "InventoryComponent /Game/World." .. name end,
                    GetOwner = function() return inv._owner end,
                    _items = items_by_slot,
                }
                if pages then
                    inv.InventoryPages = {
                        ForEach = function(_, cb)
                            for i, p in ipairs(pages) do
                                cb(i, { get = function() return p end })
                            end
                        end
                    }
                end
                inv.ItemSlots = {
                    ForEach = function(_, cb)
                        for slot = 0, max_slots - 1 do
                            local item = items_by_slot[slot]
                            if item then
                                cb(slot + 1, { get = function() return item end })
                            end
                        end
                    end,
                }
                return inv
            end

            -- Slots 0-1 QuickAction; 2-4 Backpack (SlotType 1); 5-6 Runes (SlotType 2)
            local p_inv = make_inv("player", 7, {
                [0] = make_item("Weapon_Sword", "Sword", 1, 1),
                [2] = make_item("ITEM_Ore_Iron", "Iron Ore", 45, 50),
                [3] = make_item("ITEM_Wood_Ash", "Ash Logs", 10, 50),
            }, {
                { SlotType = 1, NumSlots = 3 }, -- slots 2, 3, 4
                { SlotType = 2, NumSlots = 2 }, -- slots 5, 6
            })

            local pc
            pc = {
                _valid = true,
                IsValid = function() return true end,
                InventoryComponent = p_inv,
                GetCharacterGuid = function() return "guid-me" end,
                InventoryController = {
                    _valid = true,
                    IsValid = function() return true end,
                    MoveItemBetweenInventories = function(_, src, src_slot, dst, dst_slot)
                        state.moves[#state.moves + 1] = { src_slot = src_slot, dst_slot = dst_slot }
                        local it = src._items[src_slot]
                        if not it then return false end
                        src._items[src_slot] = nil
                        dst._items[dst_slot] = it
                        return true
                    end,
                    SplitAndPutStack = function(_, src, src_slot, count, dst, dst_slot)
                        state.splits[#state.splits + 1] = { src_slot = src_slot, dst_slot = dst_slot, count = count }
                        local src_it = src._items[src_slot]
                        if not src_it then return false end
                        src_it.Count = src_it.Count - count
                        src_it.count = src_it.Count
                        if src_it.Count <= 0 then src._items[src_slot] = nil end
                        if dst._items[dst_slot] then
                            dst._items[dst_slot].Count = dst._items[dst_slot].Count + count
                            dst._items[dst_slot].count = dst._items[dst_slot].Count
                        else
                            dst._items[dst_slot] = make_item(src_it.id, src_it.name, count, src_it.maxStack)
                        end
                        return true
                    end,
                },
            }
            p_inv._owner = pc

            local pawn = {
                _valid = true,
                IsValid = function() return true end,
                HasAuthority = function() return not state.is_remote end,
                K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
            }

            package.loaded.rlm_engine = {
                is_valid = is_valid,
                full_name = function(o) return o and o.GetFullName and o:GetFullName() or "" end,
                local_controller = function() return pc end,
                local_pawn = function() return pawn end,
                real_time_seconds = function() return os.clock() end,
                local_generation_allowed = function()
                    if state.is_remote then return false, "Client" end
                    return true, "Standalone"
                end,
                object_call = function(o, fn)
                    return o and o[fn] and o[fn](o) or nil
                end,
            }

            local c1_inv = make_inv("c1", 16, {
                [0] = make_item("ITEM_Ore_Iron", "Iron Ore", 20, 50),
                [4] = make_item("ITEM_Resources_Key_NC_UmS_03", "Crucible Engram of the Hounded", 1, 1),
            })
            local c1_actor = {
                _valid = true, IsValid = function() return true end,
                GetAddress = function() return "act_c1" end,
                GetFullName = function() return "BP_BaseBuilding_Chest_Iron_C /Game/World.C1" end,
                GetCustomName = function() return { ToString = function() return "" end } end,
                GetBuildingName = function() return { ToString = function() return "Iron Chest" end } end,
                pos = { X = 300, Y = 0, Z = 0 },
                LinkedInventoryComponent = { _valid = true, IsValid = function() return true end, bIsLocked = false },
            }
            c1_inv._owner = c1_actor

            local c2_inv = make_inv("c2", 16, {
                [2] = make_item("ITEM_Resources_Key_NC_UmS_02", "Crucible Engram of Betrayal", 2, 5),
            })
            local c2_actor = {
                _valid = true, IsValid = function() return true end,
                GetAddress = function() return "act_c2" end,
                GetFullName = function() return "BP_BaseBuilding_Crate_C /Game/World.C2" end,
                GetCustomName = function() return { ToString = function() return "Vault Keys" end } end,
                GetBuildingName = function() return { ToString = function() return "Crate" end } end,
                pos = { X = 900, Y = 0, Z = 0 },
                LinkedInventoryComponent = { _valid = true, IsValid = function() return true end, bIsLocked = false },
            }
            c2_inv._owner = c2_actor

            local current_api_inv = c1_inv
            local fake_api = {
                _valid = true,
                IsValid = function() return true end,
                GetInventoryComponent = function() return current_api_inv end,
                SetInventory = function(_, target) current_api_inv = target end,
            }

            local org = require("rlm_organiser")
            org.all_storage_in_reach = function()
                return {
                    { actor = c1_actor, inv = c1_inv, label = nil, native_name = "", distance = 3, pos = c1_actor.pos, maxSlots = 16 },
                    { actor = c2_actor, inv = c2_inv, label = "All: Keys", native_name = "Vault Keys", distance = 9, pos = c2_actor.pos, maxSlots = 16 },
                }
            end
            org.open_storage = function()
                return current_api_inv, current_api_inv._owner, fake_api, nil
            end
            org.read_slots = function(inv)
                local arr = {}
                local keys = {}
                for k in pairs(inv._items) do keys[#keys + 1] = k end
                table.sort(keys)
                for _, k in ipairs(keys) do
                    local it = inv._items[k]
                    arr[#arr + 1] = { slot = k, id = it.id, name = it.name, count = it.count, maxStack = it.maxStack }
                end
                return arr
            end

            local ce = require("rlm_chest_explorer")

            -- 1. Container titles resolve cleanly (building name vs role + native name)
            local chests = ce.nearby_chests()
            assert(#chests == 2)
            assert(chests[1].title == "Iron Chest", "got: " .. chests[1].title)
            assert(chests[2].title == "Vault Keys (All: Keys)", "got: " .. chests[2].title)

            -- 2. Search across nearby chests finds both Crucibles with icon
            local hits, meta = ce.search_items("crucible")
            assert(#hits == 2 and meta.chests == 2)
            assert(hits[1].icon and hits[1].icon:find("Crucible_Keys", 1, true))

            -- 3. Stack merge top-up plan (Iron Ore 45/50 in slot 2 <- 20 in c1 -> moves 5 via split into slot 2)
            local merge_plan = ce.plan_withdraw_to_backpack(c1_inv, 0, p_inv, 20)
            assert(merge_plan.ok and merge_plan.dst_slot == 2 and merge_plan.count == 5 and merge_plan.is_split)

            -- 4. Empty backpack slot plan for Crucible -> slot 4 (never quick-action 0..1 or runes 5..6)
            local ok_w1, msg_w1 = ce.withdraw_to_backpack(hits[1], 1)
            assert(ok_w1, msg_w1)
            assert(p_inv._items[4] and p_inv._items[4].id == "ITEM_Resources_Key_NC_UmS_03")
            assert(#state.moves == 1 and state.moves[1].dst_slot == 4)

            -- 5. Backpack items page now full (slots 2,3,4 occupied) -> new item withdraw MUST refuse cleanly (no floor drop, no runes page leak)
            local ok_full, msg_full = ce.withdraw_to_backpack(hits[2], 1)
            assert(not ok_full)
            assert(msg_full:find("full", 1, true))

            -- 6. Pin chest calls minimap claim + show_destinations
            local ok_pin, msg_pin = ce.pin_chest(hits[2])
            assert(ok_pin and #_G.__PIN_CALLS == 1)
            assert(_G.__PIN_CALLS[1].opts.owner == "claimed:chest_explorer")

            -- 7. CE-03 native open chest tab switch verifies target inventory
            local ok_sw = ce.switch_open_chest(fake_api, c2_inv)
            assert(ok_sw and current_api_inv == c2_inv)

            -- 8. Privately locked chest blocks withdraw on RemoteClient
            state.is_remote = true
            c2_actor.OwnershipComponent = {
                _valid = true, IsValid = function() return true end,
                bIsPrivatelyOwned = true,
                IsPrivatelyLockedFromPlayer = function() return true end,
            }
            local ok_priv, msg_priv = ce.withdraw_to_backpack(hits[2], 1)
            assert(not ok_priv and msg_priv:find("privately locked", 1, true))

            -- 9. Organiser module integration: search-items, find_items view, inspect-hit-chest -> chest_detail
            local mod = assert(loadfile(MODULE_REL_PATH))()
            local mod_org = package.loaded.rlm_organiser
            mod_org.all_storage_in_reach = org.all_storage_in_reach
            mod_org.open_storage = org.open_storage
            mod_org.read_slots = org.read_slots
            local ok_act, act_msg = mod.run_action({}, "search-items", "Crucible")
            assert(ok_act and act_msg:find("match", 1, true), tostring(act_msg))
            local fv = mod.activate({})
            assert(fv.status == "Find Items" and #fv.rows >= 2)
            local ok_insp, insp_msg = mod.run_action({}, "inspect-hit-chest", "")
            assert(ok_insp, tostring(insp_msg))
            local dv = mod.activate({})
            assert(dv.status == "Vault Keys (All: Keys)", tostring(dv.status))
            package.loaded.rlm_organiser = org
            package.loaded.rlm_chest_explorer = ce

            -- 10. OSRS Bank view model: count formatting, colors, ∞ All Chests, search override, tab slicing
            assert(ce.format_osrs_count(1) == "")
            assert(ce.format_osrs_count(540) == "540")
            assert(ce.format_osrs_count(125000) == "125K")
            assert(ce.format_osrs_count(12000000) == "12M")
            assert(ce.osrs_stack_color(500).G > 0.8 and ce.osrs_stack_color(500).B < 0.4) -- OSRS yellow
            assert(ce.osrs_stack_color(120000).R == 1.0 and ce.osrs_stack_color(120000).B == 1.0) -- white >=100K
            assert(ce.item_monogram("Crucible Engram") == "CE")

            local vm_all = ce.build_bank_view_model(chests, "__all__", "")
            assert(vm_all.use_all == true and vm_all.total_chests == 2)
            assert(#vm_all.entries >= 2 and vm_all.max_slots == 32)
            local vm_tab = ce.build_bank_view_model(chests, chests[2].key, "")
            assert(not vm_tab.use_all and vm_tab.tabs[2].short_label == "KEYS")
            local vm_search = ce.build_bank_view_model(chests, chests[1].key, "betrayal")
            assert(vm_search.use_all == true and #vm_search.entries == 1)
            assert(vm_search.entries[1].item_name == "Crucible Engram of Betrayal")

            -- 11. Verify all 14 OSRS Bank art textures exist on disk
            local expected_art = {
                "osrs_bank_frame.png", "osrs_bank_stone_bg.png", "osrs_bank_tab_idle.png",
                "osrs_bank_tab_active.png", "osrs_bank_slot.png", "osrs_bank_slot_hot.png",
                "osrs_bank_btn_stone.png", "osrs_bank_btn_red.png", "osrs_bank_infinity.png",
                "osrs_bank_deposit.png", "osrs_bank_search.png", "osrs_bank_wrench.png",
                "osrs_bank_pin.png", "osrs_bank_close.png",
            }
            for _, fname in ipairs(expected_art) do
                local f = io.open("Modules/Organiser/art/" .. fname, "rb")
                assert(f, "missing Modules/Organiser/art/" .. fname)
                f:close()
            end

            -- 12. Full OSRS Bank HUD direct-CanvasPanel render -> layout -> refresh -> click -> close lifecycle
            local closed_api = false
            fake_api.CloseCurrentInventory = function() closed_api = true end
            local docked_pos = nil
            local function make_widget(cls)
                local w = {
                    _valid = true, _cls = cls, _vis = 4, _children = {},
                    IsValid = function(self) return self._valid end,
                    GetFullName = function(self) return cls .. " /Engine/Transient." .. cls .. "_" .. tostring(self) end,
                    GetClass = function(self) return { GetFName = function() return { ToString = function() return self._cls end } end } end,
                    SetVisibility = function(self, v) self._vis = v end,
                    GetVisibility = function(self) return self._vis end,
                    AddChild = function(self, ch) self._children[#self._children + 1] = ch; return {} end,
                    AddChildToVerticalBox = function(self, ch)
                        self._children[#self._children + 1] = ch
                        ch.Slot = { SetPadding = function() end, SetHorizontalAlignment = function() end, SetSize = function() end }
                        return ch.Slot
                    end,
                    AddChildToHorizontalBox = function(self, ch)
                        self._children[#self._children + 1] = ch
                        return { SetPadding = function() end, SetSize = function() end, SetVerticalAlignment = function() end, SetHorizontalAlignment = function() end }
                    end,
                    AddChildToOverlay = function(self, ch) self._children[#self._children + 1] = ch; return { SetPadding = function() end, SetHorizontalAlignment = function() end, SetVerticalAlignment = function() end } end,
                    AddChildToUniformGrid = function(self, ch) self._children[#self._children + 1] = ch; return { SetPadding = function() end } end,
                    AddChildToCanvas = function(self, ch)
                        self._children[#self._children + 1] = ch
                        ch.Slot = {
                            SetAutoSize = function() end, SetZOrder = function() end,
                            SetAnchors = function() end, SetAlignment = function() end,
                            SetPosition = function(_, p) docked_pos = p end,
                            SetSize = function() end,
                        }
                        return ch.Slot
                    end,
                    GetChildrenCount = function(self) return #self._children end,
                    GetChildAt = function(self, i) return self._children[i + 1] end,
                    SetBrushColor = function() end,
                    SetBrush = function() end,
                    SetBrushFromTexture = function() end,
                    SetPadding = function() end,
                    SetClipping = function() end,
                    SetShadowOffset = function() end,
                    SetShadowColorAndOpacity = function() end,
                    SetText = function() end,
                    SetColorAndOpacity = function() end,
                    SetFont = function() end,
                    SetDesiredSizeOverride = function() end,
                    SetWidthOverride = function() end,
                    SetHeightOverride = function() end,
                    SetHintText = function() end,
                    SetRenderOpacity = function() end,
                    SetIsSelectable = function() end,
                    SetShouldSelectUponReceivingFocus = function() end,
                    SetIsFocusable = function() end,
                    SetLabelText = function() end,
                    RemoveFromParent = function() end,
                    Background = { OutlineSettings = {} },
                    WidgetStyle = { BackgroundColor = {}, ForegroundColor = {}, FocusedForegroundColor = {}, TextStyle = { Font = { Size = 12 } } },
                    Font = { Size = 12 },
                }
                return w
            end
            local host_canvas = make_widget("CanvasPanel")
            local vert_nav = make_widget("VerticalNavigation")
            vert_nav.Slot = { GetPosition = function() return { X = 635, Y = 48 } end, GetSize = function() return { X = 630, Y = 619 } end }
            local open_panel = make_widget("WBP_WorldActorInventory_MainPanel_C")
            open_panel.WidgetTree = { RootWidget = host_canvas }
            open_panel.VerticalNavigation = vert_nav

            local wbl = {
                _valid = true, IsValid = function() return true end,
                Create = function() return make_widget("WBP_DomAllCapsButton") end,
            }
            _G.StaticFindObject = function(path)
                if path == "/Script/UMG.Default__WidgetBlueprintLibrary" then return wbl end
                return { _valid = true, _path = path, IsValid = function() return true end }
            end
            _G.StaticConstructObject = function(cls)
                return make_widget((cls._path or "Widget"):match("([^.]+)$") or "Widget")
            end
            _G.LoadAsset = function() end
            _G.FindFirstOf = function() return nil end

            local bank = require("rlm_osrs_bank_hud")
            local amap = {}
            assert(bank.render(pc, open_panel, c2_inv, c2_actor, fake_api, org, ce, amap)) -- build_frame
            assert(bank.render(pc, open_panel, c2_inv, c2_actor, fake_api, org, ce, amap)) -- build_content
            assert(bank.render(pc, open_panel, c2_inv, c2_actor, fake_api, org, ce, amap)) -- flush_later -> ready
            assert(bank.render(pc, open_panel, c2_inv, c2_actor, fake_api, org, ce, amap)) -- refresh!
            assert(#host_canvas._children == 1, "expected OSRS root SizeBox mounted directly in host CanvasPanel")
            assert(docked_pos and docked_pos.X >= 660 and docked_pos.Y >= 40, "expected centered OSRS dock over VerticalNavigation")
            assert(vert_nav:GetVisibility() == 1, "expected VerticalNavigation hidden in OSRS mode")
            assert(#bank.state().ui.tiles == 56, "expected 8x7 (56) OSRS grid slots")
            assert(bank.handle_click("bank:qty:5", c2_inv, c2_actor, fake_api, org, ce))
            assert(bank.state().qty_mode == 5)
            assert(bank.handle_click("bank:close", c2_inv, c2_actor, fake_api, org, ce))
            assert(closed_api == true, "expected X close button to invoke CloseCurrentInventory")
            bank.stop()
            assert(vert_nav:GetVisibility() == 4, "expected VerticalNavigation restored to 4 on stop")

            -- 13. Deep chest tab stability & retention (>7 chests, bIsLocked switchover, distance jitter, auto-page)
            local deep_chests = {}
            local swap_dist = false
            for idx = 1, 12 do
                local dc_inv = { _valid = true, MaxSlotCount = 16, IsValid = function() return true end,
                    _items = { [0] = { id = "ITEM_Test_" .. idx, name = "Test Item " .. idx, count = idx * 3, maxStack = 99 } } }
                local dc_actor = {
                    _valid = true, _locked = (idx == 10),
                    GetAddress = function() return 9000 + idx end,
                    IsValid = function() return true end,
                    GetFullName = function() return "BP_Chest_" .. idx end,
                    GetCustomName = function() return idx == 10 and "Deep Gems" or "" end,
                    GetBuildingName = function() return "Iron Chest" end,
                    K2_GetActorLocation = function() return { X = idx * 200, Y = 0, Z = 0 } end,
                    LinkedInventoryComponent = {
                        _valid = true, IsValid = function() return true end,
                        bIsLocked = (idx == 10),
                    },
                }
                dc_inv._owner = dc_actor
                deep_chests[idx] = {
                    actor = dc_actor, inv = dc_inv,
                    label = idx == 2 and "All: Wood" or nil,
                    native_name = idx == 10 and "Deep Gems" or "",
                    distance = idx * 2, pos = { X = idx * 200, Y = 0, Z = 0 }, maxSlots = 16,
                }
            end
            org.all_storage_in_reach = function(_, _, opts)
                local list = {}
                for idx, entry in ipairs(deep_chests) do
                    local allow = not entry.actor.LinkedInventoryComponent.bIsLocked
                    if not allow and type(opts) == "table" then
                        if opts.open_actor == entry.actor or opts.keep_actor == entry.actor then allow = true end
                        for _, ka in ipairs(opts.keep_actors or {}) do
                            if ka == entry.actor then allow = true end
                        end
                    end
                    if allow then
                        local copy = {
                            actor = entry.actor, inv = entry.inv, label = entry.label,
                            native_name = entry.native_name,
                            distance = swap_dist and (30 - entry.distance) or entry.distance,
                            pos = entry.pos, maxSlots = entry.maxSlots,
                        }
                        list[#list + 1] = copy
                    end
                end
                table.sort(list, function(a, b) return a.distance < b.distance end)
                return list
            end
            current_api_inv = deep_chests[10].inv
            org.open_storage = function() return current_api_inv, current_api_inv._owner, fake_api, open_panel end
            assert(bank.render(pc, open_panel, deep_chests[10].inv, deep_chests[10].actor, fake_api, org, ce, amap))
            assert(bank.render(pc, open_panel, deep_chests[10].inv, deep_chests[10].actor, fake_api, org, ce, amap))
            assert(bank.render(pc, open_panel, deep_chests[10].inv, deep_chests[10].actor, fake_api, org, ce, amap))
            assert(bank.render(pc, open_panel, deep_chests[10].inv, deep_chests[10].actor, fake_api, org, ce, amap))
            assert(#bank.state().view_model.tabs == 12, "expected all 12 chests in view model")
            assert(bank.state().tab_page == 2, "expected auto-jump to tab_page 2 for chest #10, got " .. tostring(bank.state().tab_page))
            assert(bank.state().tab_prev == true)
            assert(bank.state().ui.tabs[5].box:GetVisibility() == 0 and bank.state().ui.tabs[6].box:GetVisibility() == 1, "expected unused chest tabs (slots > remaining on page 2) to stay Collapsed (1)")

            -- Simulate moving to opposite side of base & switching to chest #1 via tab_prev -> chest #10 must NOT vanish or reshuffle!
            swap_dist = true
            local order_before = {}
            for i, t in ipairs(bank.state().view_model.tabs) do order_before[i] = t.key end
            assert(bank.handle_click("bank:tab_prev", current_api_inv, current_api_inv._owner, fake_api, org, ce))
            assert(bank.state().tab_page == 1)
            assert(bank.handle_click("bank:tab:1", current_api_inv, current_api_inv._owner, fake_api, org, ce))
            assert(current_api_inv == deep_chests[1].inv)
            assert(bank.render(pc, open_panel, deep_chests[1].inv, deep_chests[1].actor, fake_api, org, ce, amap))
            assert(#bank.state().view_model.tabs == 12, "expected locked physical chest #10 to stay in tabs after SetInventory switch")
            for i, t in ipairs(bank.state().view_model.tabs) do
                assert(t.key == order_before[i], "expected stable tab order at slot " .. tostring(i))
            end

            -- Verify genuine rlm_organiser.all_storage_in_reach keeps unowned bIsLocked chests when include_locked = true
            local prev_find_all = _G.FindAllOf
            local prev_find_first = _G.FindFirstOf
            local prev_sfo = _G.StaticFindObject
            local bba_tok = { _is_bba = true }
            local lock_actor = {
                IsValid = function() return true end,
                IsA = function(_, cls) return cls == bba_tok end,
                GetAddress = function() return 77701 end,
                GetFullName = function() return "BP_BaseBuilding_Chest_Iron_C_77701" end,
                GetCustomName = function() return nil end,
                K2_GetActorLocation = function() return { X = 100, Y = 0, Z = 0 } end,
                LinkedInventoryComponent = { IsValid = function() return true end, bIsLocked = true },
            }
            local lock_inv = {
                IsValid = function() return true end,
                GetFullName = function() return "LockInv_77701" end,
                GetOwner = function() return lock_actor end,
                MaxSlotCount = 16,
                ItemSlots = { ForEach = function() end },
            }
            _G.StaticFindObject = function(p)
                if p == "/Script/Dominion.BaseBuildingActor" then return bba_tok end
                return prev_sfo and prev_sfo(p) or nil
            end
            _G.FindAllOf = function(cls)
                if cls == "InventoryComponent" then return { lock_inv } end
                return {}
            end
            _G.FindFirstOf = function() return nil end
            local prev_org = package.loaded.rlm_organiser
            local prev_engine_pos = package.loaded.rlm_engine.local_controller
            package.loaded.rlm_engine.local_controller = function() return { IsValid = function() return false end } end
            package.loaded.rlm_organiser = nil
            local real_org = require("rlm_organiser")
            local without_locked = real_org.all_storage_in_reach({ X = 0, Y = 0, Z = 0 }, { rangeMeters = 40 }, {})
            local with_locked = real_org.all_storage_in_reach({ X = 0, Y = 0, Z = 0 }, { rangeMeters = 40 }, { include_locked = true })
            package.loaded.rlm_organiser = prev_org
            package.loaded.rlm_engine.local_controller = prev_engine_pos
            _G.StaticFindObject = prev_sfo
            _G.FindAllOf = prev_find_all
            _G.FindFirstOf = prev_find_first
            assert(#without_locked == 0, "expected default organiser scan to skip unowned locked chest, got " .. tostring(#without_locked))
            assert(#with_locked == 1 and with_locked[1].locked == true, "expected explorer include_locked scan to keep locked public chest")

            -- Verify bottom buttons keep SelfHitTestInvisible (4) on background border & Visible (0) on button hit target
            local qb5 = bank.state().ui.qty_btns[5]
            assert(qb5 and qb5.bg:GetVisibility() == 4, "expected SelfHitTestInvisible (4) on button Border so clicks reach button")
            assert(qb5.btn:GetVisibility() == 0, "expected Visible (0) on button hit target")

            -- Verify search drawer toggles, quantity pills update status, pin toggles, and role cycles
            assert(bank.state().search_open == false)
            assert(bank.handle_click("bank:search_toggle", current_api_inv, current_api_inv._owner, fake_api, org, ce))
            assert(bank.state().search_open == true)
            assert(bank.render(pc, open_panel, deep_chests[10].inv, deep_chests[10].actor, fake_api, org, ce, amap))
            assert(bank.state().ui.search_row:GetVisibility() == 4)
            assert(bank.handle_click("bank:search_clear", current_api_inv, current_api_inv._owner, fake_api, org, ce))
            assert(bank.state().search_open == false)

            assert(bank.handle_click("bank:qty:10", current_api_inv, current_api_inv._owner, fake_api, org, ce))
            assert(bank.state().qty_mode == 10 and bank.state().status_text:find("10", 1, true) ~= nil)

            -- Deposit from bank spills over automatically when the first unlabelled chest is full
            local sp_logs, sp_moves = {}, {}
            local full_c1_slots = {}
            for si = 0, 1 do
                full_c1_slots[si] = {
                    IsValid = function() return true end,
                    Count = 99,
                    ItemData = {
                        IsValid = function() return true end,
                        GetFName = function() return { ToString = function() return "ITEM_Resources_CopperOre" end } end,
                        Name = { ToString = function() return "Copper Ore" end },
                        MaxStackSize = 99,
                    },
                }
            end
            local empty_c2_slots = {}
            local full_inv = { IsValid = function() return true end, MaxSlotCount = 2, ItemSlots = { ForEach = function(_, cb)
                for idx = 0, 1 do if full_c1_slots[idx] then cb(idx + 1, { get = function() return full_c1_slots[idx] end }) end end
            end } }
            local overflow_inv = { IsValid = function() return true end, MaxSlotCount = 4, ItemSlots = { ForEach = function(_, cb)
                for idx = 0, 3 do if empty_c2_slots[idx] then cb(idx + 1, { get = function() return empty_c2_slots[idx] end }) end end
            end } }
            local bp_slot_item = {
                IsValid = function() return true end,
                Count = 5,
                ItemData = {
                    IsValid = function() return true end,
                    GetFName = function() return { ToString = function() return "ITEM_Resources_IronOre" end } end,
                    Name = { ToString = function() return "Iron Ore" end },
                    MaxStackSize = 99,
                },
            }
            local bp_inv = {
                IsValid = function() return true end,
                NumberOfQuickActionSlots = 10,
                MaxSlotCount = 12,
                ItemSlots = { ForEach = function(_, cb) cb(11, { get = function() return bp_slot_item end }) end },
            }
            local test_ctrl = {
                IsValid = function() return true end,
                InventoryComponent = bp_inv,
                InventoryController = {
                    IsValid = function() return true end,
                    MoveItemBetweenInventories = function(_, src, ss, dst, ds)
                        sp_moves[#sp_moves + 1] = { dst = dst, slot = ds }
                        return true
                    end,
                },
                Pawn = { IsValid = function() return true end, K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end },
            }
            local sp_org = {
                settings = function() return { rangeMeters = 40 } end,
                labelled_storage_in_reach = function() return {} end,
                open_storage = function() return full_inv, { IsValid = function() return true end } end,
                all_storage_in_reach = function()
                    return {
                        { actor = { IsValid = function() return true end, GetFullName = function() return "full_c1" end }, inv = full_inv, maxSlots = 2, distance = 1, slots = {} },
                        { actor = { IsValid = function() return true end, GetFullName = function() return "over_c2" end }, inv = overflow_inv, maxSlots = 4, distance = 2, slots = {} },
                    }
                end,
                read_slots = function(i)
                    if i == full_inv then return { { slot = 0, id = "ITEM_Resources_CopperOre", name = "Copper Ore", count = 99, maxStack = 99 }, { slot = 1, id = "ITEM_Resources_CopperOre", name = "Copper Ore", count = 99, maxStack = 99 } } end
                    if i == bp_inv then return { { slot = 10, id = "ITEM_Resources_IronOre", name = "Iron Ore", count = 5, maxStack = 99 } } end
                    return {}
                end,
                backpack_slot_ranges = function() return { { 10, 11 } } end,
                locks = function() return {} end,
                is_remote_client = function() return false end,
            }
            local prev_lc = package.loaded.rlm_engine.local_controller
            package.loaded.rlm_engine.local_controller = function() return test_ctrl end
            local ok_sp, sp_msg = ce.deposit_from_bank({ inv = full_inv, actor = { IsValid = function() return true end } }, sp_org)
            package.loaded.rlm_engine.local_controller = prev_lc
            assert(ok_sp and #sp_moves == 1 and sp_moves[1].dst == overflow_inv, "expected full first chest to spill over to overflow_inv: " .. tostring(sp_msg))

            -- Verify drag item onto chest tab transfers stack to target chest without click-withdraw
            assert(bank.handle_click("bank:tab:1", current_api_inv, current_api_inv._owner, fake_api, org, ce))
            assert(bank.render(pc, open_panel, deep_chests[1].inv, deep_chests[1].actor, fake_api, org, ce, amap))
            local src_entry = bank.state().grid_entries[1]
            assert(src_entry ~= nil)
            local drag_moves = {}
            org.transfer_single_slot = function(c, s_inv, s_slot, d_inv, d_slot, cnt, split)
                drag_moves[#drag_moves + 1] = { s_inv = s_inv, d_inv = d_inv, d_slot = d_slot, cnt = cnt }
                return true
            end
            assert(bank.handle_press("bank:tile:1") == true)
            assert(bank.state().drag_tile == 1 and bank.state().drag_entry == src_entry)
            -- Hover cursor over Tab 2 (deep_chests[2]) on release
            bank.state().ui.tabs[2].hit.IsHovered = function() return true end
            assert(bank.handle_release("bank:tile:1", current_api_inv, current_api_inv._owner, fake_api, org, ce) == true)
            bank.state().ui.tabs[2].hit.IsHovered = function() return false end
            assert(#drag_moves == 1 and drag_moves[1].s_inv == src_entry.chest_inv and drag_moves[1].d_inv == bank.state().tab_targets[2].chest.inv,
                "expected drag-release over tab 2 to transfer item to tab 2 chest")
            assert(bank.state().drag_tile == nil and bank.state().drag_entry == nil)

            -- Also verify relative WidgetLayoutLibrary mouse calibration handles Slate capture even when IsHovered() is false
            local mouse_pt = { X = 1047, Y = 418 }
            local prev_sfo_drag = _G.StaticFindObject
            _G.StaticFindObject = function(p)
                if p == "/Script/UMG.Default__WidgetLayoutLibrary" then
                    return { _valid = true, IsValid = function() return true end, GetMousePositionOnViewport = function() return mouse_pt end }
                end
                return prev_sfo_drag and prev_sfo_drag(p) or nil
            end
            assert(bank.handle_press("bank:tile:1") == true)
            -- Simulate dragging from tile 1 center (dx=47) up onto tab 3 center (13 + 18 + 3*59 + 28 = 236, y=68 => delta +189, -50)
            mouse_pt = { X = 1047 + 189, Y = 418 - 50 }
            assert(bank.handle_release("bank:tile:1", current_api_inv, current_api_inv._owner, fake_api, org, ce) == true)
            _G.StaticFindObject = prev_sfo_drag
            assert(#drag_moves == 2 and drag_moves[2].d_inv == bank.state().tab_targets[3].chest.inv,
                "expected calibrated viewport coordinates to resolve drop onto tab 3 chest")

            -- Closing restores original physical_inv before CloseCurrentInventory
            closed_api = false
            assert(bank.handle_click("bank:close", deep_chests[1].inv, deep_chests[1].actor, fake_api, org, ce))
            assert(closed_api == true and current_api_inv == deep_chests[10].inv, "expected close to restore original physical_inv")
            bank.stop()

            return true
        """)
        self.assertTrue(out)


if __name__ == "__main__":
    unittest.main()
