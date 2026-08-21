# install-cliproxyapi

Cross-platform installer and manager for:

- **[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)** — the local proxy/router for Codex, Claude, and Gemini.
- **[cpa-usage-keeper](https://github.com/Willxup/cpa-usage-keeper)** — a token-usage dashboard backed by CLIProxyAPI.

Both applications start automatically after login, restart after a crash, and check GitHub for updates every day at 10:00.

## Supported systems

| System | Architectures | Background-process mechanism |
| --- | --- | --- |
| macOS | Apple Silicon | User LaunchAgents |
| Ubuntu | x64, ARM64 | User systemd services and timers |
| Windows 10/11 | x64, ARM64 | Current-user Scheduled Tasks |

Ubuntu installation uses the current user's systemd manager and does not require administrator privileges. Run it from a normal login session without `sudo`.

Windows tasks use the current user's limited token, so a standard Windows installation does not require administrator privileges. Windows PowerShell 5.1 or PowerShell 7 is supported; organization-managed devices may still restrict Scheduled Task creation through policy.

## Quick start

### macOS

```bash
git clone ssh://git@github.com/chrisptang/install-cliproxyapi.git
cd install-cliproxyapi
./start-cliproxyapi.sh install
```

### Ubuntu

Run as the target user without `sudo`:

```bash
git clone ssh://git@github.com/chrisptang/install-cliproxyapi.git
cd install-cliproxyapi
./start-cliproxyapi-ubuntu.sh install
```

The script requires Ubuntu with a running user systemd manager, plus `curl` and `tar`.

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

- Proxy: `http://127.0.0.1:8317` by default; override the port during installation with `--port` (`-Port` on Windows), and bind it to the local network with `--lan` (`-Lan` on Windows)
- Dashboard: `http://127.0.0.1:30000`
- Default client API key: `local-key` (localhost-only; `--lan` requires you to set your own)
- Default management key: `local-key` (same)

Change the default keys before exposing either service outside your computer.

## Commands

The macOS, Ubuntu, and Windows scripts expose the same commands. Substitute the command prefix for your system:

- macOS: `./start-cliproxyapi.sh`
- Ubuntu: `./start-cliproxyapi-ubuntu.sh`
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

### Override the proxy port

The `install` command accepts a port override and keeps cpa-usage-keeper pointed at the same CLIProxyAPI endpoint:

```bash
./start-cliproxyapi.sh install --port 9000
./start-cliproxyapi-ubuntu.sh install --port 9000
```

```powershell
.\start-cliproxyapi.ps1 install -Port 9000
```

The port must be between `1` and `65535`. When the generated configuration already exists, an explicit port override updates its top-level `port` value and the keeper's `CPA_BASE_URL`; without an override, existing files remain untouched.

### Serve the local network (LAN mode)

By default the proxy binds `127.0.0.1`, so only the machine running it can connect. Pass `--lan` (`-Lan` on Windows) to bind `0.0.0.0` instead, which lets other machines on the same network use the proxy:

```bash
./start-cliproxyapi.sh install --lan --api-key "$(openssl rand -hex 24)"
./start-cliproxyapi-ubuntu.sh install --lan --api-key "$(openssl rand -hex 24)"
```

```powershell
.\start-cliproxyapi.ps1 install -Lan -ApiKey ([guid]::NewGuid().ToString('N'))
```

LAN mode requires an explicit API key, which must be at least 16 characters of `A-Z a-z 0-9 . _ ~ -`. Binding `0.0.0.0` also exposes the management API, and the shipped `local-key` default is published in this repository, so reusing it would let anyone on the network read and modify the proxy configuration. The key you pass becomes both the client `api-keys` entry and `remote-management.secret-key`, and the keeper's `CPA_MANAGEMENT_KEY` is updated to match.

Clients then point at `http://<this-machine-ip>:8317` and must send that API key. Note:

- The cpa-usage-keeper dashboard stays bound to `127.0.0.1` in LAN mode. It runs without a login wall (`AUTH_ENABLED=false`), so it is deliberately not exposed.
- A host firewall may still block inbound connections. Allow inbound TCP on the proxy port for the local network (`ufw allow`/`firewalld` on Ubuntu, Windows Defender Firewall on Windows).
- Applied to an existing `config.yaml`, `--lan` rewrites `host` and, with `--api-key`, replaces the `api-keys` list and `remote-management.secret-key`. Re-running is safe, and installing later without `--lan` restores the `127.0.0.1` binding.
- Only use this on networks you trust. The proxy forwards to upstream accounts billed to you.

## GitHub proxy

Release API requests and downloads use `$http_proxy`, then `$HTTP_PROXY`, and finally `http://127.0.0.1:7890` by default.

macOS example:

```bash
http_proxy=http://127.0.0.1:1087 ./start-cliproxyapi.sh update
```

Ubuntu example:

```bash
http_proxy=http://127.0.0.1:1087 ./start-cliproxyapi-ubuntu.sh update
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

Runtime files, including an installed copy of the manager used by daily updates, are stored in `~/.local/share/cliproxyapi`. LaunchAgents are written to `~/Library/LaunchAgents`; installation and start operations unload the existing job, delete its same-name plist, recreate it, and bootstrap the new definition. No LaunchAgent executes files from the cloned repository, so cloning under `~/Documents` does not trigger background-access prompts.

### Ubuntu

Runtime files, including the installed manager copy used by daily updates, are stored in `~/.local/share/cliproxyapi`. User services and timers are written to `~/.config/systemd/user`:

- `cliproxyapi.service`
- `cliproxyapi-update.service` and `cliproxyapi-update.timer`
- `cpa-usage-keeper.service`
- `cpa-usage-keeper-update.service` and `cpa-usage-keeper-update.timer`

Services start with the user's systemd session, restart after crashes, and write logs under `~/.local/share/cliproxyapi/logs`.

### Windows

Runtime files are stored in `%LOCALAPPDATA%\CLIProxyAPI`. The manager creates four current-user Scheduled Tasks:

- `CLIProxyAPI Proxy`
- `CLIProxyAPI Proxy Update`
- `CLIProxyAPI Usage Keeper`
- `CLIProxyAPI Usage Keeper Update`

The data directory contains downloaded executables, `config.yaml`, the dashboard `.env` and SQLite data, logs, version markers, a persisted GitHub proxy setting, and a copy of the Windows manager used by daily update tasks.

## Notes

- `config.yaml` and `keeper-data/.env` contain secrets. Back them up securely.
- The dashboard requires `usage-statistics-enabled: true`; all installers enable it automatically.
- `uninstall` intentionally preserves local data. Delete the platform data directory manually if you want a complete removal.
- On Ubuntu, background services use the current user's systemd session. The script does not enable lingering, so the user must log in before the services start.
- On Windows, background tasks run only while the installing user is logged in. This keeps installation administrator-free and matches the macOS and Ubuntu user-service models.
