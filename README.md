# RSDW Mod Manager Organiser

Organiser is a storage module for RuneScape: Dragonwilds on PC. It adds a sidebar to built chests and an Organiser tab to [RSDW Mod Manager](https://github.com/webstercharly/RSDW-ModManager).

## Install

1. Install UE4SS and the public Mod Manager using the manager's installation guide.
2. Copy the whole `Modules/Organiser` folder into `RSDragonwilds/Binaries/Win64/ue4ss/Mods/RSDWModManager/Modules/`.
3. Start the game, or use **Reload Mods** if the public manager is already running.
4. Open a built chest for the sidebar, or press **F7** and select **Organiser** for settings, retention rules and the base advisor.

## Use

- Label built storage with an item name such as `Ash Logs`, a category such as `All: Ore`, or `Misc` to accept items already stored there.
- **Deposit Backpack** sends matching stacks to nearby labelled storage. Retention rules in **Carried Items & Locks** keep the quantity you specify. Automatic deposit is off by default.
- **Sort This Chest** consolidates partial stacks and sorts items in one chest. **Resort Nearby** moves misplaced stacks between labelled chests.
- **Organise Base** assigns roles to unlabelled storage. **Re-plan All** can replace existing labels. **Base Advisor** shows storage usage and suggests roles near workstations.
- Enable **Trash Container Incineration** in Organiser settings to use the `Trash` label. With that setting on, closing a built container labelled `Trash` destroys its contents.

World and dungeon loot chests open in the game's usual loot panel. On joined servers, Organiser paces transfers and waits for inventory updates before proceeding.

Settings, external labels and retention rules are stored in `%LOCALAPPDATA%\RSDWModManager\organiser.json`. Removing the module leaves that file and any native chest names in place.

## Version 0.3.3

First public source version. Includes the built-storage check and the fix for opening the panel beside storage without a native custom name. Thirty-seven Lua-backed tests passed, covering inventory planning, joined-server transfer timing, the loot chest regression and reload. The [in-game checklist](Docs/TEST_PLAN.md) is pending.

Inspired by RuneSort from darksparrow. Organiser is an independent implementation. MIT, see [LICENSE](LICENSE).
