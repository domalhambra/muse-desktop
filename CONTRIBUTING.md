# Contributing

Upstream Muse Desktop is created and maintained by [Robert Courson (@robzilla1738)](https://github.com/robzilla1738). Meta does not maintain or support it. This fork is Dom Alhambra's, and its app is mMac, a native macOS app over upstream's Node core. Third-party dependency and asset credits remain in NOTICE.md.

Use macOS 15 or newer, Xcode, XcodeGen and Node.js 22.12 or newer, and run `npm ci`. Build mMac as "Change mMac or its backend" in `docs/changing-things.md` says. Install Muse Code separately.

Keep changes focused. Include a screenshot for appearance changes, describe the user-visible behavior, and explain how it was checked. Interface copy uses sentence case, explicit actions, and the same terms across menus, windows and alerts: **project**, **conversation**, **Muse Code**, **Settings**, **Send**, and **New line**.

Before submitting, run `npm run format`, then the gate in "Prove a change" in `docs/changing-things.md`. Unit tests run without the CLI. The integration and headless scripts and the UI tests need Muse Code, and use its echo provider with isolated temporary storage. Never add real transcripts, credentials, personal project paths, environment dumps, or account details to fixtures or screenshots.

Keep privileged work in the backend. A new backend method validates its arguments with zod in `src/headless/backend.ts`, accepts file paths only inside a project mMac knows, and gets a typed Swift call in `mac/Packages/MuseBackend/`. Three methods take paths outside a project, and each checks its path before it uses it: `attachments` reads files the person chose or dropped, `voice` reads and deletes a recording mMac wrote, and `export` writes the file the person chose in the save panel. Never add a method that runs an arbitrary shell command, reads any other path outside a selected project, or returns a credential.

For protocol upgrades, update the pinned SDK, run the real-CLI tests, inspect schema fingerprint warnings, and update the compatibility record. Keep approvals user-driven and preserve server-supplied requirement IDs and choice IDs. Do not change a user's permission profile as a side effect of a UI feature.

Open an issue for substantial changes before implementation. Use the repository's private security reporting feature for security-sensitive findings; see `SECURITY.md`.
