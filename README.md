# Folia Start-Up Script (Windows)

One PowerShell script that turns a fresh Windows PC into a ready-to-play
**Folia Minecraft server**. Everything is downloaded from the internet —
no Java to install, no Python, no admin rights, no manual configuration.

## What it sets up

- Folia 26.2 direct main-world server (build 7, pinned)
- Java 25 — Eclipse Temurin, bundled in `.\java25\`
- WorldEdit
- LuckPerms
- Chunky
- ViaVersion / ViaBackwards / ViaRewind (best effort)
- EssentialsC — `/sethome` `/home` `/delhome` `/homes` for **every** player
- **`/kill` for every player** — self-kill only (ops keep the full-power
  `/minecraft:kill`), with a cooldown
- **Cooldowns** on `/sethome` `/home` `/tpa` `/kill` (default 30s, enforced on
  ops too)
- **54-slot ender chest** — VariableEnderChests, one page, no paging arrows,
  vanilla ender chest contents are converted automatically on first login
- **Reach datapack** — extended block/entity interaction range (default 5.5)
  applied to every player automatically on join
- **Ping simulator (Toxiproxy)** — connect to `127.0.0.1:25566` to play with
  simulated real-world ping (~80ms RTT by default); localhost-only, nothing
  system-wide, SHA256-verified download
- No whitelist, offline mode (same as a LAN-friendly setup)
- No NoCheatPlus, no CoreProtect, no gamerule commands
- `run.bat` / `stop.bat` / `rcon.ps1` helpers with a random per-install RCON password
- Java RAM auto-sized to your PC (half of installed RAM, clamped to 4–8 GB)

## Quick start

1. Download **`setup-folia-windows.ps1`** from this repo.
2. Right-click the file → **Run with PowerShell**.
   (If your browser marked it as blocked: right-click → Properties → *Unblock* first.
   Or run from a terminal: `powershell -ExecutionPolicy Bypass -File .\setup-folia-windows.ps1`)
3. Wait while it downloads Java 25, Folia, and the plugins (~1 GB, a few minutes).
4. When asked, type your **Minecraft username** — you'll be made server operator.
5. First boot generates the world; the script finishes setup automatically
   (ops you, grants permissions, applies cooldowns, starts the ping simulator).
6. Join the server at **`localhost:25565`** — or **`localhost:25566`** to play
   with simulated ping.

The server installs to `Desktop\FoliaServer` by default.

## Managing the server

| Action | How |
|---|---|
| Start everything (server + ping sim) | re-run the setup script |
| Start server only | double-click `run.bat` |
| Stop server (saves world) | double-click `stop.bat`, or type `stop` in the server console |
| Start / stop the ping simulator | `tools\toxiproxy\start-toxiproxy.bat` / `stop-toxiproxy.bat` |
| Run a console command | `powershell -ExecutionPolicy Bypass -File rcon.ps1 -Command "list"` |

A `README.txt` with these notes is also generated inside the server folder.

## Options

All parameters are optional:

```powershell
powershell -ExecutionPolicy Bypass -File .\setup-folia-windows.ps1 `
    -InstallDir "C:\mcsrv" `   # where to install (default: Desktop\FoliaServer)
    -McVersion 26.2 `          # Minecraft/Folia version
    -FoliaBuild 7 `            # 0 = newest build of any channel
    -McPort 25565 `            # game port
    -RconPort 25575 `          # RCON port
    -OpUsername Alex `         # skip the interactive operator prompt
    -XmxGB 6 `                 # 0 = auto (half of RAM, 4–8 GB)
    -CooldownSeconds 30 `      # /sethome /home /tpa /kill cooldown
    -ReachBlocks 5.5 `         # reach applied to every player
    -EchestRows 6 `            # ender chest rows (6 = 54 slots, one page)
    -JitterPort 25566 `        # simulated-ping endpoint port
    -JitterLatencyMs 40 `      # added latency per direction (x2 = RTT)
    -JitterVarianceMs 10 `     # +/- jitter per direction
    -NoJitter `                # skip the Toxiproxy ping simulator entirely
    -NoStart `                 # download + configure only, don't boot
    -StartHidden `             # start the server without a console window
    -NoPause                   # don't wait for Enter at the end (CI/automation)
```

## Re-running / repairing

The script is idempotent: existing Java, `folia.jar`, plugin jars, configs and
the world are detected and **never re-downloaded or overwritten** — re-running
it is the normal way to start everything (server + ping simulator). If the
server or proxy are already running they are left alone; LuckPerms grants are
re-applied harmlessly. Feature config files (`commands.yml`, ender chest
config, reach datapack) are written only on the first run, so manual tweaks
survive re-runs. If Folia publishes newer builds, re-run with `-FoliaBuild 0`
to grab the newest.

## Requirements

- Windows 10/11 x64
- Internet connection (~1 GB of downloads)
- About 2 GB of free disk space

## Security notes

- The generated server runs in **offline mode with no whitelist**: anyone who
  can reach the port can join with any username. That's fine for yourself and
  LAN friends — do **not** port-forward it to the internet without enabling
  whitelist or online mode in `server.properties`.
- RCON listens on `127.0.0.1` only (localhost) with a random password stored
  in the hidden `.rconpass` file in the server folder.
- The Toxiproxy API listens on `127.0.0.1:8474` only; it delays nothing except
  connections explicitly made to the jitter port.
- VariableEnderChests is downloaded from this repo's GitHub Releases
  (mirrored from SpigotMC, which blocks scripted downloads) and is
  SHA256-pinned to the official 1.11.9.2 jar.
