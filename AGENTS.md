# Agents

This repo's guide for any coding agent is `CLAUDE.md`. Read it first. It routes every change to the one document that governs it. The index of everything under `docs/` is `docs/README.md`.

Build and run mMac as "Change mMac or its backend" in `docs/changing-things.md` says. The gate is "Prove a change" in the same file. Run it in order, with `MUSE_BIN` set to the installed `muse`. There is no deploy.

Three rules an agent breaks most easily: never commit to `main` or push upstream (`main` mirrors upstream, and features go to the fork by PR); never let a test or a feature write Muse's config beyond its own entries (`~/.config/muse/trust.json` and `~/.config/muse/settings.json`); and never read or write Dom's Keychain item `com.domalhambra.mmac.bridge-token` from a test or a script.
