# ============================================================================
#  Folia 26.2 Direct Server Setup for Windows
#  ---------------------------------------------------------------
#  Downloads everything from the internet into a fresh folder:
#    - Folia 26.2 (build 7 pinned, falls back to latest)
#    - Java 25 (Eclipse Temurin, bundled in .\java25\)
#    - WorldEdit, LuckPerms, Chunky (Folia-compatible)
#    - ViaVersion / ViaBackwards / ViaRewind (best effort)
#    - EssentialsC (homes: /sethome /home /delhome /homes for ALL players)
#  No NoCheatPlus. No proxy. No CoreProtect. No gamerule commands.
#  No whitelist. Offline mode (same as the reference setup).
#
#  HOW TO RUN (your friends):
#    1. Save this file, e.g. to Desktop
#    2. Right-click it  ->  "Run with PowerShell"
#    3. Wait. It asks for your Minecraft name to make you operator.
#    4. Join: localhost:25565
#
#  To re-run / repair: just run it again. Existing files are kept.
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
    [switch]$NoStart,                    # download + configure only, don't boot
    [switch]$NoPause                     # don't wait for Enter at the end
)

$ErrorActionPreference = "Stop"
$UserAgent = "FoliaWinSetup/1.0"
Add-Type -AssemblyName System.IO.Compression.FileSystem

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
    param([string]$Url, [string]$OutFile, [hashtable]$Headers = @{})
    for ($i = 1; $i -le 3; $i++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -Headers $Headers `
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
# 4. Plugins from Modrinth
# ----------------------------------------------------------------------------
function Get-ModrinthPlugin {
    param([string]$Slug, [string]$OutName, [string]$FileMatch = "", [bool]$Required = $false)
    $out = "$InstallDir\plugins\$OutName"
    if (Test-PluginJar $out) { Ok "$OutName already present. Skipping."; return }

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

function Install-Plugins {
    Log "Downloading plugins from Modrinth..."
    Get-ModrinthPlugin -Slug "worldedit"     -OutName "WorldEdit.jar"     -FileMatch "bukkit" -Required $true
    Get-ModrinthPlugin -Slug "luckperms"    -OutName "LuckPerms.jar"     -FileMatch "bukkit"
    Get-ModrinthPlugin -Slug "chunky"       -OutName "Chunky.jar"        -FileMatch "bukkit"
    Get-ModrinthPlugin -Slug "essentialsc"  -OutName "EssentialsC.jar"
    Get-ModrinthPlugin -Slug "viaversion"   -OutName "ViaVersion.jar"
    Get-ModrinthPlugin -Slug "viabackwards" -OutName "ViaBackwards.jar"
    Get-ModrinthPlugin -Slug "viarewind"    -OutName "ViaRewind.jar"
    Ok "Plugins ready."
}

# ----------------------------------------------------------------------------
# 5. Configs (mirrors the reference setup: no whitelist, offline mode, RCON)
# ----------------------------------------------------------------------------
function Write-Configs {
    # Random RCON password, generated once per install
    $passFile = "$InstallDir\.rconpass"
    if (Test-Path $passFile) {
        $rconPass = (Get-Content $passFile -Raw).Trim()
    } else {
        $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789'
        $rconPass = -join ((1..32) | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
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
    Set-Content -Path "$InstallDir\server.properties" -Value $sp -Encoding ASCII

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
    Set-Content -Path "$InstallDir\run.bat" -Value $runBat -Encoding ASCII

    # RCON helper in PowerShell (no Python needed) with the generated password baked in
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

    $stopBat = @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rcon.ps1" -Command stop
"@
    Set-Content -Path "$InstallDir\stop.bat" -Value $stopBat -Encoding ASCII

    $readme = @"
FOLIA $McVersion SERVER - QUICK REFERENCE
=========================================
Start server : double-click run.bat
Stop server  : double-click stop.bat  (or type stop in the server console)
Send command : powershell -ExecutionPolicy Bypass -File rcon.ps1 -Command "list"

Join         : localhost:25565  (or this PC's LAN IP from other machines)

Homes (everyone has these): /sethome  /home  /delhome  /homes
Operator console commands : type them straight into the server window

RCON password is stored in the hidden file .rconpass
"@
    Set-Content -Path "$InstallDir\README.txt" -Value $readme -Encoding ASCII
    Ok "Configs written (no whitelist, homes enabled, RCON on $RconPort)."
}

# ----------------------------------------------------------------------------
# 6. First boot + permissions via RCON
# ----------------------------------------------------------------------------
function Invoke-LocalRcon {
    param([string]$Command)
    powershell -NoProfile -ExecutionPolicy Bypass -File "$InstallDir\rcon.ps1" -Command $Command
}

function Start-AndConfigure {
    Log "Starting server (first boot generates the world - can take a few minutes)..."
    Start-Process -FilePath "$InstallDir\run.bat" -WorkingDirectory $InstallDir

    Log "Waiting for the server to come up (RCON on port $RconPort)..."
    $ready = $false
    for ($i = 1; $i -le 120; $i++) {
        Start-Sleep 5
        try {
            $t = New-Object System.Net.Sockets.TcpClient
            $t.Connect("127.0.0.1", $RconPort)
            $t.Close()
            $ready = $true
            break
        } catch {}
        if ($i % 6 -eq 0) { Log ("still waiting... ({0} min)" -f [math]::Floor($i * 5 / 60)) }
    }
    if (-not $ready) { throw "Server did not open RCON within 10 minutes. Check the server window for errors." }

    Start-Sleep 5

    # Operator for the person running setup
    if ($OpUsername -eq "") {
        $OpUsername = Read-Host "Your Minecraft username to make operator (Enter to skip)"
    }
    if ($OpUsername -ne "") {
        try {
            $resp = Invoke-LocalRcon "op $OpUsername"
            Ok "op $OpUsername -> $resp"
        } catch { Warn "could not op '$OpUsername': $($_.Exception.Message)" }
    }

    # Homes for everyone (EssentialsC defaults these to true; set explicitly
    # through LuckPerms as well so it holds even if plugin defaults change)
    foreach ($node in @("essentialsc.home", "essentialsc.sethome",
                        "essentialsc.delhome", "essentialsc.homes")) {
        try {
            Invoke-LocalRcon "lp group default permission set $node true" | Out-Null
            Ok "granted $node to all players (default group)"
        } catch {
            Warn "LuckPerms grant for $node did not confirm (fine if defaults are active)"
        }
    }

    Write-Host ""
    Ok "SERVER IS UP - join at  localhost:$McPort"
    Ok "Server console is the window that opened. Stop it with stop.bat."
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host "  Folia $McVersion direct server setup for Windows" -ForegroundColor Magenta
Write-Host "  WorldEdit / LuckPerms / Chunky / Via* / EssentialsC homes" -ForegroundColor Magenta
Write-Host "  No whitelist - offline mode - no NoCheatPlus" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta

Install-Java25
Get-Folia
Install-Plugins
Write-Configs

if ($NoStart) {
    Ok "Setup complete (server not started). Run run.bat to start."
} else {
    Start-AndConfigure
    if (-not $NoPause) {
        Write-Host ""
        Read-Host "Press Enter to close this window (the server keeps running)"
    }
}
