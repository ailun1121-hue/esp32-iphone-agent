<#
.SYNOPSIS
    Windows-native equivalent of hardware/flash.sh for esp32-iphone-agent.

.DESCRIPTION
    flash.sh targets macOS/Linux (it hard-codes /dev/cu.usbmodem*, stty, comm). This script does the
    same two essential things on Windows:

      1. Force-includes hid_bridge/nimble_cfg.h into every C/C++ translation unit so NimBLE-Arduino
         host buffers match what ble_link.cpp's static_asserts require. Without it the sketch will
         NOT compile (the asserts fire) -- it cannot fail silently.
      2. Compiles with the exact FQBN from flash.sh and uploads over a Windows COM port.

    Board: ESP32-S3 with 8 MB PSRAM + native USB (e.g. XIAO ESP32S3, or N16R8 dev boards).

    NOTE: FlashSize=8M / PartitionScheme=default_8MB intentionally match upstream. A 16 MB (N16)
    board works fine; the unused upper 8 MB is simply not partitioned. Keep upstream's values
    unless you have a reason not to.

.PARAMETER Port
    COM port, e.g. COM15. Auto-detected when omitted.

.PARAMETER DebugSerial
    -DDEBUG_SERIAL=1 : echo commands and the AirPlay handshake on USB serial.
    Named -DebugSerial because -Debug is a built-in common parameter and would collide.

.PARAMETER Sta
    -DSTA_FROM_SECRETS=1 : join the Wi-Fi in hid_bridge/secrets.h instead of opening a hotspot.

.PARAMETER ApTune
    -DAP_TUNE=1 : hotspot on a 20 MHz channel with 300 TU beacons (more airtime for BLE).

.PARAMETER BuildOnly
    Compile only; print flash/RAM usage and stop before uploading.

.EXAMPLE
    .\flash_win.ps1
    .\flash_win.ps1 COM15 -DebugSerial
    .\flash_win.ps1 -BuildOnly
#>
[CmdletBinding()]
param(
    [string]$Port,
    [switch]$DebugSerial,
    [switch]$Sta,
    [switch]$ApTune,
    [switch]$BuildOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ---------------------------------------------------------------- locations
$Here       = Split-Path -Parent $MyInvocation.MyCommand.Path
$SketchDir  = Join-Path $Here 'hid_bridge'
$NimbleCfg  = Join-Path $SketchDir 'nimble_cfg.h'
$BuildDir   = Join-Path $Here 'build'

# arduino-cli writes its data under %LOCALAPPDATA%\Arduino15 by default, which may be unwritable in a
# sandboxed/CI environment. Allow an override, and fall back to a repo-local directory.
if (-not $env:ARDUINO_DIRECTORIES_DATA) {
    $local = Join-Path $Here '.arduino15'
    New-Item -ItemType Directory -Force -Path $local, (Join-Path $local 'staging'), (Join-Path $local 'user') | Out-Null
    $env:ARDUINO_DIRECTORIES_DATA      = $local
    $env:ARDUINO_DIRECTORIES_DOWNLOADS = Join-Path $local 'staging'
    $env:ARDUINO_DIRECTORIES_USER      = Join-Path $local 'user'
}

# The compile cache defaults to %LOCALAPPDATA%\arduino, which is likewise outside a sandbox. Point it
# at a repo-local directory once, so 'Cannot create build cache directory' never happens.
$CacheDir = Join-Path $Here '.arduino-build-cache'

# Same FQBN as flash.sh. Keep the order of the options; arduino-cli parses them strictly.
$Fqbn = 'esp32:esp32:esp32s3:USBMode=default,CDCOnBoot=cdc,FlashSize=8M,PSRAM=opi,PartitionScheme=default_8MB'

# ---------------------------------------------------------------- helpers
function Find-ArduinoCli {
    # an explicit ARDUINO_CLI wins; then PATH; then a repo-local tools dir
    if ($env:ARDUINO_CLI -and (Test-Path $env:ARDUINO_CLI)) { return $env:ARDUINO_CLI }
    $cmd = Get-Command arduino-cli -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $local = Join-Path (Split-Path -Parent $Here) '.tools\arduino-cli.exe'
    if (Test-Path $local) { return $local }
    throw 'arduino-cli not found. Install it (https://arduino.github.io/arduino-cli/) or set $env:ARDUINO_CLI.'
}

function Get-ComPorts {
    # Only ports that actually exist as serial devices. Bluetooth SPP ports are excluded: they are
    # virtual modems, never a board.
    [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object -Unique
}

function Resolve-PythonForCore {
    # A usable Python interpreter, or $null. ESP32_PYTHON overrides the search.
    if ($env:ESP32_PYTHON -and (Test-Path $env:ESP32_PYTHON)) { return $env:ESP32_PYTHON }
    foreach ($candidate in 'python', 'python3', 'py') {
        $found = Get-Command $candidate -ErrorAction SilentlyContinue
        if (-not $found) { continue }
        # Reject the Microsoft Store alias stub: it exits non-zero without running anything.
        & $found.Source -c 'import sys' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return $found.Source }
    }
    return $null
}

function Get-CoreToolsDir {
    # <data>/packages/esp32/hardware/esp32/<version>/tools, newest version first.
    param([string]$ArduinoCli)
    $config = & $ArduinoCli config dump 2>$null | Out-String
    $m = [regex]::Match($config, '(?m)^\s*data:\s*(.+?)\s*$')
    if (-not $m.Success) { return $null }
    $packages = Join-Path $m.Groups[1].Value 'packages\esp32\hardware\esp32'
    if (-not (Test-Path $packages)) { return $null }
    Get-ChildItem $packages -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName 'tools' } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
}

function Resolve-CoreScript {
    # Command line that runs <name>.py from the core's tools dir, or $null to keep the bundled .exe.
    #
    # Why: the esp32 core ships several Windows helpers as PyInstaller one-file exes (gen_esp32part,
    # flasher, espota, ...). Each unpacks helper DLLs at startup; on a locked-down or read-only
    # toolchain directory that dies with "Failed to extract VCRUNTIME140.dll ... fopen: Permission
    # denied", aborting the build after everything has compiled. The .py implementation ships right
    # next to each .exe, so prefer it when an interpreter is available. Same output, no behaviour change.
    param([string]$ArduinoCli, [string]$Name)

    if ($env:ESP32_NATIVE_TOOLS -eq 'exe') { return $null }   # escape hatch: force the bundled exes

    $toolsDir = Get-CoreToolsDir -ArduinoCli $ArduinoCli
    if (-not $toolsDir) { return $null }
    $pyScript = Join-Path $toolsDir "$Name.py"
    if (-not (Test-Path $pyScript)) { return $null }

    $python = Resolve-PythonForCore
    if (-not $python) { return $null }
    return "$(Quote-Arg $python) $(Quote-Arg $pyScript)"
}

function Quote-Arg {
    param([string]$Value)
    '"' + $Value + '"'
}

function Test-IsEsp32 {
    param([string]$ComPort)
    # Ask the chip. A stale/historical COM port or a different device simply fails to answer.
    $esptool = Get-Command esptool -ErrorAction SilentlyContinue
    if (-not $esptool) { return $null }   # cannot verify; caller decides
    $out = & $esptool.Source -p $ComPort -b 115200 --connect-attempts 1 chip-id 2>&1 | Out-String
    if ($out -match 'ESP32-S\d|ESP32-S3') { return 'ESP32-S3' }
    if ($out -match 'Detecting chip type') { return 'other-esp32' }
    return $null
}

# ---------------------------------------------------------------- preflight
if (-not (Test-Path $NimbleCfg)) { throw "missing $NimbleCfg" }

# flash.sh refuses paths with spaces because of the -include argument. On Windows we quote properly,
# so spaces are fine -- but keep the check visible so nobody is surprised by a mangled argument.
$defs = @("-include `"$NimbleCfg`"")
if ($DebugSerial) { $defs += '-DDEBUG_SERIAL=1' }
if ($ApTune)  { $defs += '-DAP_TUNE=1' }
if ($Sta) {
    if (-not (Test-Path (Join-Path $SketchDir 'secrets.h'))) {
        throw '-Sta needs hid_bridge\secrets.h (copy secrets.example.h and fill in WIFI_SSID / WIFI_PASS).'
    }
    $defs += '-DSTA_FROM_SECRETS=1'
}
$defString = $defs -join ' '

$arduinoCli = Find-ArduinoCli
Write-Host "arduino-cli : $arduinoCli" -ForegroundColor DarkGray
Write-Host "extra flags : $defString" -ForegroundColor DarkGray

# Keep arduino-cli's compile cache inside the repo (idempotent; harmless if already set).
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
& $arduinoCli config set build_cache.path $CacheDir | Out-Null

# ---------------------------------------------------------------- compile
# flash.sh passes the same definition to BOTH compiler.cpp.extra_flags and compiler.c.extra_flags.
# nimble_cfg.h must reach C++ files (ble_link.cpp) AND C files (the AirPlay / playfair C sources),
# so both properties are required. A single 'build.extra_flags' would not work here.
$compileArgs = @(
    'compile',
    '-b', $Fqbn,
    '--build-property', "compiler.cpp.extra_flags=$defString",
    '--build-property', "compiler.c.extra_flags=$defString",
    '--output-dir', $BuildDir,
    '--warnings', 'default'
)

# The esp32 core ships several Windows helpers as PyInstaller single-file exes (see Resolve-CoreScript).
# gen_esp32part runs during the build, flasher during the upload; point both at their .py twins.
$partitionTool = Resolve-CoreScript -ArduinoCli $arduinoCli -Name 'gen_esp32part'
if ($partitionTool) {
    Write-Host "partition tool: $partitionTool" -ForegroundColor DarkGray
    $compileArgs += @('--build-property', "tools.gen_esp32part.cmd.windows=$partitionTool")
}

$compileArgs += $SketchDir

Write-Host "`n=== Compiling (ESP32-S3, 8MB flash, OPI PSRAM) ===" -ForegroundColor Cyan
& $arduinoCli @compileArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "`nCompile FAILED (exit $LASTEXITCODE)." -ForegroundColor Red
    Write-Host 'If you see a static_assert about nimble_cfg.h, the -include flags did not reach the' -ForegroundColor Yellow
    Write-Host 'compiler -- do not flash such a build; BLE throughput would collapse.' -ForegroundColor Yellow
    exit 1
}

$bin = Join-Path $BuildDir 'hid_bridge.ino.bin'
if (Test-Path $bin) {
    $mb = [math]::Round((Get-Item $bin).Length / 1MB, 3)
    Write-Host "`nFirmware: $bin ($mb MB)" -ForegroundColor Green
}

if ($BuildOnly) { Write-Host 'Build-only: skipping upload.' -ForegroundColor Green; exit 0 }

# ---------------------------------------------------------------- choose port
if (-not $Port) {
    $candidates = @(Get-ComPorts)
    if ($candidates.Count -eq 0) { throw 'No COM ports found. Plug the board in and try again.' }

    if ($candidates.Count -gt 1) {
        Write-Host "`nSeveral COM ports present: $($candidates -join ', ')" -ForegroundColor Yellow
        Write-Host 'Probing each for an ESP32-S3 ...' -ForegroundColor DarkGray
        $verified = @()
        foreach ($c in $candidates) {
            $kind = Test-IsEsp32 -ComPort $c
            if ($kind) { Write-Host "  $c -> $kind" -ForegroundColor DarkGray } else { Write-Host "  $c -> no answer" -ForegroundColor DarkGray }
            if ($kind -eq 'ESP32-S3') { $verified += $c }
        }
        if ($verified.Count -eq 1) {
            $Port = $verified[0]
        } elseif ($verified.Count -gt 1) {
            throw "Several ESP32-S3 boards answered ($($verified -join ', ')). Pass one explicitly: .\flash_win.ps1 $($verified[0])"
        } else {
            throw "None of the ports answered as an ESP32-S3. Pass the right one explicitly: .\flash_win.ps1 COMx"
        }
    } else {
        $Port = $candidates[0]
    }
}
$Port = $Port.ToUpperInvariant()
Write-Host "`nPort: $Port" -ForegroundColor Cyan

# ---------------------------------------------------------------- upload
$uploadArgs = @('upload', '-b', $Fqbn, '-p', $Port, '--input-dir', $BuildDir)
$flashPrefix = Resolve-CoreScript -ArduinoCli $arduinoCli -Name 'flasher'
if ($flashPrefix) {
    Write-Host "flash helper: $flashPrefix" -ForegroundColor DarkGray
    $uploadArgs += @('--upload-property', "tools.esptool_py.upload.flash_prefix.windows=$flashPrefix")
}
$uploadArgs += $SketchDir

Write-Host '=== Uploading ===' -ForegroundColor Cyan
& $arduinoCli @uploadArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "`nUpload FAILED (exit $LASTEXITCODE)." -ForegroundColor Red
    Write-Host 'If the port is busy, the app/monitor holding it may be open. Hold BOOT and tap RESET to' -ForegroundColor Yellow
    Write-Host 'enter the ROM bootloader, then retry.' -ForegroundColor Yellow
    exit 1
}

Write-Host "`nDone. Firmware flashed to $Port." -ForegroundColor Green
Write-Host 'Watch it boot:  arduino-cli monitor -p ' -NoNewline
Write-Host "$Port -c baudrate=115200" -ForegroundColor White
Write-Host 'Expect a "ble: msys ..." line confirming the NimBLE buffers, then hotspot + BLE advertising.' -ForegroundColor DarkGray
