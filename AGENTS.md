# Agent entry point

This repository owns the public Organiser module for RSDW Mod Manager. It must
remain drop-in compatible with the public shell and self-contained under
Modules/Organiser.

Before changing game-facing code, read the public Manager's AGENTS.md, module
contract, mod-development skill, stability rules, and relevant knowledge-base
guides.

Public boundaries:

- no private shortcut or cheat service;
- no XP reward, teleport, spawn, or opaque executor;
- explicit inventory/storage operations must preserve role, capacity, lock,
  reload, and verification safeguards;
- start and stop remain idempotent across Reload Mods.

Run Tools/Test-PublicPackage.ps1 before handoff. Keep live Dragonwilds results
separate from Lua/JSON, mocked, artwork, and boundary validation.
