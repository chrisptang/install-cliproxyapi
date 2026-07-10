# install-cliproxyapi

Cross-platform installer and manager for:

- **[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)** — the local proxy/router for Codex, Claude, and Gemini.
- **[cpa-usage-keeper](https://github.com/Willxup/cpa-usage-keeper)** — a token-usage dashboard backed by CLIProxyAPI.

Both applications start automatically after login, restart after a crash, and check GitHub for updates every day at 10:00.

## Supported systems

| System | Architectures | Background-process mechanism |
| --- | --- | --- |
| macOS | Apple Silicon | User LaunchAgents |
| Windows 10/11 | x64, ARM64 | Current-user Scheduled Tasks |

Windows tasks use the current user's limited token, so a standard Windows installation does not require administrator privileges. Windows PowerShell 5.1 or PowerShell 7 is supported; organization-managed devices may still restrict Scheduled Task creation through policy.

## Quick start

### macOS

```bash
git clone ssh://git@github.com/chrisptang/install-cliproxyapi.git
cd install-cliproxyapi
./start-cliproxyapi.sh install
```

### Windows

Run in PowerShell:

```powershell
git clone ssh://git@github.com/chrisptang/install-cliproxyapi.git
cd install-cliproxyapi
powershell -ExecutionPolicy Bypass -File .\start-cliproxyapi.ps1 install
```

If script execution is already allowed, this shorter form also works:

```powershell
.\start-cliproxyapi.ps1 install
```

After installation:

- Proxy: `http://127.0.0.1:8317`
- Dashboard: `http://127.0.0.1:30000`
- Default client API key: `local-key`
- Default management key: `local-key`

Change the default keys before exposing either service outside your computer.

## Commands

The macOS and Windows scripts expose the same commands. Substitute the command prefix for your system:

- macOS: `./start-cliproxyapi.sh`
- Windows: `.\start-cliproxyapi.ps1`

| Command | What it does |
| --- | --- |
| `install` | Install/update both applications, register background jobs, and start them. This is the default. |
| `update` | Check for a CLIProxyAPI update and restart it if updated. |
| `start` | Start CLIProxyAPI. |
| `stop` | Stop CLIProxyAPI. |
| `restart` | Restart CLIProxyAPI. |
| `status` | Show service, binary, and version status for both applications. |
| `uninstall` | Stop and remove background jobs while keeping config, binaries, and usage data. |
| `keeper-install` | Install/update and start cpa-usage-keeper. |
| `keeper-update` | Check for a cpa-usage-keeper update and restart it if updated. |
| `keeper-start` | Start cpa-usage-keeper. |
| `keeper-stop` | Stop cpa-usage-keeper. |
| `keeper-restart` | Restart cpa-usage-keeper. |

## GitHub proxy

Release API requests and downloads use `$http_proxy`, then `$HTTP_PROXY`, and finally `http://127.0.0.1:7890` by default.

macOS example:

```bash
http_proxy=http://127.0.0.1:1087 ./start-cliproxyapi.sh update
```

Windows examples:

```powershell
# Use a proxy. The Windows manager persists this value for daily updates.
.\start-cliproxyapi.ps1 install -GitHubProxy http://127.0.0.1:1087

# Connect directly without a proxy.
.\start-cliproxyapi.ps1 install -GitHubProxy ""
```

The proxy is used only for GitHub fetches; the managed applications do not inherit it from the installer.

## Generated files

### macOS

Runtime files are stored in `~/.local/share/cliproxyapi`. LaunchAgents are written to `~/Library/LaunchAgents`.

### Windows

Runtime files are stored in `%LOCALAPPDATA%\CLIProxyAPI`. The manager creates four current-user Scheduled Tasks:

- `CLIProxyAPI Proxy`
- `CLIProxyAPI Proxy Update`
- `CLIProxyAPI Usage Keeper`
- `CLIProxyAPI Usage Keeper Update`

The data directory contains downloaded executables, `config.yaml`, the dashboard `.env` and SQLite data, logs, version markers, a persisted GitHub proxy setting, and a copy of the Windows manager used by daily update tasks.

## Notes

- `config.yaml` and `keeper-data/.env` contain secrets. Back them up securely.
- The dashboard requires `usage-statistics-enabled: true`; both installers enable it automatically.
- `uninstall` intentionally preserves local data. Delete the platform data directory manually if you want a complete removal.
- On Windows, background tasks run only while the installing user is logged in. This keeps installation administrator-free and matches the macOS user-agent model.
