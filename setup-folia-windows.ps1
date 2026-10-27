# ============================================================================
#  Folia 26.2 Direct Server Setup for Windows  (one script - everything in)
#  ---------------------------------------------------------------
#  Builds the complete "Direct Folia" server from the internet:
#    - Folia 26.2 (build 7 pinned) + bundled Java 25 (.\java25\)
#    - Plugins: WorldEdit, LuckPerms, Chunky, ViaVersion/ViaBackwards/ViaRewind,
#      EssentialsC, VariableEnderChests (single-page ender chest)
#    - /kill for ALL players (self-kill only, cooldown) - vanilla /minecraft:kill
#      stays available to ops
#    - Cooldowns on /sethome /home /tpa /kill (default 30s, applies to ops too)
#    - Reach datapack: extended block/entity reach applied to every player on
#      join (default 5.5) - advancement-reward trigger, works on Folia 26.2
#    - 54-slot ender chest (6 rows, one page, vanilla contents auto-converted)
#    - Toxiproxy jitter endpoint: connect to 127.0.0.1:25566 for simulated
#      real-world ping (default +40ms +/- 10ms per direction = ~80ms RTT)
#
#  HOW TO RUN (your friends):
#    1. Save this file, e.g. to Desktop
#    2. Right-click it  ->  "Run with PowerShell"
#    3. Wait. It asks for your Minecraft name to make you operator.
#    4. Join: localhost:25565   (or localhost:25566 to play with simulated ping)
#
#  To re-run / repair / START EVERYTHING: just run it again. Existing files,
#  plugins and configs are detected and kept - nothing is re-downloaded or
#  updated. If the server or the ping proxy are already running they are left
#  alone; if they are down, they are started.
#
#  Optional parameters (advanced):
#    powershell -ExecutionPolicy Bypass -File .\setup-folia-windows.ps1 `
#        -InstallDir "C:\mcsrv" -McPort 25565 -RconPort 25575 -OpUsername Alex
# ============================================================================
param(
    [string]$InstallDir = "$env:USERPROFILE\Desktop\FoliaServer",
    [string]$McVersion = "26.2",
    [int]$FoliaBuild = 7,                # 0 = newest build of any channel
    [int]$McPort = 25565,
    [int]$RconPort = 25575,
    [string]$OpUsername = "",            # empty = ask during setup
    [int]$XmxGB = 0,                     # 0 = auto (half of RAM, 4-8 GB)
    [int]$CooldownSeconds = 30,          # /sethome /home /tpa /kill cooldown
    [double]$ReachBlocks = 5.5,          # block + entity interaction range
    [int]$EchestRows = 6,                # ender chest rows (6 = 54 slots, 1 page)
    [int]$JitterPort = 25566,            # simulated-ping endpoint
    [int]$JitterLatencyMs = 40,          # added latency per direction (x2 = RTT)
    [int]$JitterVarianceMs = 10,         # +/- jitter per direction
    [switch]$NoJitter,                   # skip the Toxiproxy ping simulator
    [switch]$NoStart,                    # download + configure only, don't boot
    [switch]$StartHidden,                # start server without a console window
    [switch]$NoPause                     # don't wait for Enter at the end
)

$ErrorActionPreference = "Stop"
$UserAgent = "FoliaWinSetup/1.1"
Add-Type -AssemblyName System.IO.Compression.FileSystem

# VariableEnderChests 1.11.9.2 - the only safe 26.2 build. SpigotMC blocks
# scripted downloads, so the jar is mirrored as a release asset on the script's
# own GitHub repo (SHA256-pinned to the SpigotMC original).
$VecJarName    = "VariableEnderChests-1.11.9.2.jar"
$VecJarUrl     = "https://github.com/ComicSquid74273/folia_start_up_script/releases/download/vec-1.11.9.2/$VecJarName"
$VecSha256     = "0DD749635ADD949218A5878288F9586062E45AB973A2BA134EBF0EFF79782759"
$VecSpigotPage = "https://www.spigotmc.org/resources/variable-ender-chests-1-8-1-21-configurable.102187/"

# Toxiproxy v2.13.0 (official Shopify release, SHA256-pinned)
$ToxiVersion     = "2.13.0"
$ToxiDir         = "$InstallDir\tools\toxiproxy"
$ToxiServerExe   = "toxiproxy-server-windows-amd64.exe"
$ToxiCliExe      = "toxiproxy-cli-windows-amd64.exe"
$ToxiServerSha256 = "04B710EEFD7690C89F7CC67289E3E14618F1FF3C26E4A5F752A34A879B895BAB"
$ToxiCliSha256   = "6585D19999ABFC1D0C3B3276343DDFE81FBB4B50883CE810337678243A90499B"
$ToxiApiPort     = 8474

# Pretty logging
function Log([string]$m) { Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Ok([string]$m)  { Write-Host "[  OK] $m" -ForegroundColor Green }
function Warn([string]$m){ Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Err([string]$m) { Write-Host "[ ERR] $m" -ForegroundColor Red }

# Speed up downloads and enable TLS 1.2 (older Windows PowerShell)
$ProgressPreference = "SilentlyContinue"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ----------------------------------------------------------------------------
# Download helpers with retry
# ----------------------------------------------------------------------------
function Get-WebFile {
    param([string]$Url, [string]$OutFile)
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile `
                -UserAgent $UserAgent -UseBasicParsing -TimeoutSec 600
            return
        } catch {
            Warn ("download attempt {0}/3 failed: {1}" -f $i, $_.Exception.Message)
            Start-Sleep ($i * 3)
        }
    }
    throw "Failed to download $Url"
}

function Get-WebJson {
    param([string]$Url)
    for ($i = 1; $i -le 3; $i++) {
        try {
            return Invoke-RestMethod -Uri $Url -Headers @{ "User-Agent" = $UserAgent } `
                -TimeoutSec 90 -UseBasicParsing
        } catch {
            Start-Sleep ($i * 3)
        }
    }
    throw "Failed to fetch $Url"
}

# A "valid jar" = zip archive with a plugin.yml or MANIFEST, and not tiny.
function Test-PluginJar {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    if ((Get-Item $Path).Length -lt 10000) { return $false }
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            foreach ($e in $zip.Entries) {
                if ($e.FullName -eq "plugin.yml" -or $e.FullName -eq "META-INF/MANIFEST.MF") { return $true }
            }
            return $false
        } finally { $zip.Dispose() }
    } catch { return $false }
}

# Find an already-installed plugin jar by wildcard (e.g. "LuckPerms*.jar") so
# re-runs never re-download anything, even if the jar filename differs.
function Find-PluginJar([string]$Pattern) {
    $hits = Get-ChildItem -Path "$InstallDir\plugins" -Filter $Pattern -File -ErrorAction SilentlyContinue
    foreach ($h in $hits) { if (Test-PluginJar $h.FullName) { return $h.Name } }
    return $null
}

function Test-PortListening([int]$Port) {
    return ($null -ne (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue))
}

# ----------------------------------------------------------------------------
# 1. Folders
# ----------------------------------------------------------------------------
Log "Install folder: $InstallDir"
New-Item -ItemType Directory -Force -Path `
    $InstallDir, "$InstallDir\plugins", "$InstallDir\tmp" | Out-Null

# ----------------------------------------------------------------------------
# 2. Java 25 (Eclipse Temurin, bundled - nothing to install system-wide)
# ----------------------------------------------------------------------------
function Install-Java25 {
    $javaExe = "$InstallDir\java25\bin\java.exe"
    if (Test-Path $javaExe) {
        $v = (cmd /c "`"$javaExe`" -version 2>&1" | Select-Object -First 1)
        if ("$v" -match 'version "25') { Ok "Java 25 already present ($v)"; return }
    }
    Log "Downloading Java 25 (Eclipse Temurin JDK, Windows x64)..."
    $zip = "$env:TEMP\java25.zip"
    Get-WebFile "https://api.adoptium.net/v3/binary/latest/25/ga/windows/x64/jdk/hotspot/normal/eclipse" $zip
    Log "Extracting Java 25..."
    $extractTmp = "$env:TEMP\java25-extract"
    if (Test-Path $extractTmp) { Remove-Item -Recurse -Force $extractTmp }
    Expand-Archive -Path $zip -DestinationPath $extractTmp -Force
    $inner = Get-ChildItem -Directory $extractTmp | Select-Object -First 1
    if (Test-Path "$InstallDir\java25") { Remove-Item -Recurse -Force "$InstallDir\java25" }
    Move-Item $inner.FullName "$InstallDir\java25"
    Remove-Item -Recurse -Force $extractTmp -ErrorAction SilentlyContinue
    Remove-Item $zip -ErrorAction SilentlyContinue
    $v = (cmd /c "`"$javaExe`" -version 2>&1" | Select-Object -First 1)
    Ok "Java installed: $v"
}

# ----------------------------------------------------------------------------
# 3. Folia jar (PaperMC Fill API, build pinned to match the reference server)
# ----------------------------------------------------------------------------
function Get-Folia {
    $jar = "$InstallDir\folia.jar"
    if ((Test-Path $jar) -and ((Get-Item $jar).Length -gt 10MB)) {
        Ok "folia.jar already present. Skipping."
        return
    }
    Log "Fetching Folia $McVersion build info from PaperMC..."
    $builds = Get-WebJson "https://fill.papermc.io/v3/projects/folia/versions/$McVersion/builds"
    $build = $null
    if ($FoliaBuild -gt 0) {
        $build = $builds | Where-Object { $_.id -eq $FoliaBuild } | Select-Object -First 1
        if (-not $build) { Warn "Build $FoliaBuild not found; using newest instead." }
    }
    if (-not $build) {
        $build = $builds | Sort-Object -Property id -Descending | Select-Object -First 1
    }
    $url = $build.downloads.'server:default'.url
    Log ("Downloading Folia {0} build {1} ({2})..." -f $McVersion, $build.id, $build.channel)
    Get-WebFile $url $jar
    Ok ("folia.jar downloaded ({0:N0} MB)" -f ((Get-Item $jar).Length / 1MB))
}

# ----------------------------------------------------------------------------
# 4. Plugins (Modrinth + the VariableEnderChests release mirror)
# ----------------------------------------------------------------------------
function Get-ModrinthPlugin {
    param([string]$Slug, [string]$OutName, [string]$DetectPattern,
          [string]$FileMatch = "", [bool]$Required = $false)

    # Never re-download when any valid version-matching jar is already there
    $existing = Find-PluginJar $DetectPattern
    if ($existing) { Ok "$existing already installed. Skipping download."; return }

    $out = "$InstallDir\plugins\$OutName"
    $loaders = [uri]::EscapeDataString('["folia","paper","bukkit","spigot"]')
    $games   = [uri]::EscapeDataString('["' + $McVersion + '"]')
    $versions = @()
    try {
        $versions = @(Get-WebJson "https://api.modrinth.com/v2/project/$Slug/version?loaders=$loaders&game_versions=$games")
    } catch {}
    if ($versions.Count -eq 0) {
        $versions = @(Get-WebJson "https://api.modrinth.com/v2/project/$Slug/version")
    }
    $candidates = @($versions | Where-Object { $_.version_type -eq "release" })
    if ($candidates.Count -eq 0) { $candidates = $versions }
    $candidates = @($candidates | Sort-Object -Property date_published -Descending)

    foreach ($v in $candidates) {
        $jarFiles = @($v.files | Where-Object { $_.filename -like "*.jar" })
        if ($FileMatch -ne "") {
            $pick = @($jarFiles | Where-Object { $_.filename -match $FileMatch })
            if ($pick.Count -gt 0) { $jarFiles = $pick }
        }
        $file = $jarFiles | Where-Object { $_.primary } | Select-Object -First 1
        if (-not $file) { $file = $jarFiles | Select-Object -First 1 }
        if (-not $file) { continue }
        try {
            Log ("Downloading {0} {1}..." -f $OutName, "$($v.version_number)")
            Get-WebFile $file.url $out
            if (-not (Test-PluginJar $out)) { throw "not a valid plugin jar" }
            return
        } catch {
            Warn ("candidate failed for {0}: {1}" -f $OutName, $_.Exception.Message)
            if (Test-Path $out) { Remove-Item -Force $out }
        }
    }
    if ($Required) { throw "Could not download required plugin $OutName" }
    Warn "Skipped optional plugin $OutName (best effort)"
}

# VariableEnderChests: 54-slot single-page ender chest. Only 1.11.9.2 is safe
# on 26.2 (older builds wiped ender chest data). SpigotMC (the only official
# source) blocks scripted downloads, so we pull a SHA256-pinned copy from this
# script's GitHub repo; if that ever fails, fall back to a manual browser
# download.
function Install-VariableEnderChests {
    $existing = Find-PluginJar "VariableEnderChests*.jar"
    if ($existing) { Ok "$existing already installed. Skipping download."; return }

    Log "Downloading VariableEnderChests 1.11.9.2 (single-page 54-slot ender chest)..."
    $out = "$InstallDir\plugins\$VecJarName"
    try {
        Get-WebFile $VecJarUrl $out
        $hash = (Get-FileHash -Algorithm SHA256 -Path $out).Hash
        if ($hash -ne $VecSha256) { throw "SHA256 mismatch (expected $VecSha256, got $hash)" }
        if (-not (Test-PluginJar $out)) { throw "not a valid plugin jar" }
        Ok "VariableEnderChests downloaded (SHA256 verified)."
        return
    } catch {
        Warn "auto-download failed: $($_.Exception.Message)"
        if (Test-Path $out) { Remove-Item -Force $out }
    }

    Warn "VariableEnderChests needs a one-time manual browser download:"
    Write-Host  "     1. Open:  $VecSpigotPage"
    Write-Host  "     2. Download version 1.11.9.2 (latest)"
    Write-Host  "     3. Move the jar into:  $InstallDir\plugins\"
    Read-Host  "     Press Enter once the jar is in place (Enter again to skip it for now)"
    if (Find-PluginJar "VariableEnderChests*.jar") {
        Ok "found it - continuing."
    } else {
        Warn "VariableEnderChests not found - the server will use the vanilla 27-slot ender chest. Re-run this script later to retry."
    }
}

function Install-Plugins {
    Log "Checking plugins..."
    Get-ModrinthPlugin -Slug "worldedit"     -OutName "WorldEdit.jar"     -DetectPattern "WorldEdit*.jar"     -FileMatch "bukkit" -Required $true
    Get-ModrinthPlugin -Slug "luckperms"    -OutName "LuckPerms.jar"     -DetectPattern "LuckPerms*.jar"
    Get-ModrinthPlugin -Slug "chunky"       -OutName "Chunky.jar"        -DetectPattern "Chunky*.jar"       -FileMatch "bukkit"
    Get-ModrinthPlugin -Slug "essentialsc"  -OutName "EssentialsC.jar"   -DetectPattern "EssentialsC*.jar"
    Get-ModrinthPlugin -Slug "viaversion"   -OutName "ViaVersion.jar"    -DetectPattern "ViaVersion*.jar"
    Get-ModrinthPlugin -Slug "viabackwards" -OutName "ViaBackwards.jar"  -DetectPattern "ViaBackwards*.jar"
    Get-ModrinthPlugin -Slug "viarewind"    -OutName "ViaRewind.jar"     -DetectPattern "ViaRewind*.jar"
    Install-VariableEnderChests
    Ok "Plugins ready."
}

# ----------------------------------------------------------------------------
# 5. Core configs (mirror the reference setup: no whitelist, offline mode, RCON)
# ----------------------------------------------------------------------------
function Write-Configs {
    # RCON password: reuse .rconpass, else reuse the one already in an
    # existing server.properties, else generate a new one (kept in .rconpass)
    $passFile = "$InstallDir\.rconpass"
    $spFile   = "$InstallDir\server.properties"
    $rconPass = $null
    if (Test-Path $passFile) {
        $rconPass = (Get-Content $passFile -Raw).Trim()
    } elseif (Test-Path $spFile) {
        $m = Select-String -Path $spFile -Pattern '^rcon\.password=(.+)$' | Select-Object -First 1
        if ($m) { $rconPass = $m.Matches[0].Groups[1].Value.Trim() }
    }
    if (-not $rconPass) {
        $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789'
        $rconPass = -join ((1..32) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
    }
    if (-not (Test-Path $passFile)) {
        Set-Content -Path $passFile -Value $rconPass -NoNewline
        (Get-Item $passFile).Attributes = 'Hidden'
    }

    # Memory: default = half of installed RAM, clamped to 4-8 GB
    if ($XmxGB -le 0) {
        $totalGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB)
        $XmxGB = [math]::Min(8, [math]::Max(4, [math]::Floor($totalGB / 2)))
    }
    $xms = [math]::Min(4, $XmxGB)
    Log "Java heap: -Xms${xms}G -Xmx${XmxGB}G"

    Set-Content -Path "$InstallDir\eula.txt" -Value "eula=true" -Encoding ASCII

    # server.properties: full write on fresh installs; on existing installs
    # only ensure the core keys (everything else the user changed is kept)
    if (-not (Test-Path $spFile)) {
        $sp = @"
server-port=$McPort
online-mode=false
white-list=false
enforce-whitelist=false
allow-flight=true
spawn-protection=0
difficulty=peaceful
gamemode=survival
max-players=20
enable-command-block=true
player-idle-timeout=0
enable-rcon=true
rcon.port=$RconPort
rcon.password=$rconPass
view-distance=8
simulation-distance=6
motd=Direct Folia $McVersion Server
"@
        Set-Content -Path $spFile -Value $sp -Encoding ASCII
        Ok "server.properties written (no whitelist, offline mode, RCON on $RconPort)."
    } else {
        $ensure = [ordered]@{
            "server-port"       = "$McPort"
            "online-mode"       = "false"
            "white-list"        = "false"
            "enforce-whitelist" = "false"
            "enable-rcon"       = "true"
            "rcon.port"         = "$RconPort"
            "rcon.password"     = "$rconPass"
        }
        $lines = @(Get-Content $spFile)
        $changed = $false
        foreach ($k in $ensure.Keys) {
            $found = $false
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match ('^' + [regex]::Escape($k) + '=')) {
                    $found = $true
                    $want = "$k=$($ensure[$k])"
                    if ($lines[$i] -ne $want) { $lines[$i] = $want; $changed = $true }
                }
            }
            if (-not $found) { $lines += "$k=$($ensure[$k])"; $changed = $true }
        }
        if ($changed) {
            Set-Content -Path $spFile -Value $lines
            Warn "server.properties existed - only the core keys were ensured, the rest kept."
        } else {
            Ok "server.properties already correct. Keeping it."
        }
    }

    # run.bat: keep an existing one (it may hold a tuned heap size)
    $runBat = @"
@echo off
setlocal
cd /d "%~dp0"
if not exist "tmp" mkdir "tmp"
set "TEMP=%~dp0tmp"
set "TMP=%~dp0tmp"
"%~dp0java25\bin\java.exe" -Xms${xms}G -Xmx${XmxGB}G -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+DisableExplicitGC -Djava.io.tmpdir="%~dp0tmp" -jar folia.jar nogui
pause
"@
    if (Test-Path "$InstallDir\run.bat") {
        Ok "run.bat already present. Keeping it."
    } else {
        Set-Content -Path "$InstallDir\run.bat" -Value $runBat -Encoding ASCII
    }

    # windowless variant (no pause) used by -StartHidden
    $runHidden = @"
@echo off
setlocal
cd /d "%~dp0"
if not exist "tmp" mkdir "tmp"
set "TEMP=%~dp0tmp"
set "TMP=%~dp0tmp"
"%~dp0java25\bin\java.exe" -Xms${xms}G -Xmx${XmxGB}G -XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 -XX:+DisableExplicitGC -Djava.io.tmpdir="%~dp0tmp" -jar folia.jar nogui
"@
    Set-Content -Path "$InstallDir\run-hidden.bat" -Value $runHidden -Encoding ASCII

    # RCON helper in PowerShell (no Python needed) with the password baked in
    $rconPs1 = @'
param(
    [Parameter(Mandatory=$true)][string]$Command,
    [string]$RconHost = "127.0.0.1",
    [int]$Port = __RCONPORT__,
    [string]$Password = "__RCONPASS__"
)
$ErrorActionPreference = "Stop"
function Send-RconPacket($Stream, [int]$Id, [int]$Type, [string]$Body) {
    $b = [System.Text.Encoding]::UTF8.GetBytes($Body)
    $buf = New-Object byte[] (14 + $b.Length)
    [System.BitConverter]::GetBytes([int]($b.Length + 10)).CopyTo($buf, 0)
    [System.BitConverter]::GetBytes([int]$Id).CopyTo($buf, 4)
    [System.BitConverter]::GetBytes([int]$Type).CopyTo($buf, 8)
    $b.CopyTo($buf, 12)
    $Stream.Write($buf, 0, $buf.Length); $Stream.Flush()
}
function Read-RconExact($Stream, [int]$Count) {
    $buf = New-Object byte[] $Count; $off = 0
    while ($off -lt $Count) {
        $r = $Stream.Read($buf, $off, $Count - $off)
        if ($r -le 0) { throw "short read" }
        $off += $r
    }
    ,$buf
}
function Read-RconPacket($Stream) {
    $len = [System.BitConverter]::ToInt32((Read-RconExact $Stream 4), 0)
    $data = Read-RconExact $Stream $len
    [pscustomobject]@{
        Id   = [System.BitConverter]::ToInt32($data, 0)
        Body = [System.Text.Encoding]::UTF8.GetString($data, 8, [Math]::Max(0, $len - 10))
    }
}
$c = New-Object System.Net.Sockets.TcpClient
$c.Connect($RconHost, $Port)
try {
    $s = $c.GetStream(); $s.ReadTimeout = 15000
    Send-RconPacket $s 10 3 $Password
    if ((Read-RconPacket $s).Id -eq -1) { throw "RCON auth failed" }
    Send-RconPacket $s 11 2 $Command
    Write-Output (Read-RconPacket $s).Body
} finally { $c.Close() }
'@
    $rconPs1 = $rconPs1.Replace("__RCONPORT__", "$RconPort").Replace("__RCONPASS__", $rconPass)
    Set-Content -Path "$InstallDir\rcon.ps1" -Value $rconPs1 -Encoding ASCII

    if (-not (Test-Path "$InstallDir\stop.bat")) {
        $stopBat = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rcon.ps1" -Command stop
"@
        Set-Content -Path "$InstallDir\stop.bat" -Value $stopBat -Encoding ASCII
    }

    $readme = @"
FOLIA $McVersion SERVER - QUICK REFERENCE
=========================================
Start everything : re-run setup-folia-windows.ps1 (starts server + ping sim)
Start server only: double-click run.bat
Stop server      : double-click stop.bat  (or type stop in the server console)
Ping simulator   : tools\toxiproxy\start-toxiproxy.bat / stop-toxiproxy.bat
Send command     : powershell -ExecutionPolicy Bypass -File rcon.ps1 -Command "list"

Join direct      : localhost:$McPort
Join with ping   : localhost:$JitterPort  (simulated ~$((2 * $JitterLatencyMs))ms RTT)

For every player:
  Homes          : /sethome /home /delhome /homes   (${CooldownSeconds}s cooldown each)
  /kill          : kills yourself only, ${CooldownSeconds}s cooldown (ops can still use /minecraft:kill)
  Ender chest    : $(9 * $EchestRows) slots on one page (/enderchest or /echest)
  Reach          : extended block + entity reach, applied automatically on join

RCON password is stored in the hidden file .rconpass
"@
    Set-Content -Path "$InstallDir\README.txt" -Value $readme -Encoding ASCII
    Ok "Core configs ready."
}

# ----------------------------------------------------------------------------
# 6. Feature configs: /kill + cooldowns, 54-slot echest, reach datapack
#    (all written only when missing - never overwrite manual tweaks)
# ----------------------------------------------------------------------------
function Write-FeatureConfigs {

    # ---- EssentialsC commands.yml -------------------------------------------
    # Full reference file: /kill = self-kill alias of suicide (override, so
    # players can't /kill others or use selectors), cooldowns on sethome +
    # suicide, EssentialsC's own /enderchest disabled so the 54-slot one from
    # VariableEnderChests owns the command. NOTE: this file is read at BOOT;
    # editing it later requires a server restart.
    $essDir = "$InstallDir\plugins\EssentialsC"
    $cmds = "$essDir\commands.yml"
    New-Item -ItemType Directory -Force -Path $essDir | Out-Null
    if (Test-Path $cmds) {
        Ok "EssentialsC commands.yml already present. Keeping it."
    } else {
        $commandsYml = @"
# EssentialsC - commands.yml
#

# The Config Version
# Do NOT CHANGE this
config-version: 11


# Controls which commands EssentialsC registers and how they compete for their
# plain name against Vanilla and other plugins.
#
#
# enabled
#   Set to false to completely remove the command from the server.
#   Players will get "Unknown command" as if the command never existed.
#   The namespaced /essentialsc:<command> form is also removed.
#
# priority
#   Controls which plugin wins the plain command name (e.g. /heal vs another
#   plugin's /heal). EssentialsC is always reachable via /essentialsc:<command>
#   regardless of the priority setting.
#
#   override  Forcibly claims the plain name, replacing whatever Vanilla or
#             another plugin registered. Use this when you want EssentialsC
#             to win over e.g. EssentialsX's /fly or Vanilla's /gamemode.
#
#   normal    Standard behaviour - first plugin loaded wins the plain name.
#             This is the default and works fine in most setups.
#
#   low       Only registers the plain name if nothing else has claimed it yet.
#             Use this when another plugin should take priority.
#
# aliases
#   Additional names this command should respond to. These are registered
#   into the server's command map just like the main name, and also respect
#   the priority setting. Leave the list empty (or omit the key entirely)
#   if you don't need any aliases.
#
# cooldown
#   Time in seconds a player must wait between uses of this command.
#   Set to 0 or omit to disable. Console senders are never gated.
#
# cooldown-bypass
#   Permission node that lets a player skip the cooldown defined above.
#   Omit if you don't need a bypass for this command.


# Player commands


feed:
  enabled: true
  priority: normal
  aliases: []

fly:
  enabled: true
  priority: normal
  aliases: []

god:
  enabled: true
  priority: normal
  aliases: []

speed:
  enabled: true
  priority: normal
  aliases: []

ping:
  enabled: true
  priority: normal
  aliases: []

playtime:
  enabled: true
  priority: normal
  aliases: []

vanish:
  enabled: true
  priority: normal
  aliases: []

nick:
  enabled: true
  priority: normal
  aliases: []

realname:
  enabled: true
  priority: normal
  aliases: []

seen:
  enabled: true
  priority: normal
  aliases: []

afk:
  enabled: true
  priority: normal
  aliases: []
  cooldown: 60

afklist:
  enabled: true
  priority: normal
  aliases: []

sudo:
  enabled: true
  priority: normal
  aliases: []

rules:
  enabled: true
  priority: normal
  aliases: []

playerlist:
  enabled: true
  priority: normal
  aliases:
  - list

ptime:
  enabled: true
  priority: normal
  aliases: []

pweather:
  enabled: true
  priority: normal
  aliases: []

uptime:
  enabled: true
  priority: normal
  aliases: []

tpa:
  enabled: true
  priority: normal
  aliases: []
  # Cooldown is configured under tpa.cooldown in config.yml.
  # The bypass permission below matches the one checked in TPAManager.
  cooldown-bypass: essentialsc.tpa.bypass.cooldown

tpahere:
  enabled: true
  priority: normal
  aliases: []

tpaccept:
  enabled: true
  priority: normal
  aliases: []

tpdeny:
  enabled: true
  priority: normal
  aliases: []

tpcancel:
  enabled: true
  priority: normal
  aliases: []

tpaignore:
  enabled: true
  priority: normal
  aliases: []

tpatoggle:
  enabled: true
  priority: normal
  aliases: []

tpaqueue:
  enabled: true
  priority: normal
  aliases: []

tphere:
  enabled: true
  priority: normal
  aliases: []

tphereall:
  enabled: true
  priority: normal
  aliases: []

back:
  enabled: true
  priority: normal
  aliases: []
  # Cooldown is configured under back.cooldown in config.yml.
  # essentialsc.back.admin bypasses both the cooldown and warmup.
  cooldown-bypass: essentialsc.back.admin

spawn:
  enabled: true
  priority: normal
  aliases: []
  # Cooldown is configured under spawn.cooldown in config.yml.
  # essentialsc.spawn.admin bypasses both the cooldown and warmup.
  cooldown-bypass: essentialsc.spawn.admin

setspawn:
  enabled: true
  priority: normal
  aliases: []

rtp:
  enabled: true
  priority: normal
  aliases: []
  # Cooldown is configured under rtp.cooldown in config.yml.
  # The bypass permission below matches the one checked in RTPManager.
  cooldown-bypass: essentialsc.rtp.bypass.cooldown

top:
  enabled: true
  priority: normal
  aliases: []

home:
  enabled: true
  priority: normal
  aliases: []
  # Cooldown is configured under home.cooldown in config.yml.
  # essentialsc.home.admin bypasses both the cooldown and warmup.
  cooldown-bypass: essentialsc.home.admin

sethome:
  enabled: true
  priority: normal
  aliases: []
  cooldown: $CooldownSeconds

delhome:
  enabled: true
  priority: normal
  aliases: []

homes:
  enabled: true
  priority: normal
  aliases: []

warp:
  enabled: true
  priority: normal
  aliases: []
  # Cooldown is configured under warp.cooldown in config.yml.
  # The bypass permission below matches the one checked in WarpCommand.
  cooldown-bypass: essentialsc.warp.bypass.cooldown

setwarp:
  enabled: true
  priority: normal
  aliases: []

delwarp:
  enabled: true
  priority: normal
  aliases: []

warps:
  enabled: true
  priority: normal
  aliases: []

warpadmin:
  enabled: true
  priority: normal
  aliases: []

shop:
  enabled: true
  priority: normal
  aliases: []

ah:
  enabled: true
  priority: normal
  aliases:
  - auction

kit:
  enabled: true
  priority: normal
  aliases: []
# Kit cooldowns are configured per-kit in kits.yml and are DB-backed.
# Bypass permissions: essentialsc.kits.cooldown.bypass or essentialsc.kits.cooldown.bypass.<kitname>

kits:
  enabled: true
  priority: normal
  aliases: []

kiteditor:
  enabled: true
  priority: normal
  aliases: []

repair:
  enabled: true
  priority: normal
  aliases: []

rename:
  enabled: true
  priority: normal
  aliases: []

enchant:
  enabled: true
  priority: normal
  aliases: []

unenchant:
  enabled: true
  priority: normal
  aliases: []

hat:
  enabled: true
  priority: normal
  aliases: []

schedules:
  enabled: true
  priority: normal
  aliases: []

itemid:
  enabled: true
  priority: normal
  aliases:
  - iteminfo

anvil:
  enabled: true
  priority: normal
  aliases: []

craftingtable:
  enabled: true
  priority: normal
  aliases:
  - workbench

balance:
  enabled: true
  priority: normal
  aliases:
  - bal

baltop:
  enabled: true
  priority: normal
  aliases:
  - balancetop

invsee:
  enabled: true
  priority: normal
  aliases: []

clearinventory:
  enabled: true
  priority: normal
  aliases: []

enderchest:
  enabled: false
  priority: normal
  aliases: []

endersee:
  enabled: true
  priority: normal
  aliases: []

smite:
  enabled: true
  priority: normal
  aliases: []

kick:
  enabled: true
  priority: normal
  aliases: []

ban:
  enabled: true
  priority: normal
  aliases: []

unban:
  enabled: true
  priority: normal
  aliases: []

mute:
  enabled: true
  priority: normal
  aliases: []

unmute:
  enabled: true
  priority: normal
  aliases: []

checkpunish:
  enabled: true
  priority: normal
  aliases: []

msg:
  enabled: true
  priority: normal
  aliases: []

reply:
  enabled: true
  priority: normal
  aliases: []

ignore:
  enabled: true
  priority: normal
  aliases: []

essc:
  enabled: true
  priority: normal
  aliases: []

broadcast:
  enabled: true
  priority: normal
  aliases: []

scoreboard:
  enabled: true
  priority: normal
  aliases: []

spawnentity:
  enabled: true
  priority: normal
  aliases: []

language:
  enabled: true
  priority: normal
  aliases:
  - lang

migration:
  enabled: true
  priority: normal
  aliases: []

ban-ip:
  enabled: true
  priority: normal
  aliases:
  - banip
  - ipban

banlist:
  enabled: true
  priority: normal
  aliases:
  - bans

tpoffline:
  enabled: true
  priority: normal
  aliases: []

sell:
  enabled: true
  priority: normal
  aliases:
  - sellg
  - sellgui

worth:
  enabled: true
  priority: normal
  aliases: []
  cooldown-bypass: essentialsc.worth.bypass-cooldown

quicksell:
  enabled: true
  priority: normal
  aliases: []

dback:
  enabled: true
  priority: normal
  aliases: []
  # Cooldown is configured under back.cooldown in config.yml (shared with /back).
  # essentialsc.dback.admin bypasses both the cooldown and warmup.
  cooldown-bypass: essentialsc.dback.admin

trash:
  enabled: true
  priority: normal
  aliases:
  - disposal

suicide:
  enabled: true
  # override + alias kill: claims plain /kill over Vanilla so players get the
  # self-kill version (vanilla /kill stays available to ops as /minecraft:kill).
  priority: override
  aliases:
  - kill
  # Applies to both /suicide and /kill (cooldown is keyed to the suicide command).
  cooldown: $CooldownSeconds

stonecutter:
  enabled: true
  priority: normal
  aliases: []

gm:
  enabled: true
  priority: normal
  aliases: []

gamemode:
  enabled: true
  priority: normal
  aliases: []

gms:
  enabled: true
  priority: normal
  aliases: []

gmc:
  enabled: true
  priority: normal
  aliases: []

gmsp:
  enabled: true
  priority: normal
  aliases: []

gma:
  enabled: true
  priority: normal
  aliases: []

unban-ip:
  enabled: true
  priority: normal
  aliases: []

discord:
  enabled: true
  priority: normal
  aliases: []
freeze:
  enabled: true
  priority: normal
  aliases: []
unfreeze:
  enabled: true
  priority: normal
  aliases: []
"@
        Set-Content -Path $cmds -Value $commandsYml -Encoding ASCII
        Ok "EssentialsC commands.yml written (/kill = self-kill, ${CooldownSeconds}s cooldowns, echest command handed to VariableEnderChests)."
    }

    # ---- VariableEnderChests config ----------------------------------------
    # default-rows 6 = 54 slots on ONE page (no paging arrows).
    # No config reload - the plugin reads it at boot.
    $vecDir = "$InstallDir\plugins\VariableEnderChests"
    $vecCfg = "$vecDir\config.yml"
    New-Item -ItemType Directory -Force -Path $vecDir | Out-Null
    if (Test-Path $vecCfg) {
        Ok "VariableEnderChests config.yml already present. Keeping it."
    } else {
        $vecYml = @"
#Do not change this manually, this is to keep track of config changes.
config-version: 7

#If mysql is set to false, database defaults to a data.db file
#Do not set mysql to true unless you have a mysql database set up
database:
  mysql: false
  host: 'localhost'
  port: 3306
  database: 'database'
  username: 'username'
  password: 'password'

#If this is set to true, it will convert current ender chests to be used by this plugin;
#If set to false, when players log in their vanilla enderchest contents will not transfer over.
#Whether this is set to true or false, does NOT affect the enderchest contents that is saved by default minecraft.
convert-current-ender-chest: true

#If this is set to 0, players will need a permission to be able to open an enderchest
default-rows: $EchestRows

default-locale: 'en_us'

#This is used when the plugin hooks into placeholder api to provide placeholders
#This allows you to modify the placeholder identifier.
#Placeholders can be parsed as %<papi-identifier>_size%
papi-identifier: 'variableenderchests'

#You can use this to register the commands that can be used to access the enderchest.
#The first command is the main command.
#Any other command in the list will be considered as aliases.
open-enderchest-commands:
  - 'enderchest'
  - 'echest'

#Any worlds specified here will not have access to the Variable Ender Chest
#Players will not be able to access it via command OR block.
#Instead accessing blocks will open the default vanilla enderchest.
disabled-worlds:

blacklisted-items:
  - 'COMMAND_BLOCK'
"@
        Set-Content -Path $vecCfg -Value $vecYml -Encoding ASCII
        Ok "VariableEnderChests config.yml written (default-rows $EchestRows = $(9 * $EchestRows) slots, one page, vanilla contents converted)."
    }

    # ---- Reach datapack ------------------------------------------------------
    # Folia 26.2 quirk: tick functions (#minecraft:tick) never execute, so the
    # reach is applied through a hidden advancement with a minecraft:tick
    # trigger + function reward - fires once per player, on join. The
    # "Error reading pack metadata" line in the boot log is benign.
    $pack = "$InstallDir\world\datapacks\reach-5"
    if (Test-Path "$pack\pack.mcmeta") {
        Ok "reach datapack already present. Keeping it."
    } else {
        New-Item -ItemType Directory -Force -Path `
            $pack, "$pack\data\reach5\advancement", "$pack\data\reach5\function" | Out-Null
        Set-Content -Path "$pack\pack.mcmeta" -Encoding ASCII -Value @"
{
  "pack": {
    "pack_format": 107,
    "description": "Extended player reach (block + entity interaction range) for every player, applied once on join"
  }
}
"@
        Set-Content -Path "$pack\data\reach5\advancement\apply.json" -Encoding ASCII -Value @"
{
  "criteria": {
    "triggered": {
      "trigger": "minecraft:tick"
    }
  },
  "rewards": {
    "function": "reach5:apply"
  }
}
"@
        Set-Content -Path "$pack\data\reach5\function\apply.mcfunction" -Encoding ASCII -Value @"
execute as @a run attribute @s minecraft:block_interaction_range base set $ReachBlocks
execute as @a run attribute @s minecraft:entity_interaction_range base set $ReachBlocks
"@
        Ok "reach datapack written ($ReachBlocks block/entity reach for every player on join)."
    }
}

# ----------------------------------------------------------------------------
# 7. Toxiproxy jitter endpoint (simulated real-world ping on 127.0.0.1:25566)
# ----------------------------------------------------------------------------
function Install-Toxiproxy {
    if ($NoJitter) { Log "Jitter proxy skipped (-NoJitter)."; return }

    New-Item -ItemType Directory -Force -Path $ToxiDir | Out-Null
    $serverExe = "$ToxiDir\$ToxiServerExe"
    $cliExe    = "$ToxiDir\$ToxiCliExe"

    foreach ($f in @(
        @{ Name = $ToxiServerExe; Path = $serverExe; Sha = $ToxiServerSha256 },
        @{ Name = $ToxiCliExe;    Path = $cliExe;    Sha = $ToxiCliSha256 }
    )) {
        if ((Test-Path $f.Path) -and ((Get-Item $f.Path).Length -gt 1MB)) {
            Ok "$($f.Name) already present. Skipping download."
            continue
        }
        Log "Downloading $($f.Name) (toxiproxy v$ToxiVersion)..."
        Get-WebFile "https://github.com/Shopify/toxiproxy/releases/download/v$ToxiVersion/$($f.Name)" $f.Path
        $hash = (Get-FileHash -Algorithm SHA256 -Path $f.Path).Hash
        if ($hash -ne $f.Sha) { throw "$($f.Name) SHA256 mismatch (expected $($f.Sha), got $hash)" }
        Ok "$($f.Name) downloaded (SHA256 verified)."
    }

    # helper bats (like the reference setup)
    if (-not (Test-Path "$ToxiDir\start-toxiproxy.bat")) {
        Set-Content -Path "$ToxiDir\start-toxiproxy.bat" -Encoding ASCII -Value @"
@echo off
rem Starts Toxiproxy (localhost only) and (re)creates the folia latency proxy.
rem Connect Minecraft to 127.0.0.1:$JitterPort to play with simulated ping.
cd /d "%~dp0"
tasklist /FI "IMAGENAME eq toxiproxy-server-windows-amd64.exe" 2>nul | find /I "toxiproxy-server" >nul
if errorlevel 1 (
    echo Starting toxiproxy-server on 127.0.0.1:$ToxiApiPort ...
    start "toxiproxy" /min toxiproxy-server-windows-amd64.exe -host 127.0.0.1 -port $ToxiApiPort
    timeout /t 2 /nobreak >nul
)
toxiproxy-cli-windows-amd64.exe -h 127.0.0.1:$ToxiApiPort delete folia >nul 2>&1
toxiproxy-cli-windows-amd64.exe -h 127.0.0.1:$ToxiApiPort create -l 127.0.0.1:$JitterPort -u 127.0.0.1:$McPort folia
toxiproxy-cli-windows-amd64.exe -h 127.0.0.1:$ToxiApiPort toxic add -t latency -a latency=$JitterLatencyMs -a jitter=$JitterVarianceMs --downstream folia
toxiproxy-cli-windows-amd64.exe -h 127.0.0.1:$ToxiApiPort toxic add -t latency -a latency=$JitterLatencyMs -a jitter=$JitterVarianceMs --upstream folia
echo.
echo Ready. Connect Minecraft to 127.0.0.1:$JitterPort  (+$JitterLatencyMs ms each direction)
pause
"@
    }
    if (-not (Test-Path "$ToxiDir\stop-toxiproxy.bat")) {
        Set-Content -Path "$ToxiDir\stop-toxiproxy.bat" -Encoding ASCII -Value @"
@echo off
taskkill /IM toxiproxy-server-windows-amd64.exe /F >nul 2>&1
echo Toxiproxy stopped.
pause
"@
    }

    # start the server (windowless) if the API port is not up yet
    if (Test-PortListening $ToxiApiPort) {
        Ok "toxiproxy already running (API on 127.0.0.1:$ToxiApiPort)."
    } else {
        Log "Starting toxiproxy (windowless, localhost-only)..."
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $serverExe
        $psi.Arguments = "-host 127.0.0.1 -port $ToxiApiPort"
        $psi.WorkingDirectory = $ToxiDir
        $psi.UseShellExecute = $true
        $psi.WindowStyle = 'Hidden'
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        $up = $false
        for ($i = 0; $i -lt 20; $i++) {
            Start-Sleep 1
            if (Test-PortListening $ToxiApiPort) { $up = $true; break }
        }
        if (-not $up) { Warn "toxiproxy did not come up - jitter endpoint not available."; return }
        Ok "toxiproxy started."
    }

    # ensure the proxy + latency toxics exist with the desired values
    # (recreating drops active connections through the jitter port, so it is
    # only done when the proxy is missing or the values changed)
    $cli = $cliExe
    function Invoke-ToxiCli([string]$Arguments) {
        (cmd /c "`"$cli`" -h 127.0.0.1:$ToxiApiPort $Arguments 2>nul") | Out-String
    }
    $inspect = Invoke-ToxiCli "inspect folia"
    $needRecreate = $true
    if ($inspect.Trim().Length -gt 0) {
        $latAll = [regex]::Matches($inspect, 'latency=(\d+)')
        $jitAll = [regex]::Matches($inspect, 'jitter=(\d+)')
        if ($inspect -match 'latency_downstream' -and $inspect -match 'latency_upstream' -and
            $latAll.Count -ge 2 -and $jitAll.Count -ge 2) {
            $latOk = $true; foreach ($m in $latAll) { if ([int]$m.Groups[1].Value -ne $JitterLatencyMs) { $latOk = $false } }
            $jitOk = $true; foreach ($m in $jitAll) { if ([int]$m.Groups[1].Value -ne $JitterVarianceMs) { $jitOk = $false } }
            if ($latOk -and $jitOk) { $needRecreate = $false }
        }
    }
    if (-not $needRecreate) {
        Ok "jitter endpoint already configured: 127.0.0.1:$JitterPort (+$JitterLatencyMs +/- $JitterVarianceMs ms per direction)."
        return
    }
    Invoke-ToxiCli "delete folia" | Out-Null
    Invoke-ToxiCli "create -l 127.0.0.1:$JitterPort -u 127.0.0.1:$McPort folia" | Out-Null
    Invoke-ToxiCli "toxic add -t latency -a latency=$JitterLatencyMs -a jitter=$JitterVarianceMs --downstream folia" | Out-Null
    Invoke-ToxiCli "toxic add -t latency -a latency=$JitterLatencyMs -a jitter=$JitterVarianceMs --upstream folia" | Out-Null
    Ok "jitter endpoint ready: 127.0.0.1:$JitterPort  (+$JitterLatencyMs +/- $JitterVarianceMs ms per direction = ~$(2 * $JitterLatencyMs)ms RTT)"
}

# ----------------------------------------------------------------------------
# 8. Boot + permissions via RCON
# ----------------------------------------------------------------------------
function Invoke-LocalRcon {
    param([string]$Command)
    powershell -NoProfile -ExecutionPolicy Bypass -File "$InstallDir\rcon.ps1" -Command $Command
}

# /home + /tpa cooldowns live in plugins\EssentialsC\config.yml (sethome and
# kill are already in the pre-written commands.yml). Only rewritten when a
# value actually differs; takes effect via `essc reload` - no restart needed.
function Set-EssentialsConfigCooldowns {
    $cfg = "$InstallDir\plugins\EssentialsC\config.yml"
    if (-not (Test-Path $cfg)) { return }
    $lines = @(Get-Content $cfg)
    $changed = $false
    $section = ""
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^([A-Za-z0-9_-]+):\s*(#.*)?$') { $section = $Matches[1] }
        if (($section -eq "home" -or $section -eq "tpa") -and
            $lines[$i] -match '^(\s+cooldown:)\s*\d+') {
            $new = $Matches[1] + " " + $CooldownSeconds
            if ($lines[$i] -ne $new) { $lines[$i] = $new; $changed = $true }
        }
    }
    if ($changed) {
        Set-Content -Path $cfg -Value $lines
        Ok "EssentialsC config.yml: /home and /tpa cooldown set to ${CooldownSeconds}s."
    } else {
        Ok "EssentialsC config.yml cooldowns already at ${CooldownSeconds}s."
    }
}

function Start-ServerIfNeeded {
    if (Test-PortListening $McPort) {
        Ok "server already running on port $McPort."
        return $false
    }
    Log "Starting server (first boot generates the world - can take a few minutes)..."
    if ($StartHidden) {
        Start-Process -FilePath "$InstallDir\run-hidden.bat" -WorkingDirectory $InstallDir -WindowStyle Hidden
    } else {
        Start-Process -FilePath "$InstallDir\run.bat" -WorkingDirectory $InstallDir
    }
    return $true
}

function Wait-Rcon([int]$MaxSeconds = 600) {
    for ($i = 0; $i -lt ($MaxSeconds / 5); $i++) {
        try {
            $t = New-Object System.Net.Sockets.TcpClient
            $t.Connect("127.0.0.1", $RconPort)
            $t.Close()
            return $true
        } catch {}
        Start-Sleep 5
        if ($i % 12 -eq 11) { Log "still waiting for the server..." }
    }
    return $false
}

function Invoke-PostBootConfig {
    # operator for the person running setup (only when nobody is opped yet)
    $opsFile = "$InstallDir\ops.json"
    $hadOps = (Test-Path $opsFile) -and ((Get-Content $opsFile -Raw).Trim() -notin @("", "[]"))
    if (-not $hadOps) {
        if ($OpUsername -eq "") {
            $OpUsername = Read-Host "Your Minecraft username to make operator (Enter to skip)"
        }
        if ($OpUsername -ne "") {
            try {
                Invoke-LocalRcon "op $OpUsername" | Out-Null
                Ok "opped $OpUsername"
            } catch { Warn "could not op '$OpUsername': $($_.Exception.Message)" }
        }
    }

    # LuckPerms grants - idempotent, safe to repeat on every run.
    # NOTE: `lp` often returns an EMPTY RCON response but still executes.
    foreach ($node in @("essentialsc.home", "essentialsc.sethome",
                        "essentialsc.delhome", "essentialsc.homes",
                        "essentialsc.suicide")) {
        try {
            Invoke-LocalRcon "lp group default permission set $node true" | Out-Null
            Ok "granted $node to all players (default group)"
        } catch {
            Warn "LuckPerms grant for $node did not confirm (usually still applied)"
        }
    }

    # Ops have every permission by default, which would silently bypass the
    # /home and /tpa cooldowns. Explicit LuckPerms false overrides that, so
    # the cooldowns (and the 3s /home warmup) apply to ops too.
    if (Test-Path $opsFile) {
        try {
            $ops = Get-Content $opsFile -Raw | ConvertFrom-Json
            foreach ($o in @($ops)) {
                if (-not $o.name) { continue }
                try {
                    Invoke-LocalRcon "lp user $($o.name) permission set essentialsc.home.admin false" | Out-Null
                    Invoke-LocalRcon "lp user $($o.name) permission set essentialsc.tpa.bypass.cooldown false" | Out-Null
                    Ok "cooldown bypass disabled for op $($o.name)"
                } catch { Warn "could not set cooldown negation for $($o.name)" }
            }
        } catch { Warn "could not read ops.json: $($_.Exception.Message)" }
    }

    # /home + /tpa cooldowns in config.yml + live reload (no restart needed)
    Set-EssentialsConfigCooldowns
    try {
        Invoke-LocalRcon "essc reload" | Out-Null
        Ok "EssentialsC reloaded (cooldowns live)."
    } catch { Warn "essc reload did not confirm - cooldowns apply after the next restart." }
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host "  Folia $McVersion direct server setup for Windows" -ForegroundColor Magenta
Write-Host "  homes + /kill + cooldowns + reach + 54-slot echest + ping sim" -ForegroundColor Magenta
Write-Host "  No whitelist - offline mode - re-runnable, never re-downloads" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta

Install-Java25
Get-Folia
Install-Plugins
Write-Configs
Write-FeatureConfigs
Install-Toxiproxy

if ($NoStart) {
    Ok "Setup complete (server not started). Run run.bat to start."
} else {
    $startedByScript = Start-ServerIfNeeded
    if (Wait-Rcon) {
        Invoke-PostBootConfig
        Write-Host ""
        Ok "SERVER IS UP - join at  localhost:$McPort"
        if (-not $NoJitter) { Ok "With simulated ping: localhost:$JitterPort (~$(2 * $JitterLatencyMs)ms RTT)" }
        if ($startedByScript -and -not $StartHidden) { Ok "Server console is the window that opened. Stop it with stop.bat." }
    } else {
        throw "Server did not open RCON within 10 minutes. Check the server window for errors."
    }
    if (-not $NoPause) {
        Write-Host ""
        Read-Host "Press Enter to close this window (the server keeps running)"
    }
}
