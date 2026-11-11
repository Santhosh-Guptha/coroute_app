#!/usr/bin/env bash
# Builds coroute_background_location.mp4 from shot1..4.mp4 with captions. Needs ffmpeg.
set -e
CAP=("1. Open CoRoute and start a ride"
     "2. In-app notice before asking"
     "3. Choose \"Allow all the time\""
     "4. Phone locked: tracking continues")
DUR=(8 12 12 23)   # seconds per shot, total 55
FONT=${FONT:-DejaVuSans}
rm -f list.txt
for i in 0 1 2 3; do
  n=$((i+1)); t=$(echo "${CAP[$i]}" | sed "s/'/\\\\'/g; s/:/\\\\:/g")
  ffmpeg -y -loglevel error -i shot$n.mp4 -t ${DUR[$i]} -an \
    -vf "scale='min(1080,iw)':-2,fps=30,drawbox=y=ih-150:w=iw:h=150:color=black@0.55:t=fill,drawtext=font=$FONT:text='$t':fontcolor=white:fontsize=44:x=(w-text_w)/2:y=h-100" \
    -c:v libx264 -pix_fmt yuv420p -preset medium -crf 20 part$n.mp4
  echo "file 'part$n.mp4'" >> list.txt
done
ffmpeg -y -loglevel error -f concat -safe 0 -i list.txt -c copy coroute_background_location.mp4
rm -f part*.mp4 list.txt
ffprobe -v error -show_entries format=duration -of csv=p=0 coroute_background_location.mp4 | xargs printf "Done: coroute_background_location.mp4 (%.0f s)\n"
