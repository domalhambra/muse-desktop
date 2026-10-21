# Bridges

A bridge lets another agent ask Muse Code to do work through Muse Desktop. The other agent can be Meta's Muse app, a script, or any MCP client. Muse Desktop runs each request as a normal Muse Code conversation. The conversation appears in the sidebar, and its approvals and questions appear in the window.

There are two bridges. Both use the same core (`src/main/agent-api.ts`), so they accept the same requests and report the same job states.

| Bridge        | Use it when                                               | Transport                                           |
| ------------- | --------------------------------------------------------- | --------------------------------------------------- |
| Folder bridge | The other agent can read and write files on this computer | Markdown files in a folder                          |
| MCP bridge    | The other agent is an MCP client                          | Streamable HTTP on `127.0.0.1`, with a bearer token |

Both bridges are off by default. Turn them on in **Settings → Bridges**.

## What a bridge can do

A bridge can only work in a trusted project from the Muse Desktop project list (the 30 most recent projects). It can also continue an existing conversation in such a project. Everything else is a Muse Code feature that the bridge passes through:

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

Muse Desktop keeps the folder in its application data, as `bridge/` next to `preferences.json`. On macOS that is `~/Library/Application Support/muse-desktop/bridge`. **Settings → Bridges → Open bridge folder** opens it. The folder contains a `README.md` with a short version of this section, for the other agent to read.

### Ask for work

Write a Markdown file into `inbox/`. Put the settings in YAML frontmatter and the prompt below it:

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
| `project`  | Yes, unless `session` is given | A trusted project from the Muse Desktop project list                          |
| `session`  | No                             | An existing session id, to continue that conversation                         |
| `effort`   | No                             | `none`, `minimal`, `low`, `medium` (default), `high`, `xhigh`, `max`, `ultra` |
| `mode`     | No                             | `queue` (default) or `steer`, for a conversation that is working              |
| `model`    | No                             | A Muse Code model id                                                          |
| `worktree` | No                             | `true` to run in a new Git worktree that Muse creates                         |

Muse Desktop moves the request to `inbox/processed/` as soon as it reads it. If Muse Desktop cannot start the job, it moves the request to `inbox/rejected/` and writes a `.error.txt` file that gives the reason. Examples are a missing field or an untrusted project. A turn that fails after it starts stays in `processed/`, and its outbox file shows `status: error`.

### Read the result

Muse Desktop writes `outbox/<same file name>.md` and rewrites it while the job runs. The frontmatter gives the job id, the session id, and the status. The **Reply** section holds Muse's answer. The **Transcript** section holds every step of the turn. Read the file until the status is `done`, `error` or `cancelled`.

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

For a question with options, an answer that matches an option label selects that option. Separate labels with commas for a multiple-choice question. Any other answer goes to Muse as free text. Muse Desktop moves each decision file to `decisions/processed/`. A decision that fails leaves `decisions/<job id>.error.txt`.

## MCP bridge

1. Open **Settings → Bridges**.
2. Click **Make token**. Copy the token. Muse Desktop shows it only once.
3. Turn on **MCP bridge**.
4. Give the client the URL `http://127.0.0.1:7735/mcp` and the header `Authorization: Bearer <token>`.

Change the port in the same tab. **Copy token** copies the current token later. **Make new token** replaces the token at once, so clients that use the old token lose access.

| Tool            | Does                                                                                                                      |
| --------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `list_projects` | Lists the projects the bridge accepts.                                                                                    |
| `list_sessions` | Lists recent conversations in those projects, including their worktrees.                                                  |
| `list_models`   | Lists the models the installed Muse Code offers.                                                                          |
| `ask_muse`      | Starts a job. Takes `project` or `session`, `prompt`, `effort`, `mode`, `model`, `worktree` and `wait_seconds`.           |
| `get_job`       | Returns the job status, the reply, and pending approvals and questions. Add `include_transcript` for the full transcript. |
| `list_jobs`     | Lists recent jobs since Muse Desktop started, up to 200.                                                                  |
| `approve`       | Decides an approval with a `choiceId` from `get_job`.                                                                     |
| `answer`        | Answers a question. The answer follows the rules in the folder bridge's Decide section.                                   |
| `cancel`        | Stops the job's turn.                                                                                                     |

`ask_muse` and `get_job` take `wait_seconds`, up to 120. The call then returns when the job finishes, needs a decision, or the time ends. This removes most polling.

## Teaching Muse for Mac

Paste this block into the Muse app as an instruction or a skill. Replace the folder path with the path that **Open bridge folder** shows.

```text
You can ask Muse Code, a coding agent on this Mac, to work in a code project.
Use the bridge folder at /Users/<you>/Library/Application Support/muse-desktop/bridge.

To ask for work, write a new Markdown file in inbox/. Use a short, unique file name.
Start the file with this frontmatter, then write the task below it:
---
project: <absolute path of a trusted project in Muse Desktop>
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

## Security

- A bridge accepts work only for trusted projects in the Muse Desktop project list, and for conversations in those projects. Worktrees count as part of their project. A project that drops off the list of 30 recent projects loses bridge access until you open it again.
- The MCP bridge listens on `127.0.0.1` only. Every request must carry the bearer token. Muse Desktop compares the token in constant time.
- The token is not stored in the preferences. Muse Desktop keeps it in the `bridge-token` file, encrypted with Electron `safeStorage`. On macOS that uses the Keychain. On Linux, `safeStorage` can fall back to a weak built-in key. When `safeStorage` is not available, the file holds the token as plain text with permissions for your user only.
- Muse Desktop creates the bridge folder with permissions for your user only, and writes its own files the same way. Files that another agent writes keep the permissions that agent gives them. Any program that runs as your user can write requests into the folder. Turn the folder bridge off when you do not use it.
- Muse Code applies its usual sandbox and approval rules to bridge jobs. A bridge decides an approval with one of the choices Muse offers, and Muse checks the choice.
