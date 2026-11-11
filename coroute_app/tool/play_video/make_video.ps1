# Builds coroute_background_location.mp4 from shot1..4.mp4 with captions. Needs ffmpeg in PATH.
$ErrorActionPreference = "Stop"
$cap = @("1. Open CoRoute and start a ride",
         "2. In-app notice before asking",
         "3. Choose Allow all the time",
         "4. Phone locked - tracking continues")
$dur = @(8, 12, 12, 23)
$font = "C\:/Windows/Fonts/arial.ttf"
Remove-Item list.txt -ErrorAction SilentlyContinue
for ($i = 0; $i -lt 4; $i++) {
  $n = $i + 1
  $vf = "scale='min(1080,iw)':-2,fps=30,drawbox=y=ih-150:w=iw:h=150:color=black@0.55:t=fill,drawtext=fontfile='$font':text='$($cap[$i])':fontcolor=white:fontsize=44:x=(w-text_w)/2:y=h-100"
  ffmpeg -y -loglevel error -i "shot$n.mp4" -t $dur[$i] -an -vf $vf -c:v libx264 -pix_fmt yuv420p -preset medium -crf 20 "part$n.mp4"
  Add-Content list.txt "file 'part$n.mp4'"
}
ffmpeg -y -loglevel error -f concat -safe 0 -i list.txt -c copy coroute_background_location.mp4
Remove-Item part*.mp4, list.txt
Write-Host "Done: coroute_background_location.mp4"
