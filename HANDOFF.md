# Handoff

## Organiser 0.3.5

- The chest sidebar uses the public shell's shared Graphite surface when
  available. The public module retains its own storage configuration and
  chest lifecycle. Live appearance in the public package is pending.

## Organiser 0.3.4: Docked chest open reliability & smarter bank sorting

Organiser 0.3.4 ports the verified docked-HUD and category-planning fixes into the public module (`Modules/Organiser/`), keeping `organiser.json` persistence and public boundary exclusions (no private shortcut bindings, full-menu shortcut button, or deposit Magic XP bonus; trash incineration off by default).

- `rlm_organiser.lua`: `open_storage()` iterates `pairs(panels)` prioritising `IsActivated() == true` over `IsVisible() == true`, and `storage_from_api()` avoids strict world-scan locks on already-open built chests while rejecting player inventory, loot/dungeon chests (`IsA(BaseBuildingActor)` when resolved), and `NON_STORAGE_PATTERNS` display props/stations. Broad crafting catch-alls (`Basic`, `Component`, `Processed`, `Special`, etc.) yield `1.5` vs `2` to any specific category on multi-category items, `infer_categories_from_identity()` covers tagged and untagged crafting items via `CRAFT_INFERENCE_RULES`, `organiser_document()` prunes stale rack/station labels, and `plan_base_roles()` uses demand-first role assignment and proportional bulk splits.
- `rlm_organiser_hud.lua`: adds `widget_is_active_or_visible()`, `refresh_hosts(open_panel)`, `station_is_visible()`, stale-frame removal on host switch, transition diagnostics via `diag_once()`, and an `rlm_async` backup tick pump when `LoopInGameThreadWithDelay` stalls.
- Unit suite in `Tools/tests/test_organiser.py` expanded from 37 to 40 Lua-backed tests (run `python -m unittest discover -s Tools/tests`). Standalone public [test plan](Docs/TEST_PLAN.md) checkboxes remain open for verification in a clean public install.
