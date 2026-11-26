# In-game test plan

- [ ] With the public Mod Manager and Organiser as the only installed module, start a playable world. Check that Organiser is listed under **F7** and that its sidebar appears beside an open built chest.
- [ ] Open a built crate without a native custom name and check that the sidebar and Organiser tab render. Assign a category label, then restart and check it and an item retention rule persist.
- [ ] Open and close world and dungeon loot chests with automatic deposit enabled. Check that the standard loot panel appears, Organiser stays hidden and the backpack only changes when looting.
- [ ] Use deposit, sort and resort with a test inventory. Verify stack counts and retention rules. Repeat on a joined server, including an inaccessible private chest and a delayed replication update.
- [ ] Use Organise Base and check that existing labels are preserved. Use Re-plan All on a test base and check that eligible labels update. Open Base Advisor and read its recommendations.
- [ ] On a test chest with disposable items, enable trash incineration, mark the chest as Trash and close it. Check that only that chest's contents are removed. Confirm the same chest retains its contents when the option is disabled.
- [ ] Use Reload Mods several times, then open and close a built chest. Verify that only one sidebar appears. Remove Organiser and reload, then verify that the vanilla chest remains interactive and Organiser's saved file is still present.
- [ ] Open two or more nearby built chests containing distinct items. In **F7 > Organiser > Find Items Across Chests**, search for each item, inspect its source chest, then withdraw one and withdraw a stack. Confirm only the selected item/count moves and joined-server transfers wait for replication.
- [ ] With the public Map module installed, pin a chest from a search result and verify the temporary destination appears. Remove Map, reload, and verify Organiser reports that pinning is unavailable without affecting chest search or withdrawal.
- [ ] Open a built chest and exercise the bank-style tabs, item search, page navigation and a drag interaction. Close and reopen it, then reload mods repeatedly; confirm one HUD remains, vanilla input is usable and no stale bank panel survives a closed chest.
