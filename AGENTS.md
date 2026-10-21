# Agents

This repo's guide for any coding agent is `CLAUDE.md`. Read it first. It routes every change to the one document that governs it. The index of everything under `docs/` is `docs/README.md`.

Develop with `npm run dev:isolated`. The gate is "Prove a change" in `docs/changing-things.md`. Run it in order, with `MUSE_BIN` set to the installed `muse`. There is no deploy.

Two rules an agent breaks most easily: never commit to `main` or push upstream (`main` mirrors upstream, and features go to the fork by PR), and never let a test or a feature write Muse's config beyond its own entries (`~/.config/muse/trust.json` and `~/.config/muse/settings.json`).
