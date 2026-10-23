# Security

The supported development line is 0.1.x. Use the [private reporting form](https://github.com/robzilla1738/muse-desktop/security/advisories/new) to contact Robert Courson. Use **Security → Report a vulnerability** to contact the maintainers privately; if unavailable, request a private reporting channel without posting exploit details or personal data.

Include the app and CLI versions, platform, minimal reproduction, impact, and whether the issue crosses the boundary between mMac and its backend, a project-file boundary, or an approval boundary. Do not include tokens, production transcripts, or a user's home-directory contents.

## Boundaries

- mMac draws its UI natively. It has no web content, no webviews and no remote navigation. Links in replies open in the default browser after a click, and only web links stay links. Images in replies never load.
- The backend is a child process of mMac. It talks to mMac only over stdin and stdout, and validates every request's arguments. It opens no network port, except the MCP bridge on `127.0.0.1` when that bridge is on.
- File previews resolve real paths inside explicitly selected projects. Directory listing skips symlinks and dependency folders. File and output previews have size limits. Pasted images and voice recordings cross to the backend as paths to private temporary files: a folder with mode 0700 and a file with mode 0600. Files chosen with the paperclip, dropped on the composer or pasted from Finder cross as the person's own paths, read where they are. The backend checks that each path is a regular file within the size limits before it reads it. Export writes the path the person chose in the save panel, with mode 0600.
- Muse Code runs with the user's inherited environment and credentials. A native project trust prompt gates session creation and resume. The app passes `--trust-workspace` only because it performs that desktop trust step; it does not disable sandboxing or tool approvals.
- Approval decisions require a currently pending server-issued choice and requirement token. The GUI never automatically approves a tool call.
- Preferences use atomic writes and restrictive file permissions. The MCP bridge token lives in the login Keychain. No analytics or crash upload is configured. Muse Code has its own separate network and data behavior.

The app is a coding-agent interface, so a trusted project and an approved CLI action can modify files and run processes using the CLI's configured permissions. A project trust prompt is not a substitute for the CLI's sandbox.

mMac has no updater. It runs from a checkout that you build.
