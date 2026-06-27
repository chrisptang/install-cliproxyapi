# install-cliproxyapi

A single-file macOS (Apple Silicon) manager that installs, auto-updates, and keeps running:

- **[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)** — the local proxy/router for Codex/Claude/Gemini.
- **[cpa-usage-keeper](https://github.com/Willxup/cpa-usage-keeper)** — a token-usage dashboard that reads usage from CLIProxyAPI.

Both run as user **LaunchAgents**: they start on login, restart on crash (KeepAlive), and check GitHub for a newer release every day at 10:00.

## Requirements

- macOS on Apple Silicon (downloads the `darwin_aarch64` / `darwin_arm64` builds).
- `curl` and `tar` (preinstalled on macOS).
- An HTTP proxy reachable for GitHub fetches (see [Proxy](#proxy)).

## Quick start

```bash
git clone ssh://git@github.com/chrisptang/install-cliproxyapi.git
cd install-cliproxyapi
./start-cliproxyapi.sh install
```

`install` (the default with no argument) does everything:

1. Removes any Homebrew-installed `cliproxyapi` (those lag behind upstream).
2. Creates `config.yaml` if missing (API key `local-key`, management secret key `local-key`).
3. Sets `usage-statistics-enabled: true` in `config.yaml` — **required** for the dashboard to receive data.
4. Downloads the latest CLIProxyAPI binary and starts it (default port **8317**).
5. Installs the cpa-usage-keeper dashboard, writes its `.env` pointing at the local proxy, and starts it on port **30000**.
6. Installs daily-updater LaunchAgents (10:00) for both.

When it finishes:

- Proxy: `http://127.0.0.1:8317`
- Dashboard: **http://127.0.0.1:30000**

## Commands

### CLIProxyAPI

| Command | What it does |
| --- | --- |
| `./start-cliproxyapi.sh install` | Full setup (default if no argument). |
| `./start-cliproxyapi.sh update` | Download a newer release if any, then restart. |
| `./start-cliproxyapi.sh start` | Start the service. |
| `./start-cliproxyapi.sh stop` | Stop the service. |
| `./start-cliproxyapi.sh restart` | Restart the service. |
| `./start-cliproxyapi.sh status` | Show service + version status for both. |
| `./start-cliproxyapi.sh uninstall` | Remove all LaunchAgents (keeps downloaded files). |

### cpa-usage-keeper dashboard (port 30000)

| Command | What it does |
| --- | --- |
| `./start-cliproxyapi.sh keeper-install` | Download dashboard, write `.env`, install agents, start. |
| `./start-cliproxyapi.sh keeper-update` | Download a newer dashboard if any, then restart. |
| `./start-cliproxyapi.sh keeper-start` | Start the dashboard. |
| `./start-cliproxyapi.sh keeper-stop` | Stop the dashboard. |
| `./start-cliproxyapi.sh keeper-restart` | Restart the dashboard. |

## Proxy

All GitHub fetches — `api.github.com` release queries and `github.com` release downloads, for both projects — go through an HTTP proxy:

- `$http_proxy` if set, else `$HTTP_PROXY` if set, else the default `http://127.0.0.1:7890`.

Override per-run, for example:

```bash
http_proxy=http://127.0.0.1:1087 ./start-cliproxyapi.sh update
```

## Layout & generated files

The script downloads binaries and generates runtime files into this directory. They are **git-ignored** and never committed:

| Path | Purpose |
| --- | --- |
| `cli-proxy-api` | CLIProxyAPI binary (downloaded). |
| `cpa-usage-keeper` | Dashboard binary (downloaded). |
| `config.yaml` | CLIProxyAPI config (contains your management secret-key hash). |
| `keeper-data/` | Dashboard SQLite DB, logs, backups, and `.env` (contains `CPA_MANAGEMENT_KEY`). |
| `logs/` | LaunchAgent stdout/stderr logs. |
| `.cliproxyapi-version`, `.cpa-usage-keeper-version` | Installed-version markers. |

LaunchAgents are written to `~/Library/LaunchAgents/`:

- `me.router-for.cliproxyapi[.update].plist`
- `me.willxup.cpa-usage-keeper[.update].plist`

## Notes

- `config.yaml` and `keeper-data/.env` hold secrets and are intentionally excluded from version control via `.gitignore`. Back them up yourself if needed.
- The dashboard only shows data while `usage-statistics-enabled: true` is set in `config.yaml`; `install` sets this for you.
- To fully remove: `./start-cliproxyapi.sh uninstall`, then delete the downloaded binaries and `keeper-data/` if you want them gone too.
