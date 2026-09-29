# Aptsy

Aptsy learns how you work with coding agents and keeps that on your machine. It reads chats from Claude Code, Cursor, Codex, Hermes, Goose, and OpenHands, and can hand relevant notes back to the agent.

The command is `sslearn`. Your chats and notes stay under `~/.selfship`.

## Install

macOS and Linux (`amd64` or `arm64`):

```bash
curl -fsSL https://raw.githubusercontent.com/selfship-ai/aptsy/main/install.sh | bash
```

The script picks the matching release, installs `sslearn` and the hook helper, then asks which tools to set up and whether to start.

- Pin a version with `SSLEARN_VERSION=v0.1.0`.
- Add `--non-interactive` to skip the questions. That installs into `/usr/local/bin` when you can write there, otherwise `~/.local/bin`, configures every tool it finds, and does not start the daemon.
- Run it as yourself. It writes config in your home directory and asks for sudo only when copying `sslearn` into `/usr/local/bin` or registering the boot service.

On Windows, use the zip from the [releases](https://github.com/selfship-ai/aptsy/releases) page.

## Use

```bash
sslearn init      # find installed agents, write hooks, write config
sslearn start     # run in the background, and start again at boot
sslearn stop      # stop until the next boot or sslearn start
sslearn uninstall # remove Aptsy from this machine
sslearn status    # check that it is up
sslearn version
```

`sslearn start` returns as soon as the daemon is up. It does not stay in the terminal. On Linux it installs a systemd service so Aptsy starts when the machine boots. On macOS it installs a launchd daemon that does the same. The first start asks for your password so it can register that service. There is no foreground mode.

After init, use your coding agent as usual. Aptsy records the session and builds a local playbook from it.

To re-read chats that were captured by an older version:

```bash
sslearn sync --rebuild
```

That replaces Aptsy's copy of those chats with a fresh read from each tool. Lessons already in the playbook are kept. If a tool no longer has the chat, that copy is left as it is. Add `--tool claude_code` (or `cursor`, `codex`, `hermes`, `goose`, `openhands`) to limit the command to one tool.

Check what has been learned:

```bash
sslearn learn status
```

## Where files live

| Path | What it is |
|------|------------|
| `~/.selfship/learn/config.yml` | Config written by `sslearn init` |
| `~/.selfship/learn/ingest_data/` | Local database |
| `~/.selfship/learn/sslearn.pid` | Process id of the daemon |
| macOS: `~/Library/Logs/sslearn.log` | Log file |
| Linux: `/var/log/sslearn/sslearn.log` | Log file |
| `~/.selfship/hooks/sslearn-bridge` | Helper the agent hooks run |

Aptsy listens on `127.0.0.1:8787` for hooks and `127.0.0.1:8788/mcp` for MCP. `sslearn init` writes the MCP entry for each tool it finds.

Set `SELFSHIP_TOKEN` if you want that secret required on both local ports. Leave it unset when only you can reach this machine.

Set `OPENAI_API_KEY` to let Aptsy write lessons with a model. `OPENAI_BASE_URL` and `OPENAI_CHAT_MODEL` override the endpoint and model. With no key, Aptsy still records chats.

## Upgrade

Run the install command again. It replaces `sslearn` and `sslearn-bridge` and leaves an existing config in place unless you ask it to set the hooks up again. Restart a daemon that was already running so it picks up the new binary.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/selfship-ai/aptsy/main/install.sh | bash -s -- --uninstall
```

If `sslearn` is already on your PATH:

```bash
sslearn uninstall
```

That stops the boot service, removes the hook and MCP entries Aptsy added, and deletes `~/.selfship`, the log file, and the `sslearn` command. `sslearn uninstall` asks before it deletes anything. The install-script command does not ask again.
