# RSDW Mod Manager Organiser

Organiser is a storage module for RuneScape: Dragonwilds on PC. It adds a sidebar to built chests and an Organiser tab to [RSDW Mod Manager](https://github.com/webstercharly/RSDW-ModManager).

## Install

1. Install UE4SS and the public Mod Manager using the manager's installation guide.
2. Copy the whole `Modules/Organiser` folder into `RSDragonwilds/Binaries/Win64/ue4ss/Mods/RSDWModManager/Modules/`.
3. Start the game, or use **Reload Mods** if the public manager is already running.
4. Open a built chest for the bank-style interface, or press **F7** and select **Organiser** for chest search, settings, retention rules and the base advisor.

## Use

- Label built storage with an item name such as `Ash Logs`, a category such as `All: Ore`, or `Misc` to accept items already stored there.
- **Deposit Backpack** sends matching stacks to nearby labelled storage. Retention rules in **Carried Items & Locks** keep the quantity you specify. Automatic deposit is off by default.
- **Sort This Chest** consolidates partial stacks and sorts items in one chest. **Resort Nearby** moves misplaced stacks between labelled chests.
- **Organise Base** assigns roles to unlabelled storage. **Re-plan All** can replace existing labels. **Base Advisor** shows storage usage and suggests roles near workstations.
- **Find Items Across Chests** searches accessible nearby storage. Select a result to inspect its chest, withdraw one item or a stack, or place a temporary minimap pin when the public Map module is installed.
- The built-chest interface adds bank-style tabs, item search, paging and drag-aware item controls while preserving the game inventory as the transfer authority.
- Enable **Trash Container Incineration** in Organiser settings to use the `Trash` label. With that setting on, closing a built container labelled `Trash` destroys its contents.

World and dungeon loot chests open in the game's usual loot panel. On joined servers, Organiser paces transfers and waits for inventory updates before proceeding.

Settings, external labels and retention rules are stored in `%LOCALAPPDATA%\RSDWModManager\organiser.json`. Removing the module leaves that file and any native chest names in place.

## Version 0.3.6

Adds the public chest explorer and bank-style built-storage interface, including nearby chest inspection, cross-chest item search, controlled withdrawals, minimap pin handoff, generated interface artwork and reload-safe HUD ownership. These features are self-contained and do not depend on private shortcut or cheat modules.

## Version 0.3.5

The chest sidebar uses the shared Graphite backing when installed with the
current public Mod Manager.

## Version 0.3.4

Improves docked chest detection (`open_storage()` prioritises active panels and cleanly validates open storage, while the HUD backs up `LoopInGameThreadWithDelay` with an `rlm_async` pump, re-checks active station visibility, removes stale dock frames on host switch, and logs state transitions), refines crafting material inference and broad-category scoring, prunes non-storage display props (racks, pedestals, trophies, stations), and improves demand-first base role planning. Forty Lua-backed unit tests pass cleanly. The [in-game checklist](Docs/TEST_PLAN.md) remains open for standalone public verification.

Inspired by RuneSort from darksparrow. Organiser is an independent implementation. MIT, see [LICENSE](LICENSE).
