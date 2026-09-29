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
- Run it as yourself. It writes config in your home directory and asks for sudo only when copying `sslearn` into `/usr/local/bin`.

On Windows, download `sslearn_*_windows_*.zip` from the [releases](https://github.com/selfship-ai/aptsy/releases) page, then run `sslearn init`.

To install one archive by hand:

```bash
gh release download v0.1.0 --repo selfship-ai/aptsy --pattern 'sslearn_0.1.0_darwin_arm64.tar.gz'
tar -xzf sslearn_0.1.0_darwin_arm64.tar.gz
sudo mv sslearn /usr/local/bin/sslearn
mkdir -p ~/.selfship/hooks
mv sslearn-bridge ~/.selfship/hooks/sslearn-bridge
chmod +x ~/.selfship/hooks/sslearn-bridge
sslearn init
sslearn start
```

Change the archive name for your OS and CPU. The hook helper must be at `~/.selfship/hooks/sslearn-bridge`.

## Use

```bash
sslearn init      # find installed agents, write hooks, write config
sslearn start     # run in the foreground
sslearn stop      # stop a background daemon
sslearn status    # check that it is up
sslearn version
```

`sslearn start` keeps running until you press Ctrl+C, and records `~/.selfship/learn/sslearn.pid`. If the installer started it in the background, `sslearn stop` stops that process.

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
| `~/.selfship/learn/sslearn.pid` | Process id of a background daemon |
| `~/.selfship/learn/sslearn.log` | Log when the installer starts it in the background |
| `~/.selfship/hooks/sslearn-bridge` | Helper the agent hooks run |

Aptsy listens on `127.0.0.1:8787` for hooks and `127.0.0.1:8788/mcp` for MCP. `sslearn init` writes the MCP entry for each tool it finds. To add it yourself:

```json
{
  "mcpServers": {
    "sslearn": {
      "url": "http://127.0.0.1:8788/mcp"
    }
  }
}
```

Set `SELFSHIP_TOKEN` if you want that secret required on both local ports. Leave it unset when only you can reach this machine.

Set `OPENAI_API_KEY` to let Aptsy write lessons with a model. `OPENAI_BASE_URL` and `OPENAI_CHAT_MODEL` override the endpoint and model. With no key, Aptsy still records chats.

## Upgrade

Run the install command again. It replaces `sslearn` and `sslearn-bridge` and leaves an existing config in place unless you ask it to set the hooks up again. Restart a daemon that was already running so it picks up the new binary.

## Uninstall

Remove the Aptsy entries from:

- `~/.claude/settings.json` and `~/.claude.json`
- `~/.cursor/hooks.json` and `~/.cursor/mcp.json`
- `~/.codex/hooks.json` and `~/.codex/config.toml`
- `~/.hermes/config.yaml`
- `~/.agents/plugins/selfship/`
- `~/.openhands/hooks.json`

Then remove the command and the data directory:

```bash
rm -f /usr/local/bin/sslearn ~/.local/bin/sslearn
rm -rf ~/.selfship
```
