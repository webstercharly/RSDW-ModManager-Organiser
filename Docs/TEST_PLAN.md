# In-game test plan

- [ ] With the public Mod Manager and Organiser as the only installed module, start a playable world. Check that Organiser is listed under **F7** and that its sidebar appears beside an open built chest.
- [ ] Open a built crate without a native custom name and check that the sidebar and Organiser tab render. Assign a category label, then restart and check it and an item retention rule persist.
- [ ] Open and close world and dungeon loot chests with automatic deposit enabled. Check that the standard loot panel appears, Organiser stays hidden and the backpack only changes when looting.
- [ ] Use deposit, sort and resort with a test inventory. Verify stack counts and retention rules. Repeat on a joined server, including an inaccessible private chest and a delayed replication update.
- [ ] Use Organise Base and check that existing labels are preserved. Use Re-plan All on a test base and check that eligible labels update. Open Base Advisor and read its recommendations.
- [ ] On a test chest with disposable items, enable trash incineration, mark the chest as Trash and close it. Check that only that chest's contents are removed. Confirm the same chest retains its contents when the option is disabled.
- [ ] Use Reload Mods several times, then open and close a built chest. Verify that only one sidebar appears. Remove Organiser and reload, then verify that the vanilla chest remains interactive and Organiser's saved file is still present.
