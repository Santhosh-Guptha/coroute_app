# Records the 4 shots for the Play background-location video. Needs adb in PATH and one phone connected.
$ErrorActionPreference = "Stop"
$pkg = "space.devmonks.coroute_app"
adb devices
Write-Host "Resetting CoRoute location permissions so the dialogs appear again..."
adb shell pm revoke $pkg android.permission.ACCESS_BACKGROUND_LOCATION 2>$null
adb shell pm revoke $pkg android.permission.ACCESS_FINE_LOCATION 2>$null
adb shell pm revoke $pkg android.permission.ACCESS_COARSE_LOCATION 2>$null
adb shell settings put system show_touches 1
$shots = @(
  "Shot 1: open CoRoute from the home screen and tap Start ride",
  "Shot 2: the in-app 'Location in the background' disclosure, then tap Continue",
  "Shot 3: Android dialog 'While using the app', then settings 'Allow all the time', then back",
  "Shot 4: lock the phone (show the ride notification on the lock screen), wait, unlock to show the map moved"
)
for ($i = 1; $i -le 4; $i++) {
  Write-Host ""
  Write-Host $shots[$i-1]
  Read-Host "Press Enter to START recording shot $i"
  $p = Start-Process adb -ArgumentList "shell screenrecord --bit-rate 8000000 --time-limit 60 /sdcard/shot$i.mp4" -PassThru -NoNewWindow
  Read-Host "Press Enter to STOP shot $i"
  adb shell pkill -INT screenrecord
  Start-Sleep -Seconds 2
  adb pull /sdcard/shot$i.mp4 "shot$i.mp4"
  adb shell rm /sdcard/shot$i.mp4
}
adb shell settings put system show_touches 0
Write-Host "Done. Now run make_video.ps1"
