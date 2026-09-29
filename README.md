# Aptsy

Aptsy learns how you work with coding agents and keeps that on your machine. It reads chats from Claude Code, Cursor, Codex, Hermes, Goose, and OpenHands, and can hand relevant notes back to the agent.

The command is `aptsy`. Your chats and notes stay under `~/.aptsy`.

## Install

macOS and Linux (`amd64` or `arm64`):

```bash
curl -fsSL https://raw.githubusercontent.com/selfship-ai/aptsy/main/install.sh | bash
```

The script picks the matching release, installs `aptsy` and the hook helper, starts the daemon, then asks which tools to set up. MCP entries are written after the server is already listening.

- Pin a version with `APTSY_VERSION=v0.1.0`.
- Add `--non-interactive` to skip the questions. That installs into `/usr/local/bin` when you can write there, otherwise `~/.local/bin`, starts the daemon, then configures every tool it finds.
- Run it as yourself. It writes config in your home directory and asks for sudo only when copying `aptsy` into `/usr/local/bin` or registering the boot service.

On Windows, use the zip from the [releases](https://github.com/selfship-ai/aptsy/releases) page.

## Use

```bash
aptsy init      # find installed agents, write hooks and config; MCP entries wait until the server is up
aptsy start     # run in the background, and start again at boot
aptsy stop      # stop until the next boot or aptsy start
aptsy uninstall # remove Aptsy from this machine
aptsy status    # check that it is up
aptsy version
```

`aptsy start` returns as soon as the daemon is up. It does not stay in the terminal. On Linux it installs a systemd service so Aptsy starts when the machine boots. On macOS it installs a launchd daemon that does the same. The first start asks for your password so it can register that service. There is no foreground mode.

After init, use your coding agent as usual. Aptsy records the session and builds a local playbook from it.

To re-read chats that were captured by an older version:

```bash
aptsy sync --rebuild
```

That replaces Aptsy's copy of those chats with a fresh read from each tool. Lessons already in the playbook are kept. If a tool no longer has the chat, that copy is left as it is. Add `--tool claude_code` (or `cursor`, `codex`, `hermes`, `goose`, `openhands`) to limit the command to one tool.

Check what has been learned:

```bash
aptsy learn status
```

## Where files live

| Path | What it is |
|------|------------|
| `~/.aptsy/config.yml` | Config written by `aptsy init` |
| `~/.aptsy/ingest_data/` | Local database |
| `~/.aptsy/aptsy.pid` | Process id of the daemon |
| macOS: `~/Library/Logs/aptsy.log` | Log file |
| Linux: `/var/log/aptsy/aptsy.log` | Log file |
| `~/.aptsy/hooks/aptsy-bridge` | Helper the agent hooks run |

Aptsy listens on `127.0.0.1:8787` for hooks and `127.0.0.1:8788/mcp` for MCP. MCP entries are written only after that server is listening, either at the end of `aptsy init` or by `aptsy start` if init ran first.

Set `APTSY_TOKEN` if you want that secret required on both local ports. Leave it unset when only you can reach this machine.

Set `OPENAI_API_KEY` to let Aptsy write lessons with a model. `OPENAI_BASE_URL` and `OPENAI_CHAT_MODEL` override the endpoint and model. With no key, Aptsy still records chats.

## Upgrade

Run the install command again. It replaces `aptsy` and `aptsy-bridge` and leaves an existing config in place unless you ask it to set the hooks up again. Restart a daemon that was already running so it picks up the new binary.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/selfship-ai/aptsy/main/install.sh | bash -s -- --uninstall
```

If `aptsy` is already on your PATH:

```bash
aptsy uninstall
```

That stops the boot service, removes the hook and MCP entries Aptsy added, and deletes `~/.aptsy`, the log file, and the `aptsy` command. `aptsy uninstall` asks before it deletes anything. The install-script command does not ask again.
