"""Unit and mocked Lua checks for the Organiser service and module (Modules/Organiser).

Tests manifest schema, index registration, label parsing, rule scoring, item lock retention,
settings, module lifecycle, and view navigation.
"""
from __future__ import annotations

import json
import os
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MODULE_DIR = ROOT / "Modules" / "Organiser"

_lupa_path = os.environ.get("RSDW_LUPA_PATH")
if _lupa_path:
    sys.path.insert(0, _lupa_path)
try:
    from lupa.lua54 import LuaRuntime
except ImportError:  # pragma: no cover
    LuaRuntime = None


ENV = r"""
local document
local saves = { count = 0, ok = true }
local fake_store = {
    register = function(kind, spec)
        assert(kind == "organiser" and spec.file == "organiser.json")
        document = document or { schemaVersion = 1 }
        return true, document
    end,
    get = function(kind)
        if kind == "organiser" then return document end
        return nil
    end,
    save = function(kind)
        assert(kind == "organiser")
        saves.count = saves.count + 1
        return saves.ok, (not saves.ok) and 'disk full' or nil
    end,
}
local logs = {}
local fake_log = {
    info = function(m) logs[#logs + 1] = 'info: ' .. tostring(m) end,
    warn = function(m) logs[#logs + 1] = 'warn: ' .. tostring(m) end,
    error = function(m) logs[#logs + 1] = 'error: ' .. tostring(m) end,
}
local fake_engine = {
    is_valid = function(o) return o ~= nil and o ~= false end,
    local_controller = function() return nil end,
    full_name = function(o) return tostring(o or '') end,
    call = function() return nil end,
    object_call = function() return nil end,
    real_time_seconds = function() return 0 end,
}
local base_building_class = {}
function StaticFindObject(path)
    if path == "/Script/Dominion.BaseBuildingActor" then return base_building_class end
end
function is_base_building(_, class)
    return class == base_building_class
end

package.loaded.rlm_store = fake_store
package.loaded.rlm_log = fake_log
package.loaded.rlm_engine = fake_engine
local service, hud
local native_loadfile = loadfile
function loadfile(path)
    local chunk, reason = native_loadfile(path)
    if not chunk then return nil, reason end
    if path:match("/rlm_organiser%.lua$") then
        return function()
            service = chunk()
            return service
        end
    elseif path:match("/rlm_organiser_hud%.lua$") then
        return function(organiser)
            hud = chunk(organiser)
            return hud
        end
    end
    return chunk
end

local module = assert(loadfile(MODULE_PATH))()
assert(module.start({}))

return {
    organiser = service,
    current_service = function() return service end,
    module = module,
    hud = hud,
    saves = saves,
    logs = logs,
    document = function() return document end,
}
"""


class OrganiserManifestTests(unittest.TestCase):
    def test_manifest_schema_and_fields(self):
        manifest_path = MODULE_DIR / "manifest.json"
        self.assertTrue(manifest_path.exists(), "manifest.json missing")
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

        self.assertEqual(manifest.get("schemaVersion"), 1)
        self.assertEqual(manifest.get("id"), "organiser")
        self.assertEqual(manifest.get("name"), "Organiser")
        self.assertEqual(manifest.get("order"), 25)
        self.assertEqual(manifest.get("entry"), "module.lua")

        ui = manifest.get("ui", {})
        self.assertEqual(ui.get("menuLabel"), "ORGANISER")
        action_ids = [a.get("id") for a in ui.get("actions", [])]
        self.assertIn("auto-organise", action_ids)
        self.assertIn("deposit", action_ids)
        self.assertIn("advisor", action_ids)
        self.assertIn("sort-open", action_ids)
        self.assertIn("resort-nearby", action_ids)
        self.assertIn("label", action_ids)
        self.assertIn("lock", action_ids)
        self.assertIn("trash", action_ids)
        self.assertEqual(manifest["version"], "0.3.4")

@unittest.skipIf(LuaRuntime is None, "lupa is not installed")
class OrganiserServiceTests(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        g = self.lua.globals()
        g.MODULE_PATH = (MODULE_DIR / "module.lua").as_posix()
        self.t = self.lua.execute(ENV)
        self.organiser = self.t["organiser"]
        g.organiser_service = self.organiser
        self.module = self.t["module"]
        self.hud = self.t["hud"]

    # -- Label parsing ---------------------------------------------------------

    def test_parse_label_exact_item(self):
        rule = self.organiser.parse_label("Ash Logs")
        self.assertIsNotNone(rule)
        self.assertEqual(rule["kind"], "item")
        self.assertEqual(rule["value"], "Ash Logs")

    def test_parse_label_category(self):
        rule = self.organiser.parse_label("All: Wood")
        self.assertIsNotNone(rule)
        self.assertEqual(rule["kind"], "cat")
        self.assertEqual(rule["value"], "Wood")

    def test_parse_label_misc_and_trash(self):
        misc = self.organiser.parse_label("Misc")
        self.assertIsNotNone(misc)
        self.assertEqual(misc["kind"], "misc")

        trash = self.organiser.parse_label("Trash")
        self.assertIsNotNone(trash)
        self.assertEqual(trash["kind"], "trash")

    def test_parse_label_empty_returns_nil(self):
        self.assertIsNone(self.organiser.parse_label(""))
        self.assertIsNone(self.organiser.parse_label("   "))
        self.assertIsNone(self.organiser.parse_label(None))

    # -- Rule scoring ----------------------------------------------------------

    def test_rule_score_prioritises_exact_item_over_category_and_misc(self):
        item_rule = self.organiser.parse_label("Ash Logs")
        cat_rule = self.organiser.parse_label("All: Wood")
        misc_rule = self.organiser.parse_label("Misc")

        item_info = self.lua.eval(r"""{ name = "Ash Logs", id = "ITEM_AshLogs", categories = { "Wood", "Resource" } }""")
        other_item_info = self.lua.eval(r"""{ name = "Oak Logs", id = "ITEM_OakLogs", categories = { "Wood", "Resource" } }""")
        container_items = self.lua.eval(r"""{ { id = "ITEM_AshLogs", name = "Ash Logs" } }""")

        # Exact item match gives score 3
        self.assertEqual(self.organiser.rule_score(item_rule, item_info, container_items), 3)
        self.assertIsNone(self.organiser.rule_score(item_rule, other_item_info, container_items))

        # Category match gives score 2
        self.assertEqual(self.organiser.rule_score(cat_rule, item_info, container_items), 2)
        self.assertEqual(self.organiser.rule_score(cat_rule, other_item_info, container_items), 2)

        # Misc match gives score 1 (when matching item exists in container)
        self.assertEqual(self.organiser.rule_score(misc_rule, item_info, container_items), 1)
        self.assertIsNone(self.organiser.rule_score(misc_rule, other_item_info, container_items))

    def test_rule_score_ore_theme_includes_minerals_and_metals_below_exact_category(self):
        ore_rule = self.organiser.parse_label("All: Ore")
        mineral_rule = self.organiser.parse_label("All: Mineral")
        component_rule = self.organiser.parse_label("All: Component")

        gypsum = self.lua.eval(r"""{ name = "Gypsum", id = "ITEM_Resources_Gypsum", categories = { "Mineral", "Resource" } }""")
        sandstone = self.lua.eval(r"""{ name = "Sandstone", id = "ITEM_Resources_Sandstone", categories = { "Mineral", "Resource" } }""")
        copper_ore = self.lua.eval(r"""{ name = "Copper Ore", id = "ITEM_Resources_CopperOre", categories = { "Ore", "Metal", "Resource" } }""")
        ash_logs = self.lua.eval(r"""{ name = "Ash Logs", id = "ITEM_Resources_Wood_Ash", categories = { "Wood", "Resource" } }""")

        # Gypsum & Sandstone match All: Ore via theme fallback (1.5), while exact All: Mineral wins (2)
        self.assertEqual(self.organiser.rule_score(ore_rule, gypsum), 1.5)
        self.assertEqual(self.organiser.rule_score(ore_rule, sandstone), 1.5)
        self.assertEqual(self.organiser.rule_score(mineral_rule, gypsum), 2)
        self.assertEqual(self.organiser.rule_score(ore_rule, copper_ore), 2)

        # Generic parent Resource tag must not pull Wood/Minerals into All: Component
        self.assertIsNone(self.organiser.rule_score(component_rule, ash_logs))
        self.assertIsNone(self.organiser.rule_score(component_rule, gypsum))

    # -- Item locks & retention ------------------------------------------------

    def test_item_locks_set_get_and_clear(self):
        ok, _ = self.organiser.set_lock("Ash Logs", 20)
        self.assertTrue(ok)
        self.assertEqual(self.organiser.lock("Ash Logs"), 20)

        ok, _ = self.organiser.set_lock("Yew Logs", "all")
        self.assertTrue(ok)
        self.assertEqual(self.organiser.lock("Yew Logs"), "all")

        # Set 0 removes lock
        ok, _ = self.organiser.set_lock("Ash Logs", 0)
        self.assertTrue(ok)
        self.assertIsNone(self.organiser.lock("Ash Logs"))

        # Clear all
        self.organiser.clear_all_locks()
        self.assertIsNone(self.organiser.lock("Yew Logs"))

    # -- Settings --------------------------------------------------------------

    def test_settings_defaults_and_updates(self):
        s = self.organiser.settings()
        self.assertEqual(s["rangeMeters"], 40)
        self.assertEqual(s["costEnabled"], False)
        self.assertEqual(s["enableTrash"], False)

        self.organiser.set_setting("rangeMeters", 60)
        self.assertEqual(self.organiser.setting("rangeMeters"), 60)

    # -- Module UI adapter -----------------------------------------------------

    def test_module_activate_overview_view(self):
        view = self.module.activate(None)
        self.assertIn("STORAGE ORGANISER", view["status"])
        self.assertIsInstance(view["rows"], object)

    def test_module_navigation_subviews(self):
        # Navigate to locks
        handled = self.module.select_row(None, "nav:locks")
        self.assertTrue(handled)
        view = self.module.activate(None)
        self.assertIn("ITEM RETENTION LOCKS", view["status"])

        # Navigate to settings
        handled = self.module.select_row(None, "nav:settings")
        self.assertTrue(handled)
        view = self.module.activate(None)
        self.assertIn("ORGANISER SETTINGS", view["status"])

        # Navigate back to overview
        handled = self.module.select_row(None, "nav:overview")
        self.assertTrue(handled)
        view = self.module.activate(None)
        self.assertIn("STORAGE ORGANISER", view["status"])

    def test_module_run_action_deposit_fails_safely_when_no_controller(self):
        ok, msg = self.module.run_action(None, "deposit", "")
        self.assertFalse(ok)
        self.assertIn("controller is unavailable", msg)

    # -- Container Sorting & Comparison ----------------------------------------

    def test_compare_items_deterministic_ordering(self):
        weapon = self.lua.eval(r"""{ name = "Bronze Sword", id = "ITEM_BronzeSword", count = 1, categories = { "Weapon" } }""")
        ore = self.lua.eval(r"""{ name = "Iron Ore", id = "ITEM_IronOre", count = 20, categories = { "Ore" } }""")
        wood_a = self.lua.eval(r"""{ name = "Ash Logs", id = "ITEM_AshLogs", count = 10, categories = { "Wood" } }""")
        wood_b = self.lua.eval(r"""{ name = "Oak Logs", id = "ITEM_OakLogs", count = 5, categories = { "Wood" } }""")

        # Weapon (rank 10) comes before Ore (rank 30)
        self.assertTrue(self.organiser.compare_items(weapon, ore))
        self.assertFalse(self.organiser.compare_items(ore, weapon))

        # Ore (rank 30) comes before Wood (rank 33)
        self.assertTrue(self.organiser.compare_items(ore, wood_a))

        # Within same category, Ash Logs comes before Oak Logs alphabetically
        self.assertTrue(self.organiser.compare_items(wood_a, wood_b))
        self.assertFalse(self.organiser.compare_items(wood_b, wood_a))

    def test_sort_open_storage_fails_safely_when_no_storage_open(self):
        ok, msg = self.organiser.sort_open_storage()
        self.assertFalse(ok)
        self.assertIn("No storage container is currently open", msg)

    def test_resort_nearby_storage_fails_safely_when_no_controller(self):
        ok, msg = self.organiser.resort_nearby_storage()
        self.assertFalse(ok)
        self.assertIn("unavailable", msg)

    def test_sort_storage_merges_partial_stacks_and_orders_slots(self):
        lua_code = r"""
        local slots_data = {
            [0] = { id = "ITEM_OakLogs", name = "Oak Logs", count = 10, maxStack = 50, categories = { "Wood" } },
            [1] = { id = "ITEM_IronOre", name = "Iron Ore", count = 15, maxStack = 50, categories = { "Ore" } },
            [2] = { id = "ITEM_IronOre", name = "Iron Ore", count = 25, maxStack = 50, categories = { "Ore" } },
        }
        local moves = {}
        local fake_ctrl = {
            MoveItemBetweenInventories = function(self, src_inv, src_slot, dst_inv, dst_slot)
                moves[#moves + 1] = { kind = "move", src = src_slot, dst = dst_slot }
                local temp = slots_data[src_slot]
                slots_data[src_slot] = slots_data[dst_slot]
                slots_data[dst_slot] = temp
                return true
            end,
            SplitAndPutStack = function(self, src_inv, src_slot, count, dst_inv, dst_slot)
                moves[#moves + 1] = { kind = "split", src = src_slot, count = count, dst = dst_slot }
                slots_data[dst_slot].count = slots_data[dst_slot].count + count
                slots_data[src_slot].count = slots_data[src_slot].count - count
                return true
            end,
        }
        local fake_inv = {
            MaxSlotCount = 10,
            ItemSlots = {
                ForEach = function(self, fn)
                    for i = 0, 9 do
                        local d = slots_data[i]
                        if d and d.count > 0 then
                            local mock_item = {
                                Count = d.count,
                                ItemData = {
                                    Name = { ToString = function() return d.name end },
                                    MaxStackSize = d.maxStack,
                                    GetFName = function() return { ToString = function() return d.id end } end,
                                    ItemFilterTags = {
                                        GameplayTags = {
                                            ForEach = function(s, f)
                                                for _, c in ipairs(d.categories or {}) do
                                                    f(nil, { get = function() return { TagName = { ToString = function() return "ItemFilter.Material." .. c end } } end })
                                                end
                                            end
                                        }
                                    }
                                }
                            }
                            fn(i + 1, { get = function() return mock_item end })
                        end
                    end
                end
            }
        }
        return fake_inv, fake_ctrl, slots_data, moves
        """
        fake_inv, fake_ctrl, slots_data, moves = self.lua.execute(lua_code)
        ok, msg, moved_count = self.organiser.sort_storage(fake_inv, fake_ctrl)
        self.assertTrue(ok)
        self.assertIn("Sorted", msg)
        self.assertIn("merged 1 partial stack", msg)

    def test_module_run_action_sort_and_resort_fail_safely(self):
        ok, msg = self.module.run_action(None, "sort-open", "")
        self.assertFalse(ok)
        self.assertIn("No storage container is currently open", msg)

        ok, msg = self.module.run_action(None, "resort-nearby", "")
        self.assertFalse(ok)
        self.assertIn("unavailable", msg)

    # -- Bank Sorter & Workstation Advisor -------------------------------------

    def test_bank_themes_coverage(self):
        themes = self.organiser.bank_themes()
        self.assertIsNotNone(themes)
        theme_ids = [t["id"] for t in themes.values()]
        self.assertIn("ore", theme_ids)
        self.assertIn("wood", theme_ids)
        self.assertIn("equipment", theme_ids)
        self.assertIn("food", theme_ids)
        self.assertIn("magic", theme_ids)
        self.assertIn("crafting", theme_ids)

    def test_auto_organise_base_fails_safely_when_no_controller(self):
        ok, msg = self.organiser.auto_organise_base()
        self.assertFalse(ok)
        self.assertIn("unavailable", msg)

    def test_base_advisor_report_fails_safely_when_no_controller(self):
        report, err = self.organiser.base_advisor_report()
        self.assertIsNone(report)
        self.assertIn("unavailable", err)

    def test_detect_workstations_matches_patterns(self):
        lua_code = r"""
        local mock_buildings = {
            {
                GetAddress = function() return 1001 end,
                GetFullName = function() return "BP_BaseBuilding_Furnace_C_1" end,
                K2_GetActorLocation = function() return { X = 500, Y = 0, Z = 0 } end,
            },
            {
                GetAddress = function() return 1002 end,
                GetFullName = function() return "BUILDPIECE_ProcessingStation_Sawmill_C_2" end,
                K2_GetActorLocation = function() return { X = 0, Y = 500, Z = 0 } end,
            },
            {
                GetAddress = function() return 1003 end,
                GetFullName = function() return "BP_BaseBuilding_Chest_C_3" end,
                K2_GetActorLocation = function() return { X = 100, Y = 100, Z = 0 } end,
            },
        }
        _G.FindAllOf = function(class_name)
            if class_name == "BaseBuildingActor" then
                return mock_buildings
            end
            return {}
        end
        """
        self.lua.execute(lua_code)
        origin = self.lua.eval(r"""{ X = 0, Y = 0, Z = 0 }""")
        stations = self.organiser.detect_workstations(origin, 40)
        self.assertEqual(len(stations), 2)
        names = [s["name"] for s in stations.values()]
        self.assertIn("Smelter / Furnace", names)
        self.assertIn("Sawmill / Carpentry Bench", names)

    def test_module_navigation_to_advisor_view(self):
        handled = self.module.select_row(None, "nav:advisor")
        self.assertTrue(handled)
        view = self.module.activate(None)
        self.assertIn("BASE STORAGE ADVISOR", view["status"])

    def test_module_run_action_auto_organise_and_advisor(self):
        ok, msg = self.module.run_action(None, "auto-organise", "")
        self.assertFalse(ok)
        self.assertIn("unavailable", msg)

        ok, msg = self.module.run_action(None, "advisor", "")
        self.assertTrue(ok)
        self.assertIn("Switched to Base Storage Advisor", msg)

    # -- Mod Menu & Auto-Load Hooks --------------------------------------------

    def test_auto_open_setting_defaults_and_toggle(self):
        s = self.organiser.settings()
        self.assertTrue(s["autoOpenOnStorage"])
        self.assertFalse(s["autoDepositOnOpen"])

        self.organiser.set_setting("autoOpenOnStorage", False)
        self.assertFalse(self.organiser.setting("autoOpenOnStorage"))
        self.organiser.set_setting("autoOpenOnStorage", True)
        self.assertTrue(self.organiser.setting("autoOpenOnStorage"))

    def test_auto_deposit_can_run_with_dock_disabled(self):
        self.lua.execute(r"""
        local actor = { IsA = is_base_building }
        local inventory = { GetOwner = function() return actor end }
        storage_api = { GetInventoryComponent = function() return inventory end }
        deposit_calls = 0
        """)
        self.organiser.deposit_backpack = self.lua.eval(
            "function() deposit_calls = deposit_calls + 1; return true end"
        )
        self.organiser.set_setting("autoOpenOnStorage", False)
        self.organiser.set_setting("autoDepositOnOpen", True)
        self.assertTrue(self.organiser.on_storage_opened(self.lua.globals().storage_api))
        self.assertFalse(self.organiser.on_storage_opened(self.lua.globals().storage_api))
        self.assertEqual(self.lua.globals().deposit_calls, 1)
        self.organiser.on_storage_closed(self.lua.globals().storage_api)
        self.assertTrue(self.organiser.on_storage_opened(self.lua.globals().storage_api))
        self.assertEqual(self.lua.globals().deposit_calls, 2)

    def test_arm_hooks_registers_open_and_close_hooks(self):
        lua_code = r"""
        _G.registered_hooks = {}
        _G.ExecuteInGameThread = function(fn) fn() end
        _G.RegisterHook = function(hook_name, callback)
            local t = _G.registered_hooks
            t[#t + 1] = hook_name
            return true
        end
        """
        self.lua.execute(lua_code)

        self.organiser.arm_hooks(self.hud)
        self.organiser.arm_hooks(self.hud)
        hooks = list(self.lua.eval("_G.registered_hooks").values())
        self.assertEqual(len(hooks), 3)
        self.assertTrue(any("SetInventory" in h for h in hooks))
        self.assertTrue(any("ToggleInventory" in h for h in hooks))
        self.assertTrue(any("CloseCurrentInventory" in h for h in hooks))

    def test_reload_replaces_dock_and_invalidates_pending_hook_work(self):
        self.lua.execute(r"""
        dock_loops = 0
        pending = {}
        bound_hooks = {}
        function LoopInGameThreadWithDelay()
            dock_loops = dock_loops + 1
        end
        function RegisterHook(name, callback)
            assert(not bound_hooks[name], "duplicate hook " .. name)
            bound_hooks[name] = callback
        end
        function ExecuteInGameThread(callback)
            pending[#pending + 1] = callback
        end
        function record_storage_open()
            bound_hooks["/Script/Dominion.WorldActorInventoryUIAPI:SetInventory"]({
                get = function() return {} end,
            })
        end
        """)
        self.assertTrue(self.module.start(None))
        self.lua.globals().record_storage_open()
        self.lua.execute(r"""
        old_calls, new_calls = 0, 0
        organiser_service.on_storage_opened = function() old_calls = old_calls + 1 end
        next_module = assert(loadfile(MODULE_PATH))()
        """)
        next_service = self.t["current_service"]()
        next_service.on_storage_opened = self.lua.eval("function() new_calls = new_calls + 1 end")
        self.organiser.set_setting("rangeMeters", 60)
        self.module.stop()
        self.assertTrue(self.lua.globals().next_module.start(None))
        self.lua.globals().record_storage_open()
        self.lua.execute("for _, callback in ipairs(pending) do callback() end")
        self.assertEqual(self.lua.globals().dock_loops, 1)
        self.assertEqual(len(list(self.lua.globals().bound_hooks.keys())), 4)
        self.assertEqual(self.lua.globals().old_calls, 0)
        self.assertEqual(self.lua.globals().new_calls, 1)
        self.assertEqual(self.t["document"]()["settings"]["rangeMeters"], 60)

    def test_open_storage_respects_inactive_main_panel(self):
        self.lua.execute(r"""
        local stale_actor = {
            GetAddress = function() return 901 end,
            GetFullName = function() return "BP_BaseBuilding_Chest_C_901" end,
        }
        local stale_inv = {
            GetOwner = function() return stale_actor end,
        }
        local stale_api = {
            GetInventoryComponent = function() return stale_inv end,
            IsInitialized = function() return true end,
            GetFullName = function() return "WorldActorInventoryUIAPI_1" end,
        }
        local inactive_panel = {
            IsValid = function() return true end,
            GetFullName = function() return "WBP_WorldActorInventory_MainPanel_C_1" end,
            IsActivated = function() return false end,
            IsVisible = function() return false end,
            WorldInventoryManagerAPI = stale_api,
        }
        _G.FindAllOf = function(cls)
            if cls == "WorldActorInventoryMainPanel" then return { inactive_panel } end
            if cls == "WorldActorInventoryUIAPI" then return { stale_api } end
            return {}
        end
        """)
        inv = self.organiser.open_storage()
        self.assertIsNone(inv)

        self.lua.execute(r"""
        local active_actor = {
            GetAddress = function() return 902 end,
            GetFullName = function() return "BP_BaseBuilding_Chest_C_902" end,
            IsA = is_base_building,
            GetCustomName = {},
        }
        local active_inv = {
            GetOwner = function() return active_actor end,
        }
        local active_api = {
            GetInventoryComponent = function() return active_inv end,
            IsInitialized = function() return true end,
            GetFullName = function() return "WorldActorInventoryUIAPI_2" end,
        }
        local active_panel = {
            IsValid = function() return true end,
            GetFullName = function() return "WBP_WorldActorInventory_MainPanel_C_2" end,
            IsActivated = function() return true end,
            IsVisible = function() return true end,
            WorldInventoryManagerAPI = active_api,
        }
        _G.FindAllOf = function(cls)
            if cls == "WorldActorInventoryMainPanel" then return { active_panel } end
            return {}
        end
        """)
        inv, actor, api, panel = self.organiser.open_storage()
        self.assertIsNotNone(inv)
        self.assertIsNotNone(actor)
        self.assertIsNotNone(api)
        self.assertIsNotNone(panel)
        view = self.module.activate(None)
        self.assertEqual(view["rows"][1]["title"], "OPEN STORAGE: UNLABELLED")

    def test_world_loot_chest_skips_open_and_close_actions(self):
        self.lua.execute(r"""
        local loot_actor = {
            IsA = function() return false end,
            GetFullName = function() return "DungeonChest /Game/Maps/Generated/Chest" end,
            GetCustomName = {},
            LinkedInventoryComponent = {},
        }
        local inv = { GetOwner = function() return loot_actor end }
        _G.loot_api = {
            GetInventoryComponent = function() return inv end,
            IsInitialized = function() return true end,
        }
        local panel = {
            IsActivated = function() return true end,
            WorldInventoryManagerAPI = loot_api,
        }
        _G.FindAllOf = function(class)
            if class == "WorldActorInventoryMainPanel" and not _G.api_only then return { panel } end
            if class == "WorldActorInventoryUIAPI" then return { loot_api } end
            return {}
        end
        _G.loot_actions = 0
        local function record_action()
            loot_actions = loot_actions + 1
            return true
        end
        function record_loot_action() return record_action() end
        """)
        self.organiser.deposit_backpack = self.lua.globals().record_loot_action
        self.organiser.label_of = self.lua.eval('function() return "Trash" end')
        self.organiser.incinerate_storage = self.lua.globals().record_loot_action
        self.organiser.set_setting("enableTrash", True)
        self.organiser.set_setting("autoDepositOnOpen", True)
        self.assertIsNone(self.organiser.open_storage())
        self.lua.globals().api_only = True
        self.assertIsNone(self.organiser.open_storage())
        loot_api = self.lua.globals().loot_api
        self.assertFalse(self.organiser.on_storage_opened(loot_api))
        self.organiser.on_storage_closed(loot_api)
        self.assertEqual(self.lua.globals().loot_actions, 0)

    def test_organiser_hud_staged_dock_and_visibility_lifecycle(self):
        self.lua.execute(r"""
        _G.__HUD_STATE_VIS = {}
        local created_objs = {}
        local fake_slot = {
            SetAutoSize = function() end,
            SetZOrder = function() end,
            SetAnchors = function() end,
            SetAlignment = function() end,
            SetPosition = function() end,
            SetSize = function() end,
            SetPadding = function() end,
            SetHorizontalAlignment = function() end,
            SetVerticalAlignment = function() end,
        }
        local function make_widget(kind)
            local w = {
                _cls = kind,
                Font = { Size = 12 },
                SetVisibility = function(self, v)
                    self._vis = v
                    if self._is_frame then
                        _G.__HUD_STATE_VIS[#_G.__HUD_STATE_VIS + 1] = v
                    end
                end,
                GetChildrenCount = function() return 0 end,
                GetClass = function(self) return { GetFName = function() return { ToString = function() return self._cls end } end } end,
                AddChildToVerticalBox = function() return fake_slot end,
                AddChildToHorizontalBox = function() return fake_slot end,
                AddChildToOverlay = function() return fake_slot end,
                AddChild = function() return fake_slot end,
                AddChildToCanvas = function() return fake_slot end,
                SetText = function(self, t) self._text = t end,
                SetLabelText = function() end,
                SetColorAndOpacity = function() end,
                SetFont = function() end,
                SetAutoWrapText = function() end,
                SetWrapTextAt = function() end,
                SetShadowOffset = function() end,
                SetShadowColorAndOpacity = function() end,
                SetIsSelectable = function() end,
                SetShouldSelectUponReceivingFocus = function() end,
                SetIsFocusable = function() end,
                SetWidthOverride = function() end,
                SetHeightOverride = function() end,
                SetRenderOpacity = function() end,
                RemoveFromParent = function() end,
                GetFullName = function(self) return self._name or (kind .. "_inst") end,
            }
            return w
        end
        local btn_counter = 0
        local frame_obj = make_widget("WBP_Panel_C")
        frame_obj._is_frame = true
        frame_obj.BackgroundPanel = make_widget("Image")
        frame_obj.PanelContent = make_widget("Overlay")
        frame_obj.WidgetTree = make_widget("WidgetTree")
        frame_obj.WidgetTree.RootWidget = make_widget("CanvasPanel")

        local host_canvas = make_widget("CanvasPanel")
        local host_panel = make_widget("WBP_WorldActorInventory_MainPanel_C")
        host_panel._name = "WBP_WorldActorInventory_MainPanel_C_live"
        host_panel.WidgetTree = { RootWidget = host_canvas }

        local find_class = _G.StaticFindObject
        _G.StaticFindObject = function(path)
            if path == "/Script/Dominion.BaseBuildingActor" then return find_class(path) end
            return { _path = path, IsValid = function() return true end }
        end
        _G.StaticConstructObject = function(cls, parent)
            local p = cls and cls._path or ""
            local k = p:match("([^.]+)$") or "Widget"
            return make_widget(k)
        end
        _G.LoadAsset = function() end
        _G.FText = function(s) return tostring(s) end
        _G.LoopInGameThreadWithDelay = function(ms, fn)
            _G.__HUD_LOOP_FN = fn
            return true
        end
        _G.RegisterHook = function() return true end
        _G.FindFirstOf = function(cls)
            if cls == "WBP_WorldActorInventory_MainPanel_C" then return host_panel end
            return nil
        end

        local chest_actor = {
            GetAddress = function() return 777 end,
            GetFullName = function() return "BP_BaseBuilding_Chest_C_777" end,
            IsA = is_base_building,
            GetCustomName = function() return { ToString = function() return "Ore Chest" end } end,
            K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
        }
        local chest_inv = {
            MaxSlotCount = 20,
            GetOwner = function()
                if _G.__LOOT_OPEN then return { IsA = function() return false end } end
                return chest_actor
            end,
            ItemSlots = { ForEach = function() end },
        }
        local chest_api = {
            GetInventoryComponent = function() return chest_inv end,
            IsInitialized = function() return true end,
            CloseCurrentInventory = function() end,
        }
        host_panel.IsActivated = function() return _G.__CHEST_OPEN end
        host_panel.IsVisible = function() return _G.__CHEST_OPEN end
        host_panel.WorldInventoryManagerAPI = chest_api
        _G.FindAllOf = function(cls)
            if cls == "WorldActorInventoryMainPanel" then return { host_panel } end
            return {}
        end
        package.loaded.rlm_engine.local_controller = function()
            return { IsValid = function() return true end }
        end
        local wbl = {
            Create = function(self, pc, cls, owner)
                local p = cls and cls._path or ""
                if p:find("WBP_Panel", 1, true) then return frame_obj end
                btn_counter = btn_counter + 1
                local b = make_widget("WBP_DomAllCapsButton")
                b._name = "Btn_" .. tostring(btn_counter)
                return b
            end,
        }
        local orig_find = _G.StaticFindObject
        _G.StaticFindObject = function(path)
            if path == "/Script/UMG.Default__WidgetBlueprintLibrary" then return wbl end
            return orig_find(path)
        end
        """)

        hud = self.hud
        hud.start(self.lua.eval("{ config = { OrganiserPanelX = 1380, OrganiserPanelY = 57 } }"))

        # Closed chest: stays idle
        self.lua.execute("_G.__CHEST_OPEN = false")
        hud.tick()
        self.assertEqual(hud.state()["stage"], "idle")

        # Open chest: 3-tick staged build -> frame, content, ready -> visible (0)
        self.lua.execute("_G.__CHEST_OPEN = true")
        hud.tick()
        self.assertEqual(hud.state()["stage"], "frame")
        hud.tick()
        self.assertEqual(hud.state()["stage"], "content")
        hud.tick()
        self.assertEqual(hud.state()["stage"], "ready")
        hud.tick()
        vis_history = list(self.lua.eval("_G.__HUD_STATE_VIS").values())
        self.assertEqual(vis_history[-1], 0)

        # Close chest: frame collapses (1)
        self.lua.execute("_G.__CHEST_OPEN = false")
        hud.tick()
        vis_history = list(self.lua.eval("_G.__HUD_STATE_VIS").values())
        self.assertEqual(vis_history[-1], 1)

        # A visible loot panel must not show the dock again.
        self.lua.execute("_G.__CHEST_OPEN = true; _G.__LOOT_OPEN = true")
        hud.tick()
        self.assertEqual(list(self.lua.eval("_G.__HUD_STATE_VIS").values())[-1], 1)

        hud.stop()

    def test_remote_client_skips_locked_private_and_workstation_inventories(self):
        self.lua.execute(r"""
        package.loaded.rlm_engine.local_generation_allowed = function()
            return false, "RemoteClient"
        end
        local linked_chest = {
            GetAddress = function() return 101 end,
            GetFullName = function() return "BP_BaseBuilding_Chest_C_101" end,
            IsA = is_base_building,
            K2_GetActorLocation = function() return { X = 100, Y = 0, Z = 0 } end,
            LinkedInventoryComponent = { IsValid = function() return true end, bIsLocked = false },
            OwnershipComponent = { IsValid = function() return true end, bIsPrivatelyOwned = false },
        }
        local locked_chest = {
            GetAddress = function() return 102 end,
            GetFullName = function() return "BP_BaseBuilding_Chest_C_102" end,
            IsA = is_base_building,
            K2_GetActorLocation = function() return { X = 200, Y = 0, Z = 0 } end,
            LinkedInventoryComponent = { IsValid = function() return true end, bIsLocked = true },
            OwnershipComponent = { IsValid = function() return true end, bIsPrivatelyOwned = false },
        }
        local private_chest = {
            GetAddress = function() return 103 end,
            GetFullName = function() return "BP_BaseBuilding_Chest_C_103" end,
            IsA = is_base_building,
            K2_GetActorLocation = function() return { X = 300, Y = 0, Z = 0 } end,
            LinkedInventoryComponent = { IsValid = function() return true end, bIsLocked = false },
            OwnershipComponent = { IsValid = function() return true end, bIsPrivatelyOwned = true },
        }
        local smelter = {
            GetAddress = function() return 104 end,
            GetFullName = function() return "BP_BaseBuilding_Smelter_C_104" end,
            IsA = is_base_building,
            K2_GetActorLocation = function() return { X = 400, Y = 0, Z = 0 } end,
        }
        local invs = {
            { GetOwner = function() return linked_chest end, MaxSlotCount = 20, ItemSlots = { ForEach = function() end } },
            { GetOwner = function() return locked_chest end, MaxSlotCount = 20, ItemSlots = { ForEach = function() end } },
            { GetOwner = function() return private_chest end, MaxSlotCount = 20, ItemSlots = { ForEach = function() end } },
            { GetOwner = function() return smelter end, MaxSlotCount = 5, ItemSlots = { ForEach = function() end } },
        }
        _G.FindFirstOf = function(cls)
            if cls == "LinkedInventoryComponent" then return linked_chest.LinkedInventoryComponent end
            return nil
        end
        _G.FindAllOf = function(cls)
            if cls == "InventoryComponent" then return invs end
            return {}
        end
        """)
        chests = self.organiser.all_storage_in_reach(self.lua.eval("{ X = 0, Y = 0, Z = 0 }"), self.lua.eval("{ rangeMeters = 40, anyStorage = true }"))
        self.assertEqual(len(chests), 1)
        self.assertEqual(chests[1]["actor"].GetAddress(), 101)

    def test_remote_client_auto_organise_paces_rpcs_without_single_frame_flood(self):
        self.lua.execute(r"""
        package.loaded.rlm_engine.local_generation_allowed = function()
            return false, "RemoteClient"
        end
        local t = 0
        package.loaded.rlm_engine.real_time_seconds = function() return t end

        _G.__RPC_LOG = {}
        local scheduled = {}
        package.loaded.rlm_async = {
            after = function(delay, cb)
                scheduled[#scheduled + 1] = { due = t + delay, cb = cb }
                return true
            end
        }
        _G.__ADVANCE_ASYNC = function(steps)
            for _ = 1, (steps or 20) do
                if #scheduled == 0 then break end
                table.sort(scheduled, function(a, b) return a.due < b.due end)
                local next_task = table.remove(scheduled, 1)
                if next_task.due > t then t = next_task.due end
                next_task.cb()
            end
        end

        local function make_item(id, name, cat, count)
            return {
                Count = count,
                ItemData = {
                    Name = { ToString = function() return name end },
                    MaxStackSize = 50,
                    GetFName = function() return { ToString = function() return id end } end,
                    ItemFilterTags = { GameplayTags = { ForEach = function(_, f)
                        f(nil, { get = function() return { TagName = { ToString = function() return "ItemFilter.Material." .. cat end } } end })
                    end } },
                }
            }
        end

        local c1_slots = { [0] = make_item("ITEM_AshLogs", "Ash Logs", "Wood", 5) }
        local c2_slots = { [0] = make_item("ITEM_CopperOre", "Copper Ore", "Ore", 5) }
        local c1_name, c2_name = "", ""
        local actor1, actor2
        actor1 = {
            GetAddress = function() return 201 end,
            GetFullName = function() return "BP_BaseBuilding_Chest_C_201" end,
            IsA = is_base_building,
            K2_GetActorLocation = function() return { X = 100, Y = 0, Z = 0 } end,
            GetCustomName = function() return { ToString = function() return c1_name end } end,
            LinkedInventoryComponent = { IsValid = function() return true end, bIsLocked = false },
            OwnershipComponent = { IsValid = function() return true end, bIsPrivatelyOwned = false },
        }
        actor2 = {
            GetAddress = function() return 202 end,
            GetFullName = function() return "BP_BaseBuilding_Chest_C_202" end,
            IsA = is_base_building,
            K2_GetActorLocation = function() return { X = 200, Y = 0, Z = 0 } end,
            GetCustomName = function() return { ToString = function() return c2_name end } end,
            LinkedInventoryComponent = { IsValid = function() return true end, bIsLocked = false },
            OwnershipComponent = { IsValid = function() return true end, bIsPrivatelyOwned = false },
        }
        local function make_inv(actor, slots_tbl)
            return {
                MaxSlotCount = 10,
                GetOwner = function() return actor end,
                GetItemFromSlot = function(_, s) return slots_tbl[s] end,
                GetNumItemsInSlot = function(_, s) return slots_tbl[s] and slots_tbl[s].Count or 0 end,
                ItemSlots = { ForEach = function(_, fn)
                    for i = 0, 9 do if slots_tbl[i] then fn(i + 1, { get = function() return slots_tbl[i] end }) end end
                end },
                _slots = slots_tbl,
            }
        end
        local inv1 = make_inv(actor1, c1_slots)
        local inv2 = make_inv(actor2, c2_slots)

        _G.FindFirstOf = function(cls)
            if cls == "LinkedInventoryComponent" then return actor1.LinkedInventoryComponent end
            return nil
        end
        _G.FindAllOf = function(cls)
            if cls == "InventoryComponent" then return { inv1, inv2 } end
            return {}
        end
        _G.FText = function(s) return { ToString = function() return tostring(s) end } end

        local fake_ctrl = {
            MoveItemBetweenInventories = function(_, src, ss, dst, ds)
                _G.__RPC_LOG[#_G.__RPC_LOG + 1] = "move:" .. ss .. "->" .. ds
                local tmp = src._slots[ss]
                src._slots[ss] = dst._slots[ds]
                dst._slots[ds] = tmp
                return true
            end,
        }
        local pc = {
            IsValid = function() return true end,
            Pawn = { IsValid = function() return true end, K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end },
            InventoryController = fake_ctrl,
            Server_SetObjectCustomName = function(_, a, txt)
                _G.__RPC_LOG[#_G.__RPC_LOG + 1] = "rename:" .. a.GetAddress()
                if a == actor1 then c1_name = txt.ToString() else c2_name = txt.ToString() end
            end,
        }
        package.loaded.rlm_engine.local_controller = function() return pc end
        """)

        # 1. Start auto-organise: immediate return uses 0 synchronous RPCs!
        ok, msg, data = self.organiser.auto_organise_base()
        self.assertTrue(ok)
        self.assertIn("running safely", msg)
        self.assertEqual(len(list(self.lua.eval("_G.__RPC_LOG").values())), 0)
        self.assertTrue(self.organiser.is_busy())

        # 2. Overlapping run refuses while active!
        ok2, msg2 = self.organiser.auto_organise_base()
        self.assertFalse(ok2)
        self.assertIn("already running", msg2)

        # 3. Advance scheduled steps asynchronously
        self.lua.execute("_G.__ADVANCE_ASYNC(50)")
        self.assertFalse(self.organiser.is_busy())
        rpcs = list(self.lua.eval("_G.__RPC_LOG").values())
        self.assertGreaterEqual(len(rpcs), 2)
        self.assertIn("Organised 2 chest(s)", self.organiser.job_status())

    def test_remote_client_fail_closed_on_unknown_mode_and_stops_on_unchanged_move(self):
        self.lua.execute(r"""
        package.loaded.rlm_engine.local_generation_allowed = function()
            return false, "Unknown"
        end
        local t = 0
        package.loaded.rlm_engine.real_time_seconds = function() return t end
        _G.__RPC_COUNT = 0
        local scheduled = {}
        package.loaded.rlm_async = {
            after = function(delay, cb)
                scheduled[#scheduled + 1] = { due = t + delay, cb = cb }
                return true
            end
        }
        _G.__ADVANCE_ASYNC = function(steps)
            for _ = 1, (steps or 80) do
                if #scheduled == 0 then break end
                table.sort(scheduled, function(a, b) return a.due < b.due end)
                local next_task = table.remove(scheduled, 1)
                if next_task.due > t then t = next_task.due end
                next_task.cb()
            end
        end
        local function make_item(id, name, cat, count)
            return {
                Count = count,
                ItemData = {
                    Name = { ToString = function() return name end },
                    MaxStackSize = 50,
                    GetFName = function() return { ToString = function() return id end } end,
                    ItemFilterTags = { GameplayTags = { ForEach = function(_, f)
                        f(nil, { get = function() return { TagName = { ToString = function() return "ItemFilter.Material." .. cat end } } end })
                    end } },
                }
            }
        end
        local slots = {
            [0] = make_item("ITEM_AshLogs", "Ash Logs", "Wood", 5),
            [5] = make_item("ITEM_CopperOre", "Copper Ore", "Ore", 10),
        }
        local actor = {
            GetAddress = function() return 301 end,
            GetFullName = function() return "BP_BaseBuilding_Chest_C_301" end,
            IsA = is_base_building,
            K2_GetActorLocation = function() return { X = 100, Y = 0, Z = 0 } end,
            GetCustomName = function() return { ToString = function() return "All: Ore" end } end,
            LinkedInventoryComponent = { IsValid = function() return true end, bIsLocked = false },
            OwnershipComponent = { IsValid = function() return true end, bIsPrivatelyOwned = false },
        }
        local inv = {
            MaxSlotCount = 10,
            GetOwner = function() return actor end,
            GetItemFromSlot = function(_, s) return slots[s] end,
            GetNumItemsInSlot = function(_, s) return slots[s] and slots[s].Count or 0 end,
            ItemSlots = { ForEach = function(_, fn)
                for i = 0, 9 do if slots[i] then fn(i + 1, { get = function() return slots[i] end }) end end
            end },
        }
        _G.FindFirstOf = function(cls)
            if cls == "LinkedInventoryComponent" then return actor.LinkedInventoryComponent end
            return nil
        end
        _G.FindAllOf = function(cls)
            if cls == "InventoryComponent" then return { inv } end
            return {}
        end
        local fake_ctrl = {
            MoveItemBetweenInventories = function()
                _G.__RPC_COUNT = _G.__RPC_COUNT + 1
                -- Simulate server refusing/ignoring the move (slots stay unchanged)
                return true
            end,
        }
        package.loaded.rlm_engine.local_controller = function()
            return {
                IsValid = function() return true end,
                Pawn = { IsValid = function() return true end, K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end },
                InventoryController = fake_ctrl,
            }
        end
        """)
        ok, msg, data = self.organiser.auto_organise_base()
        self.assertTrue(ok)
        self.assertTrue(data["async"])
        self.assertEqual(self.lua.eval("_G.__RPC_COUNT"), 0)

        self.lua.execute("_G.__ADVANCE_ASYNC(80)")
        self.assertFalse(self.organiser.is_busy())
        # Must abort after 1 timed-out attempt instead of retrying the same unchanged slot 60x
        self.assertEqual(self.lua.eval("_G.__RPC_COUNT"), 1)
        self.assertTrue(any("4 checks" in entry for entry in self.t["logs"].values()))

    def test_remote_sort_waits_for_both_slots_and_plans_on_the_next_pass(self):
        inv, ctrl, reads = self.lua.execute(r"""
        local t, queued = 0, nil
        local engine = package.loaded.rlm_engine
        engine.local_generation_allowed = function() return false, "RemoteClient" end
        engine.real_time_seconds = function() return t end
        package.loaded.rlm_async = {
            after = function(delay, cb)
                assert(not queued, "only one continuation should be queued")
                queued = { due = t + delay, cb = cb }
                return true
            end,
        }
        ADVANCE = function()
            local task = assert(queued)
            queued = nil
            t = task.due
            task.cb()
            return t
        end

        local data = {
            Name = { ToString = function() return "Ash Logs" end },
            MaxStackSize = 50,
            GetFName = function() return { ToString = function() return "ITEM_AshLogs" end } end,
        }
        local slots = { [0] = { ItemData = data, Count = 10 }, [1] = { ItemData = data, Count = 5 } }
        local reads = { sweeps = 0 }
        local inv = {
            GetItemFromSlot = function(_, slot) return slots[slot] end,
            GetNumItemsInSlot = function(_, slot) return slots[slot] and slots[slot].Count or 0 end,
            ItemSlots = { ForEach = function(_, fn)
                reads.sweeps = reads.sweeps + 1
                for slot = 0, 1 do
                    if slots[slot] then fn(slot + 1, { get = function() return slots[slot] end }) end
                end
            end },
        }
        REPLICATE_DESTINATION = function() slots[0].Count = 15 end
        local ctrl = {
            MoveItemBetweenInventories = function(_, _, from_slot)
                slots[from_slot] = nil
                return true
            end,
        }
        return inv, ctrl, reads
        """)
        self.assertTrue(self.organiser.sort_storage(inv, ctrl)[0])
        self.assertAlmostEqual(self.lua.eval("ADVANCE()"), 0.05)  # dispatch
        scans = reads["sweeps"]
        self.assertAlmostEqual(self.lua.eval("ADVANCE()"), 0.23)  # source updated
        self.assertTrue(self.organiser.is_busy())
        self.assertEqual(reads["sweeps"], scans)
        self.lua.execute("REPLICATE_DESTINATION()")
        self.assertAlmostEqual(self.lua.eval("ADVANCE()"), 0.50)  # both slots confirmed
        self.assertEqual(reads["sweeps"], scans)
        self.assertAlmostEqual(self.lua.eval("ADVANCE()"), 0.50)  # next scheduler pass
        self.assertFalse(self.organiser.is_busy())
        self.assertIn("1 merge(s)", self.organiser.job_status())

    def test_remote_client_allows_own_private_chest_and_groups_crafting_sort(self):
        self.lua.execute(r"""
        package.loaded.rlm_engine.local_generation_allowed = function()
            return false, "RemoteClient"
        end
        local my_guid = "MY_CHAR_GUID"
        package.loaded.rlm_engine.local_controller = function()
            return {
                IsValid = function() return true end,
                GetCharacterGuid = function() return my_guid end,
            }
        end
        local my_private = {
            GetAddress = function() return 401 end,
            GetFullName = function() return "BP_BaseBuilding_Chest_C_401" end,
            IsA = is_base_building,
            K2_GetActorLocation = function() return { X = 100, Y = 0, Z = 0 } end,
            LinkedInventoryComponent = { IsValid = function() return true end, bIsLocked = false },
            OwnershipComponent = {
                IsValid = function() return true end,
                bIsPrivatelyOwned = true,
                IsPrivatelyLockedFromPlayer = function(_, g) return g ~= my_guid end,
            },
        }
        local other_private = {
            GetAddress = function() return 402 end,
            GetFullName = function() return "BP_BaseBuilding_Chest_C_402" end,
            IsA = is_base_building,
            K2_GetActorLocation = function() return { X = 200, Y = 0, Z = 0 } end,
            LinkedInventoryComponent = { IsValid = function() return true end, bIsLocked = false },
            OwnershipComponent = {
                IsValid = function() return true end,
                bIsPrivatelyOwned = true,
                IsPrivatelyLockedFromPlayer = function(_, g) return g ~= "OTHER_GUID" end,
            },
        }
        _G.FindFirstOf = function(cls)
            if cls == "LinkedInventoryComponent" then return my_private.LinkedInventoryComponent end
            return nil
        end
        _G.FindAllOf = function(cls)
            if cls == "InventoryComponent" then
                return {
                    { GetOwner = function() return my_private end, MaxSlotCount = 20, ItemSlots = { ForEach = function() end } },
                    { GetOwner = function() return other_private end, MaxSlotCount = 20, ItemSlots = { ForEach = function() end } },
                }
            end
            return {}
        end
        """)
        chests = self.organiser.all_storage_in_reach(
            self.lua.eval("{ X = 0, Y = 0, Z = 0 }"),
            self.lua.eval("{ rangeMeters = 40, anyStorage = true }"),
        )
        self.assertEqual(len(chests), 1)
        self.assertEqual(chests[1]["actor"].GetAddress(), 401)

        # Sorting groups equipment/jewellery before materials, and groups leather/thread/bars by family
        ring = self.lua.eval('{ id = "ITEM_Trinket_Iconic_Runic_Ring", name = "Runic Ring", count = 1, categories = { "Jewellery" } }')
        bar = self.lua.eval('{ id = "ITEM_Resources_MithrilBar", name = "Mithril Bar", count = 14, categories = { "Component" } }')
        soft_leather = self.lua.eval('{ id = "ITEM_Resources_Leather_Soft", name = "Soft Leather", count = 3, categories = { "Basic" } }')
        cursed_leather = self.lua.eval('{ id = "ITEM_Resources_Leather_Cursed", name = "Cursed Leather", count = 1, categories = { "Basic" } }')
        coarse_thread = self.lua.eval('{ id = "ITEM_Resources_Thread_Coarse", name = "Coarse Thread", count = 99, categories = { "Basic" } }')
        linen_cloth = self.lua.eval('{ id = "ITEM_Resources_Cloth_Linen", name = "Linen Cloth", count = 15, categories = { "Basic" } }')

        self.assertTrue(self.organiser.compare_items(ring, bar))
        self.assertTrue(self.organiser.compare_items(bar, cursed_leather))
        self.assertTrue(self.organiser.compare_items(cursed_leather, soft_leather))
        self.assertTrue(self.organiser.compare_items(soft_leather, coarse_thread))
        self.assertTrue(self.organiser.compare_items(coarse_thread, linen_cloth))

    def test_adaptive_base_role_planner_scales_with_chest_count_and_routes_overflow(self):
        self.lua.execute(r"""
        local function chest(idx, label, slots, max_slots)
            return {
                label = label,
                rule = label and organiser_service.parse_label(label) or nil,
                pos = { X = idx * 100, Y = 0, Z = 0 },
                d2 = (idx * 100) * (idx * 100),
                slots = slots or {},
                maxSlots = max_slots or 20,
            }
        end
        local function st_item(id, name, cats)
            return { id = id, name = name, count = 50, maxStack = 99, categories = cats }
        end

        -- 1. Starter tier (< 8 chests): uses coarse Bank Themes only
        local starter = {
            chest(1, "All: Component", {
                st_item("ITEM_Leather1", "Soft Leather", { "Basic", "Leather" }),
                st_item("ITEM_Leather2", "Hard Leather", { "Basic", "Leather" }),
                st_item("ITEM_Leather3", "Cursed Leather", { "Component", "Leather" }),
            }),
            chest(2, nil, {}),
            chest(3, nil, {}),
            chest(4, nil, {}),
        }
        _G.__PLAN_STARTER = organiser_service.plan_base_roles(starter, {})

        -- 2. Standard tier (8..19 chests): promotes busy sub-categories like All: Leather
        local standard = {
            chest(1, "All: Component", {
                st_item("ITEM_Leather1", "Soft Leather", { "Component", "Leather" }),
                st_item("ITEM_Leather2", "Hard Leather", { "Basic", "Leather" }),
                st_item("ITEM_Bar1", "Mithril Bar", { "Component", "Metal" }),
                st_item("ITEM_Bar2", "Adamant Bar", { "Component", "Metal" }),
            }),
            chest(2, "All: Ore", {}),
            chest(3, "All: Wood", {}),
            chest(4, "All: Equipment", {}),
            chest(5, "All: Food", {}),
            chest(6, "All: Potion", {}),
            chest(7, nil, {}),
            chest(8, nil, {}),
            chest(9, nil, {}),
        }
        _G.__PLAN_STANDARD = organiser_service.plan_base_roles(standard, {})

        -- 3. Granular tier (20+ chests): unlocks Tier 3 bulk single-item chests (>= 3 stacks)
        local granular = {
            chest(1, "All: Component", {
                st_item("ITEM_VaultShard", "Vault Shard", { "Special", "Essence" }),
                st_item("ITEM_VaultShard", "Vault Shard", { "Special", "Essence" }),
                st_item("ITEM_VaultShard", "Vault Shard", { "Special", "Essence" }),
                st_item("ITEM_Leather1", "Soft Leather", { "Basic", "Leather" }),
                st_item("ITEM_Leather2", "Hard Leather", { "Basic", "Leather" }),
            }),
            chest(2, "All: Ore", {}),
            chest(3, "All: Wood", {}),
            chest(4, "All: Equipment", {}),
            chest(5, "All: Food", {}),
            chest(6, "All: Potion", {}),
        }
        for i = 7, 22 do
            granular[#granular + 1] = chest(i, nil, {})
        end
        _G.__PLAN_GRANULAR = organiser_service.plan_base_roles(granular, {})

        -- Sub-category score beats All: Component catch-all even when item carries Component + Leather
        local org = organiser_service
        local leather_item = st_item("ITEM_Leather1", "Soft Leather", { "Component", "Leather" })
        _G.__SCORE_COMP = org.rule_score(org.parse_label("All: Component"), leather_item)
        _G.__SCORE_LEATHER = org.rule_score(org.parse_label("All: Leather"), leather_item)
        """)
        p_starter = self.lua.eval("_G.__PLAN_STARTER")
        self.assertEqual(p_starter["tier"], "starter")
        starter_labels = [a["label"] for a in p_starter["assignments"].values()]
        self.assertTrue(all(lbl != "All: Leather" for lbl in starter_labels))

        p_standard = self.lua.eval("_G.__PLAN_STANDARD")
        self.assertEqual(p_standard["tier"], "standard")
        standard_labels = [a["label"] for a in p_standard["assignments"].values()]
        self.assertIn("All: Leather", standard_labels)
        self.assertIn("All: Metal", standard_labels)

        p_granular = self.lua.eval("_G.__PLAN_GRANULAR")
        self.assertEqual(p_granular["tier"], "granular")
        granular_labels = [a["label"] for a in p_granular["assignments"].values()]
        self.assertIn("All: Leather", granular_labels)
        self.assertIn("Vault Shard", granular_labels)

        self.assertEqual(self.lua.eval("_G.__SCORE_COMP"), 1.5)
        self.assertEqual(self.lua.eval("_G.__SCORE_LEATHER"), 2)

        # 4. Force replan overwrites plain manual names (like "Farming") while preserving "Trash"
        self.lua.execute(r"""
        local org = organiser_service
        local function chest(idx, label, slots)
            return {
                label = label,
                rule = label and org.parse_label(label) or nil,
                pos = { X = idx * 100, Y = 0, Z = 0 },
                d2 = (idx * 100) * (idx * 100),
                slots = slots or {},
                maxSlots = 20,
            }
        end
        local function st_item(id, name, cats)
            return { id = id, name = name, count = 50, maxStack = 99, categories = cats }
        end
        local mixed = {
            chest(1, "Farming", { st_item("ITEM_Seeds", "Flax Seed", { "Seed" }), st_item("ITEM_Seeds", "Flax Seed", { "Seed" }) }),
            chest(2, "Trash", {}),
            chest(3, "Old Box", {}),
            chest(4, "Stuff", {}),
            chest(5, "Things", {}),
            chest(6, "Random", {}),
            chest(7, "Extra", {}),
            chest(8, "Other", {}),
            chest(9, "Overflow", {}),
        }
        _G.__PLAN_KEEP = org.plan_base_roles(mixed, {})
        _G.__PLAN_FORCE = org.plan_base_roles(mixed, {}, { force_replan = true })
        """)
        p_keep = self.lua.eval("_G.__PLAN_KEEP")
        p_force = self.lua.eval("_G.__PLAN_FORCE")
        self.assertEqual(len(list(p_keep["assignments"].values())), 0)
        force_labels = [a["label"] for a in p_force["assignments"].values()]
        self.assertIn("All: Ore", force_labels)
        self.assertIn("All: Seed", force_labels)
        self.assertNotIn("Trash", force_labels)

    def test_label_suggestions_and_recommend_prioritise_bank_roles_over_single_items(self):
        self.lua.execute(r"""
        local function item(id, name, cat)
            return {
                Count = 10,
                ItemData = {
                    Name = { ToString = function() return name end },
                    MaxStackSize = 50,
                    GetFName = function() return { ToString = function() return id end } end,
                    ItemFilterTags = { GameplayTags = { ForEach = function(_, f)
                        f(nil, { get = function() return { TagName = { ToString = function() return "ItemFilter.Material." .. cat end } } end })
                    end } },
                }
            }
        end
        local slots = {
            item("ITEM_CopperOre", "Copper Ore", "Ore"),
            item("ITEM_Gypsum", "Gypsum", "Mineral"),
            item("ITEM_AshLogs", "Ash Logs", "Wood"),
        }
        _G.__TEST_CHEST_INV = {
            ItemSlots = { ForEach = function(_, fn)
                for i, it in ipairs(slots) do fn(i, { get = function() return it end }) end
            end },
        }
        _G.FindAllOf = function() return {} end
        """)
        inv = self.lua.eval("_G.__TEST_CHEST_INV")
        rec_label, rec_reason = self.organiser.recommend_chest_label(inv, None)
        self.assertEqual(rec_label, "All: Ore")
        self.assertIn("matching stack", rec_reason)

        suggestions = list(self.organiser.label_suggestions(inv, None).values())
        # Bank roles & categories appear BEFORE single item names like Ash Logs / Gypsum
        self.assertEqual(suggestions[0], "All: Ore")
        self.assertIn("All: Wood", suggestions[:8])
        self.assertIn("Misc", suggestions[:10])
        self.assertGreater(suggestions.index("Ash Logs"), suggestions.index("All: Ore"))

    def test_audit_fixes_multi_category_scoring_non_storage_prune_and_demand_first_planning(self):
        self.lua.execute(r"""
        local org = organiser_service
        -- 1. Broad crafting catch-alls (Component/Basic/Processed/Special) yield (1.5 vs 2)
        --    to ANY specific category (Herb, Essence, Metal), even with multiple categories
        local herb_with_comp = { id = "ITEM_Botanical_Harralander", name = "Harralander", categories = { "Basic", "Component", "Herb" } }
        _G.__SCORE_HERB = org.rule_score(org.parse_label("All: Herb"), herb_with_comp)
        _G.__SCORE_HERB_COMP = org.rule_score(org.parse_label("All: Component"), herb_with_comp)
        local pure_comp = { id = "ITEM_Gear_Part", name = "Brass Gear", categories = { "Component" } }
        _G.__SCORE_PURE_COMP = org.rule_score(org.parse_label("All: Component"), pure_comp)

        -- 2. Non-storage actors (CapeRack, WeaponRack, BP_Station_*) are filtered out of all_storage_in_reach
        --    and pruned from saved organiser labels
        local doc = package.loaded.rlm_store.get("organiser")
        doc.labels = {
            { name = "BP_BaseBuilding_CapeRack_C_1", label = "All: Ore", x = 10, y = 0, z = 0 },
            { name = "BP_Station_Spinning_Wheel_C_2", label = "All: Wood", x = 20, y = 0, z = 0 },
            { name = "BP_BaseBuilding_Chest_Iron_C_3", label = "All: Component", x = 30, y = 0, z = 0 },
        }
        package.loaded.rlm_engine.local_generation_allowed = function() return false, "RemoteClient" end
        local caperack = {
            GetAddress = function() return 501 end,
            GetFullName = function() return "BP_BaseBuilding_CapeRack_C_501" end,
            IsA = is_base_building,
            K2_GetActorLocation = function() return { X = 100, Y = 0, Z = 0 } end,
            LinkedInventoryComponent = { IsValid = function() return true end, bIsLocked = false },
        }
        local weaponrack = {
            GetAddress = function() return 502 end,
            GetFullName = function() return "BP_BaseBuilding_WeaponRack_C_502" end,
            IsA = is_base_building,
            K2_GetActorLocation = function() return { X = 150, Y = 0, Z = 0 } end,
            LinkedInventoryComponent = { IsValid = function() return true end, bIsLocked = false },
        }
        local real_chest = {
            GetAddress = function() return 503 end,
            GetFullName = function() return "BP_BaseBuilding_Chest_Iron_C_503" end,
            IsA = is_base_building,
            K2_GetActorLocation = function() return { X = 200, Y = 0, Z = 0 } end,
            LinkedInventoryComponent = { IsValid = function() return true end, bIsLocked = false },
        }
        _G.FindFirstOf = function(cls)
            if cls == "LinkedInventoryComponent" then return real_chest.LinkedInventoryComponent end
            return nil
        end
        _G.FindAllOf = function(cls)
            if cls == "InventoryComponent" then
                return {
                    { GetOwner = function() return caperack end, MaxSlotCount = 1, ItemSlots = { ForEach = function() end } },
                    { GetOwner = function() return weaponrack end, MaxSlotCount = 1, ItemSlots = { ForEach = function() end } },
                    { GetOwner = function() return real_chest end, MaxSlotCount = 64, ItemSlots = { ForEach = function() end } },
                }
            end
            return {}
        end
        _G.__FILTERED_CHESTS = org.all_storage_in_reach({ X = 0, Y = 0, Z = 0 }, { rangeMeters = 40, anyStorage = true })

        -- Force settings prune via M.locks() -> organiser_document()
        org.locks()
        _G.__AFTER_PRUNE_LEN = #doc.labels

        -- 3. Non-ITEM_Resources_* items still infer material categories when tagged BasicMaterial
        local mock_inv = {
            ItemSlots = { ForEach = function(_, fn)
                local item = {
                    Count = 10,
                    ItemData = {
                        Name = { ToString = function() return "Supple Leather" end },
                        MaxStackSize = 50,
                        GetFName = function() return { ToString = function() return "ITEM_Craft_SuppleLeather" end } end,
                        ItemFilterTags = { GameplayTags = { ForEach = function(_, f)
                            f(nil, { get = function() return { TagName = { ToString = function() return "ItemFilter.Material.BasicMaterial" end } } end })
                        end } },
                    }
                }
                fn(1, { get = function() return item end })
            end },
        }
        _G.__INFERRED_SLOTS = org.read_slots(mock_inv)

        -- 4. Demand-first planning on a 9-chest base skips empty zero-demand themes when tight
        local function mkchest(i, slots, cap)
            return { pos = { X = i * 100, Y = 0, Z = 0 }, d2 = i * i * 10000, slots = slots or {}, maxSlots = cap or 20 }
        end
        local slots_metal = {}
        for k = 1, 2 do slots_metal[#slots_metal + 1] = { id = "ITEM_Bar", name = "Mithril Bar", categories = { "Component", "Metal" } } end
        for k = 1, 2 do slots_metal[#slots_metal + 1] = { id = "ITEM_Herb", name = "Harralander", categories = { "Basic", "Herb" } } end
        local tight_base = {}
        tight_base[1] = mkchest(1, slots_metal)
        for i = 2, 8 do tight_base[i] = mkchest(i, {}) end
        _G.__PLAN_TIGHT = org.plan_base_roles(tight_base, {})
        """)
        self.assertEqual(self.lua.eval("_G.__SCORE_HERB"), 2)
        self.assertEqual(self.lua.eval("_G.__SCORE_HERB_COMP"), 1.5)
        self.assertEqual(self.lua.eval("_G.__SCORE_PURE_COMP"), 2)

        chests = list(self.lua.eval("_G.__FILTERED_CHESTS").values())
        self.assertEqual(len(chests), 1)
        self.assertEqual(chests[0]["actor"].GetAddress(), 503)
        self.assertEqual(self.lua.eval("_G.__AFTER_PRUNE_LEN"), 1)

        inferred_cats = list(self.lua.eval("_G.__INFERRED_SLOTS")[1]["categories"].values())
        self.assertIn("Basic", inferred_cats)
        self.assertIn("Leather", inferred_cats)

        tight_labels = [a["label"] for a in self.lua.eval("_G.__PLAN_TIGHT")["assignments"].values()]
        self.assertIn("All: Metal", tight_labels)
        self.assertIn("All: Herb", tight_labels)
        self.assertEqual(len(tight_labels), 8)

    def test_open_storage_handles_private_chest_and_hud_ignores_inactive_station_panel(self):
        self.lua.execute(r"""
        package.loaded.rlm_engine.local_generation_allowed = function()
            return false, "RemoteClient"
        end
        package.loaded.rlm_engine.local_controller = function()
            return {
                IsValid = function() return true end,
                GetPlayerId = function() return "PLAYER_LOCAL" end,
                GetCharacterGuid = function() return { A = 1, B = 2, C = 3, D = 4 } end,
            }
        end

        local priv_actor = {
            GetAddress = function() return 601 end,
            GetFullName = function() return "BP_BaseBuilding_Chest_Iron_C_601" end,
            IsA = is_base_building,
            K2_GetActorLocation = function() return { X = 100, Y = 0, Z = 0 } end,
            LinkedInventoryComponent = { IsValid = function() return true end, bIsLocked = false },
            OwnershipComponent = {
                IsValid = function() return true end,
                bIsPrivatelyOwned = true,
                OwningPlayerId = "PLAYER_LOCAL",
            },
        }
        local priv_inv = {
            GetOwner = function() return priv_actor end,
            MaxSlotCount = 20,
            ItemSlots = { ForEach = function() end },
        }
        local open_panel = {
            GetFullName = function() return "WBP_WorldActorInventory_MainPanel_C_601" end,
            IsActivated = function() return true end,
            IsVisible = function() return true end,
            WorldInventoryManagerAPI = {
                GetInventoryComponent = function() return priv_inv end,
                IsInitialized = function() return true end,
            },
        }
        _G.FindAllOf = function(cls)
            if cls == "WorldActorInventoryMainPanel" then return { open_panel } end
            if cls == "InventoryComponent" then return { priv_inv } end
            return {}
        end
        _G.FindFirstOf = function(cls)
            if cls == "LinkedInventoryComponent" then return priv_actor.LinkedInventoryComponent end
            return nil
        end
        local org = organiser_service
        local inv, actor, api, panel = org.open_storage()
        _G.__OPEN_OK = (inv == priv_inv) and (actor == priv_actor) and (panel == open_panel)
        _G.__REACH_COUNT = #org.all_storage_in_reach({ X = 0, Y = 0, Z = 0 }, { rangeMeters = 40, anyStorage = true })
        """)
        self.assertTrue(self.lua.eval("_G.__OPEN_OK"))
        self.assertEqual(self.lua.eval("_G.__REACH_COUNT"), 1)

    def test_open_storage_fallback_and_hud_async_backup_pump(self):
        hud_source = (MODULE_DIR / "rlm_organiser_hud.lua").read_text(encoding="utf-8")
        self.lua.execute(r"""
        local player_inv = { _kind = "player", MaxSlotCount = 40 }
        _G.__TEST_CONTROLLER = {
            InventoryComponent = player_inv,
            IsValid = function() return true end,
        }
        package.loaded.rlm_engine.local_controller = function() return _G.__TEST_CONTROLLER end

        _G.StaticFindObject = function(path)
            if path == "/Script/Dominion.BaseBuildingActor" then return nil end
            return { _path = path, IsValid = function() return true end }
        end

        local station_actor = { GetFullName = function() return "BP_Station_Workbench_C_1" end }
        local station_inv = { MaxSlotCount = 4, GetOwner = function() return station_actor end }
        local player_actor = { GetFullName = function() return "BP_PlayerCharacter_C_1" end }
        player_inv.GetOwner = function() return player_actor end

        local chest_actor = {
            GetAddress = function() return 901 end,
            GetFullName = function() return "BP_BaseBuilding_Chest_C_901" end,
            GetCustomName = function() return { ToString = function() return "Backup Chest" end } end,
            K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end,
        }
        local chest_inv = {
            MaxSlotCount = 24,
            GetOwner = function() return chest_actor end,
            ItemSlots = { ForEach = function() end },
        }

        local stale_visible_panel = {
            IsActivated = function() return false end,
            IsVisible = function() return true end,
            WorldInventoryManagerAPI = { GetInventoryComponent = function() return station_inv end },
        }
        local player_inv_panel = {
            IsActivated = function() return true end,
            IsVisible = function() return true end,
            WorldInventoryManagerAPI = { GetInventoryComponent = function() return player_inv end },
        }
        local active_chest_panel = {
            IsActivated = function() return true end,
            IsVisible = function() return true end,
            WorldInventoryManagerAPI = { GetInventoryComponent = function() return chest_inv end },
        }

        -- Visible station panel before active chest panel still resolves active chest even when BaseBuildingActor is nil
        _G.FindAllOf = function(cls)
            if cls == "WorldActorInventoryMainPanel" then
                return { stale_visible_panel, player_inv_panel, active_chest_panel }
            end
            return {}
        end
        local org = organiser_service
        local got_inv, got_actor, _, got_panel = org.open_storage()
        _G.__OPEN_ACTIVE_OK = (got_inv == chest_inv) and (got_actor == chest_actor) and (got_panel == active_chest_panel)

        -- Player inventory and non-storage actors are ignored when no chest panel is active
        _G.FindAllOf = function(cls)
            if cls == "WorldActorInventoryMainPanel" then
                return { stale_visible_panel, player_inv_panel }
            end
            return {}
        end
        _G.__OPEN_FILTERED_NIL = (org.open_storage() == nil)

        -- Restore active chest panel for HUD backup pump test
        _G.FindAllOf = function(cls)
            if cls == "WorldActorInventoryMainPanel" then return { active_chest_panel } end
            return {}
        end
        local async_callbacks = {}
        package.loaded.rlm_async = {
            after = function(delay, fn)
                async_callbacks[#async_callbacks + 1] = { delay = delay, fn = fn }
                return true
            end,
        }
        local function make_widget(kind)
            return {
                _cls = kind,
                Font = { Size = 12 },
                SetVisibility = function(self, v)
                    self._vis = v
                    if self._is_frame then _G.__BACKUP_HUD_VIS = v end
                end,
                GetChildrenCount = function() return 0 end,
                GetClass = function(self) return { GetFName = function() return { ToString = function() return self._cls end } end } end,
                AddChildToVerticalBox = function() return { SetPadding = function() end, SetHorizontalAlignment = function() end, SetVerticalAlignment = function() end } end,
                AddChildToHorizontalBox = function() return { SetPadding = function() end, SetHorizontalAlignment = function() end, SetVerticalAlignment = function() end } end,
                AddChildToOverlay = function() return { SetPadding = function() end, SetHorizontalAlignment = function() end, SetVerticalAlignment = function() end } end,
                AddChild = function() return { SetPadding = function() end } end,
                AddChildToCanvas = function() return {
                    SetAutoSize = function() end,
                    SetZOrder = function() end,
                    SetAnchors = function() end,
                    SetAlignment = function() end,
                    SetPosition = function() end,
                    SetSize = function(_, sz) _G.__DOCKED_PANEL_H = sz and sz.Y or nil end,
                } end,
                ForceLayoutPrepass = function() _G.__PREPASS_CALLED = true end,
                GetDesiredSize = function() return { X = 380, Y = 540 } end,
                SetText = function() end,
                SetLabelText = function() end,
                SetColorAndOpacity = function() end,
                SetFont = function() end,
                SetAutoWrapText = function() end,
                SetWrapTextAt = function() end,
                SetShadowOffset = function() end,
                SetShadowColorAndOpacity = function() end,
                SetIsSelectable = function() end,
                SetShouldSelectUponReceivingFocus = function() end,
                SetIsFocusable = function() end,
                SetWidthOverride = function() end,
                SetHeightOverride = function() end,
                SetRenderOpacity = function() end,
                RemoveFromParent = function() end,
                GetFullName = function() return kind .. "_inst" end,
            }
        end
        local frame_obj = make_widget("WBP_Panel_C")
        frame_obj._is_frame = true
        frame_obj.BackgroundPanel = make_widget("Image")
        frame_obj.PanelContent = make_widget("Overlay")
        frame_obj.WidgetTree = { RootWidget = make_widget("CanvasPanel") }
        local wbl = {
            Create = function(self, pc, cls)
                local p = cls and cls._path or ""
                if p:find("WBP_Panel", 1, true) then return frame_obj end
                return make_widget("WBP_DomAllCapsButton")
            end,
        }
        _G.StaticFindObject = function(path)
            if path == "/Script/UMG.Default__WidgetBlueprintLibrary" then return wbl end
            if path == "/Script/Dominion.BaseBuildingActor" then return nil end
            return { _path = path, IsValid = function() return true end }
        end
        local host_canvas = make_widget("CanvasPanel")
        local host_panel = make_widget("WBP_WorldActorInventory_MainPanel_C")
        host_panel.WidgetTree = { RootWidget = host_canvas }
        host_panel.IsActivated = function() return true end
        host_panel.IsVisible = function() return true end
        _G.StaticConstructObject = function(cls)
            local p = cls and cls._path or ""
            local k = p:match("([^.]+)$") or "Widget"
            return make_widget(k)
        end
        _G.LoadAsset = function() end
        _G.FText = function(s) return tostring(s) end
        _G.LoopInGameThreadWithDelay = function() return true end
        _G.FindFirstOf = function(cls)
            if cls == "WBP_WorldActorInventory_MainPanel_C" then return host_panel end
            return nil
        end
        _G.__RSDW_PUBLIC_ORGANISER_DOCK = nil
        _G.__BACKUP_HUD_VIS = nil
        _G.__ASYNC_CALLBACKS = async_callbacks
        """)

        hud = self.lua.globals().load(hud_source, "@rlm_organiser_hud.lua", "t")(self.organiser)
        self.lua.execute(r"""
        _G.__TMP_HUD = ...
        _G.__TMP_HUD.start({})
        for i = 1, 4 do
            _G.__RSDW_PUBLIC_ORGANISER_DOCK.last_tick_at = os.clock() - 1.0
            local cb = _G.__ASYNC_CALLBACKS[i]
            if cb then cb.fn() end
        end
        _G.__ASYNC_CALLBACK_COUNT = #_G.__ASYNC_CALLBACKS
        """, hud)

        self.assertTrue(self.lua.eval("_G.__OPEN_ACTIVE_OK"))
        self.assertTrue(self.lua.eval("_G.__OPEN_FILTERED_NIL"))
        self.assertGreaterEqual(self.lua.eval("_G.__ASYNC_CALLBACK_COUNT"), 1)
        self.assertEqual(self.lua.eval("_G.__BACKUP_HUD_VIS"), 0)
        self.assertTrue(self.lua.eval("_G.__PREPASS_CALLED"))
        self.assertEqual(self.lua.eval("_G.__DOCKED_PANEL_H"), 610)

    def test_auto_organise_syncs_blank_native_names_and_logs_rename_failure(self):
        self.lua.execute(r"""
        package.loaded.rlm_engine.local_generation_allowed = function() return true, "Standalone" end
        local renamed = {}
        local should_fail = false
        local pc = {
            IsValid = function() return true end,
            Pawn = { IsValid = function() return true end, K2_GetActorLocation = function() return { X = 0, Y = 0, Z = 0 } end },
            InventoryComponent = { IsValid = function() return true end, MaxSlotCount = 40, ItemSlots = { ForEach = function() end } },
            InventoryController = { IsValid = function() return true end },
            Server_SetObjectCustomName = function(self, actor, txt)
                if should_fail then error("rpc rejected") end
                renamed[actor:GetFullName()] = tostring(txt)
            end,
        }
        package.loaded.rlm_engine.local_controller = function() return pc end
        _G.FText = function(s) return tostring(s) end

        local doc = package.loaded.rlm_store.get("organiser")
        doc.labels = {
            { name = "BP_BaseBuilding_Chest_Iron_C_701", label = "All: Ore", x = 100, y = 0, z = 0 },
        }
        local chest1 = {
            GetAddress = function() return 701 end,
            GetFullName = function() return "BP_BaseBuilding_Chest_Iron_C_701" end,
            IsA = is_base_building,
            GetCustomName = function() return { ToString = function() return "" end } end,
            K2_GetActorLocation = function() return { X = 100, Y = 0, Z = 0 } end,
        }
        local chest2 = {
            GetAddress = function() return 702 end,
            GetFullName = function() return "BP_BaseBuilding_Chest_Iron_C_702" end,
            IsA = is_base_building,
            GetCustomName = function() return { ToString = function() return "Mining & Masonry" end } end,
            K2_GetActorLocation = function() return { X = 200, Y = 0, Z = 0 } end,
        }
        _G.FindAllOf = function(cls)
            if cls == "InventoryComponent" then
                return {
                    { GetOwner = function() return chest1 end, MaxSlotCount = 20, ItemSlots = { ForEach = function() end } },
                    { GetOwner = function() return chest2 end, MaxSlotCount = 20, ItemSlots = { ForEach = function() end } },
                }
            end
            return {}
        end
        _G.FindFirstOf = function() return nil end

        local org = organiser_service
        org.auto_organise_base({ force_replan = false })
        _G.__FILL_CHEST1 = renamed["BP_BaseBuilding_Chest_Iron_C_701"]
        _G.__FILL_CHEST2 = renamed["BP_BaseBuilding_Chest_Iron_C_702"]

        org.auto_organise_base()
        _G.__OVERRIDE_CHEST1 = renamed["BP_BaseBuilding_Chest_Iron_C_701"]
        _G.__OVERRIDE_CHEST2 = renamed["BP_BaseBuilding_Chest_Iron_C_702"]

        should_fail = true
        org.set_label(pc, chest1, "All: Wood")
        """)
        self.assertEqual(self.lua.eval("_G.__FILL_CHEST1"), "All: Ore")
        self.assertIsNone(self.lua.eval("_G.__FILL_CHEST2"))
        self.assertIsNotNone(self.lua.eval("_G.__OVERRIDE_CHEST1"))
        self.assertIsNotNone(self.lua.eval("_G.__OVERRIDE_CHEST2"))
        self.assertNotEqual(self.lua.eval("_G.__OVERRIDE_CHEST2"), "Mining & Masonry")
        logs = [str(v) for v in self.t["logs"].values()]
        self.assertTrue(any("chest rename RPC failed" in entry for entry in logs))


if __name__ == "__main__":
    unittest.main()
