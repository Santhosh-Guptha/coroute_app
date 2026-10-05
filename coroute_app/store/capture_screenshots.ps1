# Takes Play Store screenshots from a phone connected over USB.
# Needs adb (Android platform tools) on PATH and USB debugging on the phone.
# Usage (from the coroute_app folder):  powershell -ExecutionPolicy Bypass -File store\capture_screenshots.ps1

$ErrorActionPreference = 'Stop'
$out = Join-Path $PSScriptRoot 'screenshots'
New-Item -ItemType Directory -Force -Path $out | Out-Null

$adb = (Get-Command adb -ErrorAction SilentlyContinue).Source
if (-not $adb) {
  $sdk = Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'
  if (Test-Path $sdk) { $adb = $sdk } else { throw 'adb not found. Install Android platform tools or add them to PATH.' }
}

$devices = & $adb devices | Select-String -Pattern "`tdevice$"
if (-not $devices) { throw 'No phone found. Connect it over USB and allow USB debugging.' }

$shots = @(
  @{ file = '01_cockpit_map';      tip = 'Cockpit map during a ride with two or more riders' },
  @{ file = '02_convoy_riders';    tip = 'Convoy screen with the riders list' },
  @{ file = '03_intercom';         tip = 'Intercom with the "Talk to" picker open' },
  @{ file = '04_stops_arrivals';   tip = 'Stops list showing who reached a stop' },
  @{ file = '05_trip_map';         tip = 'Trip report, Map tab with each rider''s coloured route' },
  @{ file = '06_trip_summary';     tip = 'Trip report, Summary with the rider cards' },
  @{ file = '07_timeline';         tip = 'Group timeline' },
  @{ file = '08_light_theme';      tip = 'Cockpit in the light theme (Account, Appearance, Light)' }
)

# Clean status bar (time 10:00, full battery, no notifications) while capturing.
& $adb shell settings put global sysui_demo_allowed 1 | Out-Null
& $adb shell am broadcast -a com.android.systemui.demo -e command enter | Out-Null
& $adb shell am broadcast -a com.android.systemui.demo -e command clock -e hhmm 1000 | Out-Null
& $adb shell am broadcast -a com.android.systemui.demo -e command battery -e level 100 -e plugged false | Out-Null
& $adb shell am broadcast -a com.android.systemui.demo -e command notifications -e visible false | Out-Null

try {
  foreach ($s in $shots) {
    Write-Host ''
    Write-Host ('Open: ' + $s.tip)
    $answer = Read-Host 'Press Enter to capture, s to skip, q to stop'
    if ($answer -eq 'q') { break }
    if ($answer -eq 's') { continue }
    $png = Join-Path $out ($s.file + '.png')
    # Saved on the phone first and pulled: piping binary through PowerShell would corrupt the PNG.
    & $adb shell screencap -p /sdcard/coroute_shot.png | Out-Null
    & $adb pull /sdcard/coroute_shot.png $png | Out-Null
    & $adb shell rm /sdcard/coroute_shot.png | Out-Null
    Write-Host ('Saved ' + $png)
  }
} finally {
  & $adb shell am broadcast -a com.android.systemui.demo -e command exit | Out-Null
}

Write-Host ''
Write-Host ('Screenshots are in ' + $out + '. Play accepts PNG or JPEG, 320 to 3840 px on each side, at most 2:1.')
