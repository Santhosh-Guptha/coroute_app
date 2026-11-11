#!/usr/bin/env bash
# Records the 4 shots for the Play background-location video. Needs adb and one phone connected.
set -e
PKG=space.devmonks.coroute_app
adb devices
adb shell pm revoke $PKG android.permission.ACCESS_BACKGROUND_LOCATION || true
adb shell pm revoke $PKG android.permission.ACCESS_FINE_LOCATION || true
adb shell pm revoke $PKG android.permission.ACCESS_COARSE_LOCATION || true
adb shell settings put system show_touches 1
SHOTS=("Shot 1: open CoRoute and tap Start ride"
       "Shot 2: in-app background-location disclosure, tap Continue"
       "Shot 3: Android dialog, then 'Allow all the time', then back"
       "Shot 4: lock the phone (ride notification), wait, unlock to show the map moved")
for i in 1 2 3 4; do
  echo; echo "${SHOTS[$((i-1))]}"
  read -rp "Enter to START shot $i"
  adb shell screenrecord --bit-rate 8000000 --time-limit 60 /sdcard/shot$i.mp4 &
  read -rp "Enter to STOP shot $i"
  adb shell pkill -INT screenrecord || true
  sleep 2
  adb pull /sdcard/shot$i.mp4 shot$i.mp4
  adb shell rm /sdcard/shot$i.mp4
done
adb shell settings put system show_touches 0
echo "Done. Now run ./make_video.sh"
