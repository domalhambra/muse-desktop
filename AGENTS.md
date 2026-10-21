# Agents

This repo's guide for any coding agent is `CLAUDE.md`. Read it first. It routes every change to the one document that governs it. The index of everything under `docs/` is `docs/README.md`.

Develop with `npm run dev:isolated`. The gate: `npm run typecheck`, `npm test`, `npm run build`, `npm run format:check`, then `npm run test:integration`, `npm run test:headless` and `npm run test:e2e` with `MUSE_BIN` set to the installed `muse`, then `swift test` and the `xcodebuild` build in `docs/changing-things.md`. Restore `docs/screenshots` after the e2e run. There is no deploy.

Two rules an agent breaks most easily: never commit to `main` or push upstream (`main` mirrors upstream, and features go to the fork by PR), and never let a test or a feature write Muse's config beyond its own entries (`~/.config/muse/trust.json` and `~/.config/muse/settings.json`).
