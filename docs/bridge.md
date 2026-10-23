# Bridges

A bridge lets another agent ask Muse Code to do work through mMac. The other agent can be Meta's Muse app, a script, or any MCP client. mMac runs each request as a normal Muse Code conversation. The conversation appears in the sidebar, and its approvals and questions appear in the window.

There are two bridges. Both use the same core (`src/main/agent-api.ts`), so they accept the same requests and report the same job states.

| Bridge        | Use it when                                               | Transport                                           |
| ------------- | --------------------------------------------------------- | --------------------------------------------------- |
| Folder bridge | The other agent can read and write files on this computer | Markdown files in a folder                          |
| MCP bridge    | The other agent is an MCP client                          | Streamable HTTP on `127.0.0.1`, with a bearer token |

Both bridges are off by default. Turn them on in **Settings → Bridges**.

## What a bridge can do

A bridge can only work in a trusted project from the mMac project list (the 30 most recent projects). It can also continue an existing conversation in such a project. Everything else is a Muse Code feature that the bridge passes through:

- Start a conversation, or send the next turn to an existing one.
- Choose the reasoning effort, the model, and queue or steer for a busy conversation.
- Run the conversation in a new Git worktree that Muse Code creates.
- Read Muse's reply, the full transcript, and the job status.
- Decide an approval, answer a question from Muse, or cancel the turn.

A job is one prompt sent as one turn. A conversation has one active job at a time.

| Status             | Meaning                                                                     |
| ------------------ | --------------------------------------------------------------------------- |
| `running`          | Muse is working.                                                            |
| `waiting-approval` | Muse needs an approval. Decide it through the bridge or in the window.      |
| `waiting-input`    | Muse asked a question. Answer it through the bridge or in the window.       |
| `done`             | The turn finished. Read the reply.                                          |
| `error`            | The turn failed. The job carries the error.                                 |
| `cancelled`        | The bridge cancelled the turn. A turn stopped in the window ends as `done`. |

## Folder bridge

mMac keeps the folder in its data folder, next to its preferences: `~/Library/Application Support/mMac/bridge`. `MMAC_DATA_FOLDER` moves the data folder, and the bridge folder with it. **Settings → Bridges → Open bridge folder** opens it. The folder contains a `README.md` with a short version of this section, for the other agent to read.

### Ask for work

Write a Markdown file into `<bridge folder>/inbox/`. Put the settings in YAML frontmatter and the prompt below it:

```md
---
project: /Users/dom/code/myrepo
effort: medium
worktree: false
---

Add a README section that describes the install steps.
```

| Field      | Required                       | Values                                                                        |
| ---------- | ------------------------------ | ----------------------------------------------------------------------------- |
| `project`  | Yes, unless `session` is given | A trusted project from the mMac project list                                  |
| `session`  | No                             | An existing session id, to continue that conversation                         |
| `effort`   | No                             | `none`, `minimal`, `low`, `medium` (default), `high`, `xhigh`, `max`, `ultra` |
| `mode`     | No                             | `queue` (default) or `steer`, for a conversation that is working              |
| `model`    | No                             | A Muse Code model id                                                          |
| `worktree` | No                             | `true` to run in a new Git worktree that Muse creates                         |

mMac moves the request to `<bridge folder>/inbox/processed/` as soon as it reads it. If mMac cannot start the job, it moves the request to `<bridge folder>/inbox/rejected/` and writes `<bridge folder>/inbox/rejected/<name>.error.txt`, which gives the reason. Examples are a missing field or an untrusted project. A turn that fails after it starts stays in `<bridge folder>/inbox/processed/`, and its outbox file shows `status: error`.

### Read the result

mMac writes `outbox/<same file name>.md` and rewrites it while the job runs. The frontmatter gives the job id, the session id, and the status. The **Reply** section holds Muse's answer. The **Transcript** section holds every step of the turn. Read the file until the status is `done`, `error` or `cancelled`.

### Decide

When the status is `waiting-approval` or `waiting-input`, the outbox file lists what Muse is waiting for. Write `decisions/<job id>.md` with one of these frontmatters:

```md
---
approvalId: a1
choiceId: c1
---
```

```md
---
userInputId: q1
questionId: pick
answer: Option label, or short free text
---
```

```md
---
cancel: true
---
```

For a question with options, an answer that matches an option label selects that option. Separate labels with commas for a multiple-choice question. Any other answer goes to Muse as free text. mMac moves each decision file to `<bridge folder>/decisions/processed/`. A decision that fails leaves `<bridge folder>/decisions/<job id>.error.txt`.

## MCP bridge

1. Open **Settings → Bridges**.
2. Click **Make token**. Copy the token. mMac shows it only once.
3. Turn on **MCP bridge**.
4. Give the client the URL `http://127.0.0.1:7735/mcp` and the header `Authorization: Bearer <token>`.

Change the port in the same pane. **Copy token** copies the current token later. **Make new token** replaces the token at once, so clients that use the old token lose access.

| Tool            | Does                                                                                                                      |
| --------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `list_projects` | Lists the projects the bridge accepts.                                                                                    |
| `list_sessions` | Lists recent conversations in those projects, including their worktrees.                                                  |
| `list_models`   | Lists the models the installed Muse Code offers.                                                                          |
| `ask_muse`      | Starts a job. Takes `project` or `session`, `prompt`, `effort`, `mode`, `model`, `worktree` and `wait_seconds`.           |
| `get_job`       | Returns the job status, the reply, and pending approvals and questions. Add `include_transcript` for the full transcript. |
| `list_jobs`     | Lists recent jobs since mMac started, up to 200.                                                                          |
| `approve`       | Decides an approval with a `choiceId` from `get_job`.                                                                     |
| `answer`        | Answers a question. The answer follows the rules in the folder bridge's Decide section.                                   |
| `cancel`        | Stops the job's turn.                                                                                                     |

`ask_muse` and `get_job` take `wait_seconds`, up to 120. The call then returns when the job finishes, needs a decision, or the time ends. This removes most polling.

## Teaching Muse for Mac

Paste this block into the Muse app as an instruction or a skill. Replace the folder path with the path that **Open bridge folder** shows.

```text
You can ask Muse Code, a coding agent on this Mac, to work in a code project.
Use the bridge folder at /Users/<you>/Library/Application Support/mMac/bridge.

To ask for work, write a new Markdown file in inbox/. Use a short, unique file name.
Start the file with this frontmatter, then write the task below it:
---
project: <absolute path of a trusted project in mMac>
effort: medium
---

Then read outbox/<the same file name>. Wait a few seconds between reads.
Stop when its status is done, error or cancelled. The Reply section holds the answer.

If the status is waiting-approval, tell me what Muse wants to do and ask me.
To approve, write decisions/<job id>.md with approvalId and choiceId in its frontmatter.
Never approve a destructive command without my confirmation.
```

When the Muse app speaks MCP, use the MCP bridge instead. Give it the URL and the bearer token from **Settings → Bridges**.

## Reaching the MCP bridge from Meta's Muse cloud

Test this first: Muse for Mac can perhaps reach `127.0.0.1` through its local agent. Then no tunnel is necessary. If it cannot, use the folder bridge, which needs no network.

Muse custom connectors that run in Meta's cloud cannot reach `127.0.0.1` on your Mac. They also cannot reach a private tailnet. A cloud connector needs a public HTTPS URL, and a public URL exposes the bridge to the internet with the bearer token as its only protection. This document does not recommend that setup. Decide it deliberately if you need it.

Tailscale Serve is the right tool for MCP clients on your own devices. It makes the bridge available inside your tailnet only:

```sh
tailscale serve --bg --https=443 http://127.0.0.1:7735
```

Then give the client:

- URL: `https://<machine>.<tailnet>.ts.net/mcp`
- Header: `Authorization: Bearer <token>`

To stop serving, run `tailscale serve --https=443 off`. Tailscale Funnel is the public variant of the same command. Do not use it with this bridge unless you accept the exposure above.

## The token

mMac keeps the MCP bridge token in the login Keychain, as a generic password with the service `com.domalhambra.mmac.bridge-token` and the account `mcp-bridge`. mMac reads it before each backend start and sends it in `start`. The backend keeps it in memory only. **Make new token** writes the new token back to the Keychain. Debug builds can use another service, named in `MMAC_KEYCHAIN_SERVICE` (see `docs/changing-things.md`).

The installed Electron Muse Desktop, if you still run it, also uses port 7735 for its MCP bridge by default. Run the MCP bridge in one app at a time. If the port is in use, the Bridges pane shows "Port 7735 is in use. Choose another port."

To read the token without mMac, run this in Terminal:

```sh
security find-generic-password -s com.domalhambra.mmac.bridge-token -a mcp-bridge -w
```

Warning: macOS asks for your login password first, because `security` is not on the item's access list. **Copy token** in the Bridges pane gives the same token with no prompt.

mMac is signed ad hoc, so each rebuild of mMac has a new code identity. The Keychain item trusts only the build that made it. After a rebuild, mMac asks for your login password when it reads the token at launch. Choose **Always Allow**. A stable signing identity, such as an Apple Development certificate, would stop this prompt.

If the Keychain refuses a new token, the MCP bridge still uses it. **Copy token** copies it until mMac or its backend restarts, and a warning row says so. After a restart, agents that use that token lose access. Make a new token to try the save again.

## Security

- A bridge accepts work only for trusted projects in the mMac project list, and for conversations in those projects. Worktrees count as part of their project. A project that drops off the list of 30 recent projects loses bridge access until you open it again.
- The MCP bridge listens on `127.0.0.1` only. Every request must carry the bearer token. mMac compares the token in constant time.
- The token is not stored in the preferences. mMac keeps it in the login Keychain (see "The token"). `src/main/bridge-token.ts`, the Electron app's encrypted token file, stays in the core, and mMac does not use it.
- mMac creates the bridge folder with permissions for your user only, and writes its own files the same way. Files that another agent writes keep the permissions that agent gives them. Any program that runs as your user can write requests into the folder. Turn the folder bridge off when you do not use it.
- Muse Code applies its usual sandbox and approval rules to bridge jobs. A bridge decides an approval with one of the choices Muse offers, and Muse checks the choice.
