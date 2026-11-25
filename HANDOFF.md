# Handoff

## Initial public package

Organiser 0.3.3 is packaged as a public Mod Manager module. Its manifest, adapter, storage service and dock are installed together under `Modules/Organiser`. The integrated build's loot chest fix is carried forward from commit `f046c86`.

The module starts and stops with the public host's runtime contract, reads and writes the module-owned `organiser.json` through the host store, and uses the host's existing scheduler for paced transfers. Reload reuses the dock timer and native hook registrations, cancels in-progress planning and rejects callbacks queued by the previous instance. Private shortcuts, the direct full-menu launcher and Magic XP bonuses are excluded. Trash incineration is off for new installations.

Offline on 25 November 2026, all 37 tests passed and every Lua and JSON file parsed. An isolated copy of published Mod Manager commit `8c8f885` discovered and started the folder, reused the dock timer and hooks on reload, and retained a setting in `organiser.json`. To repeat the unit tests, run `python -m unittest discover -s Tools/tests` with Python and `lupa`. The public installation and reload checklist remains pending in the game.
