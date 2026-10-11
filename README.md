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
- No whitelist, offline mode (same as a LAN-friendly setup)
- No NoCheatPlus, no proxy, no CoreProtect, no gamerule commands
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
   (ops you + grants home permissions to all players).
6. Join the server at **`localhost:25565`**.

The server installs to `Desktop\FoliaServer` by default.

## Managing the server

| Action | How |
|---|---|
| Start | double-click `run.bat` |
| Stop (saves world) | double-click `stop.bat`, or type `stop` in the server console |
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
    -NoStart `                 # download + configure only, don't boot
    -NoPause                   # don't wait for Enter at the end (CI/automation)
```

## Re-running / repairing

The script is idempotent: existing Java, `folia.jar`, and plugin jars are
kept and re-downloaded only if missing/invalid. Your world is never touched.
If Folia publishes newer builds, re-run with `-FoliaBuild 0` to grab the newest.

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
