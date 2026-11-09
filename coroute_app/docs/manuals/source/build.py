"""Builds the CoRoute User manual and Investor manual as print HTML (rendered to PDF by pdf.js)."""
import os, sys
S = 'file:///home/claude/manual/shots/'
sys.path.insert(0, '/home/claude/manual/mock')
from bikeglyph import bike_svg  # real bike silhouettes (same data as the app)

CSS = """
@page { size: A4; margin: 0; }
* { box-sizing: border-box; }
body { margin: 0; font-family: Manrope, system-ui, sans-serif; color: #15232E; font-size: 10.5pt; line-height: 1.5; }
.page { width: 210mm; height: 297mm; padding: 18mm 18mm 16mm; position: relative; page-break-after: always; overflow: hidden; background: #fff; }
.page:last-child { page-break-after: auto; }
.foot { position: absolute; left: 18mm; right: 18mm; bottom: 9mm; display: flex; justify-content: space-between; font-size: 8pt; color: #5B6B78; font-weight: 600; }
h1 { font-size: 26pt; line-height: 1.1; margin: 0 0 4mm; letter-spacing: -.02em; font-weight: 800; }
h2 { font-size: 13pt; margin: 6mm 0 2mm; font-weight: 800; }
h3 { font-size: 11pt; margin: 4mm 0 1mm; font-weight: 800; }
p { margin: 0 0 3mm; }
.eyebrow { font-size: 8.5pt; font-weight: 800; letter-spacing: .14em; text-transform: uppercase; color: #0B6E78; margin-bottom: 2mm; }
.lead { font-size: 12pt; color: #3E4F5C; font-weight: 600; }
.muted { color: #5B6B78; }
ul { margin: 0 0 3mm; padding-left: 5mm; } li { margin: 0 0 1.2mm; }
.grid { display: flex; gap: 7mm; align-items: flex-start; }
.col { flex: 1; min-width: 0; }
.phones { display: flex; gap: 6mm; justify-content: center; align-items: flex-start; margin: 3mm 0; }
.ph { text-align: center; }
.ph img { width: 52mm; border-radius: 6mm; border: 1.4mm solid #15232E; box-shadow: 0 3mm 7mm rgba(21,35,46,.18); display: block; margin: 0 auto; background: #fff; }
.ph.s img { width: 44mm; border-width: 1.1mm; border-radius: 5mm; }
.ph.xs img { width: 38mm; border-width: 1mm; border-radius: 4.5mm; }
.ph.xxs img { width: 33mm; border-width: 1mm; border-radius: 4mm; }
.cap { font-size: 8pt; color: #5B6B78; font-weight: 700; margin-top: 2mm; max-width: 56mm; margin-left: auto; margin-right: auto; }
.tag { display: inline-block; white-space: nowrap; font-size: 6.5pt; font-weight: 800; letter-spacing: .08em; padding: .6mm 2mm; border-radius: 2mm; margin-bottom: 1mm; }
.t-real { background: #15232E; color: #fff; } .t-design { background: #E3F3F5; color: #084F57; } .t-ill { background: #084F57; color: #fff; } .t-con { background: #B4541C; color: #fff; }
.box { background: #F4F7F9; border: 1px solid #E1E9EE; border-radius: 4mm; padding: 4mm 5mm; margin: 3mm 0; }
.box.teal { background: #E3F3F5; border-color: #B7E3E8; } .box.warn { background: #FFF1E6; border-color: #F0C9B3; }
table { width: 100%; border-collapse: collapse; font-size: 9pt; margin: 2mm 0 3mm; }
th { text-align: left; font-size: 7.5pt; letter-spacing: .08em; text-transform: uppercase; color: #5B6B78; border-bottom: 2px solid #E1E9EE; padding: 1.5mm 2mm; }
td { border-bottom: 1px solid #E1E9EE; padding: 1.8mm 2mm; vertical-align: top; }
.kpis { display: flex; gap: 4mm; margin: 4mm 0; }
.kpi { flex: 1; background: #0B6E78; color: #fff; border-radius: 4mm; padding: 4mm; }
.kpi b { display: block; font-size: 19pt; line-height: 1.1; } .kpi span { font-size: 8.5pt; opacity: .9; font-weight: 600; }
.kpi.l { background: #F4F7F9; color: #15232E; border: 1px solid #E1E9EE; }
.cover { background: #0B1517; color: #fff; padding: 0; }
.cover img.hero { width: 100%; display: block; }
.cover .in { padding: 14mm 18mm; }
.cover h1 { font-size: 34pt; color: #fff; }
.cover .lead { color: #B7E3E8; }
.pill { display: inline-block; border: 1px solid #3A4A55; border-radius: 10mm; padding: 1.5mm 4mm; font-size: 9pt; font-weight: 700; margin: 0 2mm 2mm 0; color: #D6F0F3; }
.toc li { font-weight: 700; margin-bottom: 2mm; }
.num { display: inline-flex; width: 7mm; height: 7mm; border-radius: 3.5mm; background: #0B6E78; color: #fff; align-items: center; justify-content: center; font-weight: 800; font-size: 9pt; margin-right: 2mm; }
.steps li { list-style: none; margin-bottom: 2.5mm; } .steps { padding-left: 0; }
.src { font-size: 7.5pt; color: #5B6B78; }
"""

def phone(img, cap, tag='design', size=''):
    label = {'real': 'REAL APP SCREENSHOT', 'design': 'APP DESIGN SCREEN', 'ill': 'BUILT IN 3.55 · ILLUSTRATION', 'con': 'NEXT · CONCEPT', 'mock': 'MOCK-UP · BUILT IN 3.55'}[tag]
    if size in ('xs', 'xxs'): label = {'real': 'REAL SCREENSHOT', 'design': 'DESIGN SCREEN', 'ill': 'BUILT · ILLUSTRATION', 'con': 'NEXT · CONCEPT', 'mock': 'MOCK-UP · 3.55'}[tag]
    cls = 'ill' if tag == 'mock' else tag
    return f"<div class='ph {size}'><span class='tag t-{cls}'>{label}</span><img src='{S}{img}'><div class=cap>{cap}</div></div>"

_PN = {}
def page(body, n, title):
    # Page numbers are counted per manual (the cover is page 1), so inserted pages renumber the rest.
    n = _PN[title] = _PN.get(title, 1) + 1
    return f"<div class=page>{body}<div class=foot><span>CoRoute · {title}</span><span>{n}</span></div></div>"

def doc(pages, title):
    return f"<!doctype html><html><head><meta charset=utf-8><title>{title}</title><style>{CSS}</style></head><body>{''.join(pages)}</body></html>"

LEGEND = """<div class=box style='font-size:8.5pt'><b>About the pictures.</b> <span class='tag t-real'>REAL APP SCREENSHOT</span> taken from the app on an Android emulator.
<span class='tag t-design'>APP DESIGN SCREEN</span> the design the app is built to (sample names and numbers).
<span class='tag t-ill'>ILLUSTRATION · BUILT IN 3.55</span> drawn to show a feature that is built in version 3.55 (final screens may differ slightly).
<span class='tag t-ill'>MOCK-UP · BUILT IN 3.55</span> a mock-up of a 3.55 screen drawn from the app's code and wording; not a screenshot.
<span class='tag t-con'>CONCEPT · NEXT FEATURE</span> an idea for a future version; not built yet.</div>"""

# ------------------------------------------------------------------ USER MANUAL
U = 'Rider guide'
u = []
u.append(f"""<div class='page cover'><img class=hero src='{S}feature.png'><div class=in>
<div class=eyebrow style='color:#5CCAD3'>User manual · version 3.55 · November 2026</div>
<h1>CoRoute rider guide</h1><p class=lead>Ride together. Stay together. Everything a rider needs to plan a ride, ride safely alone or in a group, and come home.</p>
<div style='margin:6mm 0'><span class=pill>Free safety for every rider</span><span class=pill>Group map and intercom</span><span class=pill>Crash detection and SOS</span><span class=pill>Siren and horn alerts</span><span class=pill>Works with weak signal</span><span class=pill>Friends, crews and rider score</span><span class=pill>Made in India, for Indian roads</span></div>
<h2 style='color:#fff'>Inside</h2><ol class=toc style='color:#D6F0F3;columns:2;column-gap:10mm'><li>Getting started</li><li>Plan and start a ride</li><li>On the road</li><li>Sound, music and calls</li><li>Sirens and horns</li><li>Clear intercom and the lock screen</li><li>Changing settings during a ride</li><li>Riding as a group</li><li>Safety features</li><li>Fuel, places and reviews</li><li>Finishing a ride</li><li>Your profile and username</li><li>Friends</li><li>Crews and polls</li><li>Rider score and leaderboards</li><li>Your bike: details and shape</li><li>Riding pillion</li><li>Your plan, garage and settings</li><li>Privacy, offline use and help</li></ol></div></div>""")

u.append(page(f"""<div class=eyebrow>1 · Getting started</div><h1>Set up once, ride safer every time</h1>
<p class=lead>CoRoute is a free app for motorcycle riders. Every safety feature works for every rider, on every plan. Groups add live coordination: a shared map, talk, regroup and roles.</p>
<div class=grid><div class=col><ul class=steps>
<li><span class=num>1</span><b>Create your free account</b> with e-mail or Google. (Guest mode has been retired, so your rides, contacts and safety settings are always saved.)</li>
<li><span class=num>2</span><b>Add your emergency contact</b> and phone number. CoRoute texts this person if you crash or raise an SOS.</li>
<li><span class=num>3</span><b>Fill in your medical info</b> (blood group, allergies, notes for a doctor). It shows on your lock screen, and in an emergency it goes to the people helping you. There is no switch to set (chapter 9).</li>
<li><span class=num>4</span><b>Add your bike</b> in Garage: model, bike type, engine cc, colour, tank and mileage. These details are needed before you create or join a ride as a rider (chapter 16). They power fuel range and engine-rest advice, and your group sees your bike's shape and colour on the map.</li>
<li><span class=num>5</span><b>Allow location, notifications, motion and microphone</b> (the microphone is for the intercom and siren alerts). Run the <b>pre-ride phone check</b>: it tests GPS, sensors, SOS readiness and battery in under a minute.</li>
<li><span class=num>6</span><b>Mount your phone on the handlebar</b>. Crash detection works best on a mount; CoRoute tells you if it thinks the phone is in a pocket or tank bag.</li></ul></div>
<div class=col style='max-width:62mm'>{phone('d_01_Start_a_ride.png','Home: your next ride, quick actions and bike status')}</div></div>
{LEGEND}""", 2, U))

u.append(page(f"""<div class=eyebrow>2 · Plan and start a ride</div><h1>From idea to route in a minute</h1>
<div class=grid><div class=col>
<h3>Plan a route</h3><p>Tap <b>Plan a route</b>, give the trip a name, pick the destination on the map and add stops (fuel, food, a viewpoint). CoRoute shows distance, time and stops, and saves the map along the route automatically so navigation keeps working where signal drops.</p>
<h3>Ride solo or invite your group</h3><p>A Community (free) rider starts solo rides with every safety feature. To ride as a group, <b>one</b> member needs a group plan and hosts the ride; everyone else joins for free with the <b>invite code</b> or link and gets the host's group features for that ride.</p>
<h3>Join a ride</h3><p>Tap <b>Join with code</b> and enter the 6-character code the host shared.</p>
<h3>Before you go</h3><ul><li>Check the weather along the route shown in the trip review.</li><li>See where you will need fuel, from your bike's real range.</li><li>Set your guardian (a family member who can follow the ride live).</li></ul></div>
<div class=col><div class=phones>{phone('r_planner.png','Planning a ride (real app)', 'real','s')}{phone('d_07_Route.png','Route with stops, ETA and distance left','design','s')}</div></div></div>""", 3, U))

u.append(page(f"""<div class=eyebrow>3 · On the road</div><h1>A cockpit made for gloves and glances</h1>
<div class=phones>{phone('d_02_Navigation_while_riding.png','Navigation: next turn, speed and limit, your group on the map','design','s')}{phone('d_03_Orbit_quick_access.png','Orbit: one tap to Intercom, Group, Fuel, Route, Guardian and SOS','design','s')}{phone('d_04_Intercom.png','Intercom: hold to talk to the whole group or to the leads','design','s')}</div>
<div class=grid><div class=col><h3>What you see</h3><ul><li>Big turn arrows and spoken directions; re-routing when you leave the route.</li><li>Your speed and the road's limit; a warning before sharp bends.</li><li>Every rider of your group live on the map.</li></ul></div>
<div class=col><h3>What you hear</h3><ul><li>Turn-by-turn voice, road hazard warnings and group alerts, all short and clear.</li><li>Push-to-talk intercom over your helmet headset. The microphone is only on while you hold the button (or in hands-free mode you choose).</li><li>Music from other apps gets quieter for a CoRoute alert and comes back right after; emergencies pause it (chapter 4).</li></ul></div></div>""", 4, U))

u.append(page(f"""<div class=eyebrow>3 · On the road (continued)</div><h1>Eyes on the road: speak now, tap later</h1>
<div class=grid><div class=col>
<h3>Cards that wait until you stop</h3><p>Some cards need a decision but are not urgent: <b>off the group's route</b>, a <b>bike or pillion swap</b> request, a <b>historic place</b> ahead and a <b>place review</b>. While you ride, CoRoute says one short line, once, and shows a small chip with nothing to tap, for example “Off the group's route · Stop to choose”.</p>
<p>When you stop (3 km/h or less for 5 seconds) the full card comes back with its buttons. A pillion can tap at any time.</p>
<div class='box teal'><b>Safety alerts never wait.</b> SOS, the crash alarm, “Bike down?”, sirens and the missing-rider check always show in full, moving or not.</div>
<div class='box' style='margin-top:4mm'><h3 style='margin-top:0'>Why my speed differs from the speedometer</h3><p>Bike speedometers are made to read <b>high</b>. The law allows them to show up to 10% + 4 km/h more than your real speed, never less. So when your speedometer says 86, you are really doing about 79–80, and that is what CoRoute shows, from GPS.</p><p style='margin:0'>Speed warnings use your real speed, so CoRoute warns you at the right moment. Expect CoRoute to read a few km/h below your bike.</p></div></div>
<div class=col style='max-width:62mm'>{phone('m_i18_movingchip.png','While moving: one spoken line and a chip; the buttons come back when you stop','mock','s')}</div></div>""", 0, U))

u.append(page(f"""<div class=eyebrow>4 · Sound, music and calls</div><h1>Hear what matters, keep your music</h1>
<div class=grid><div class=col>
<h3>What you hear</h3><ul><li><b>Everyday lines</b> (turns, road warnings, group news, fuel) make your music quieter, then it comes back about a second later. Prefer silence? Turn on <b>Pause music during alerts</b>.</li>
<li><b>Emergencies</b> (SOS, crash countdown, “Bike down?”, a siren close by, “Are you OK?”, riding far over the limit) <b>pause</b> your music. With earphones or a helmet set they play <b>in your ears</b>, louder for the line, and not on the phone speaker. Without earphones they use the phone's <b>alarm sound</b>, heard even at media volume zero and in Do Not Disturb once you allow CoRoute there.</li></ul>
<h3>Lower music when speeding</h3><p>On by default (Settings › Voice &amp; sound). It is a gentle nudge, not a punishment:</p>
<table><tr><th>You ride</th><th>Your music</th></tr><tr><td>10% over the limit</td><td>quieter (60%)</td></tr><tr><td>25% over</td><td>much quieter (30%)</td></tr><tr><td>40% over</td><td>paused, and you hear “Slow down”</td></tr><tr><td>Back under for 5 s</td><td>back to your volume</td></tr></table>
<p class=muted>Change the volume yourself and CoRoute leaves it alone. It never lowers CoRoute alerts or the intercom.</p></div>
<div class=col style='max-width:62mm'>{phone('m_i17_voicesound.png','Settings › Voice &amp; sound: music, siren, horn and voice options','mock','s')}</div></div>
<h3>During a phone call</h3><div class=grid><div class=col><ul><li><b>Ringing or talking:</b> everyday lines wait, so nothing talks over your call.</li><li><b>Emergencies still get through:</b> a short tone and a few words in your call audio (the caller does not hear them), a buzz and a notification.</li></ul></div>
<div class=col><ul><li><b>After the call</b> you hear a short catch-up: “Safety alert during your call: …”, then “While you were on the call: 2 road warnings, Asha fell behind.”</li><li>Hands-free intercom talk comes back by itself after the call.</li></ul></div></div>""", 0, U))

u.append(page(f"""<div class=eyebrow>5 · Sirens and horns</div><h1>An extra pair of ears on the road</h1>
<p class=lead>Made for riders who can't hear outside: noise-cancelling earbuds, a helmet set, music. Your phone's own microphone still hears the road and tells you about the ambulance you would miss.</p>
<div class=phones>{phone('m_i15_siren.png','Siren card: in your ears with earbuds or music','mock','xxs')}{phone('m_i16_horn.png','Horn card: check your mirrors','mock','xxs')}{phone('m_i17_voicesound.png','Settings › Voice &amp; sound (no group card)','mock','xxs')}</div>
<div class=grid><div class=col><h3>Sirens</h3><ul><li>Wail, yelp and hi-lo sirens, including Indian ambulance hi-lo.</li><li><b>Earbuds, helmet set or music:</b> music pauses and you hear in your ears “Emergency vehicle siren close by. Keep left and give way.”, plus a vibration, the card and a lock-screen heads-up. Noise cancelling does not block it.</li><li><b>Phone speaker, no music:</b> a short tone, a vibration and the card (you can hear the siren).</li><li>Far away: “siren in the distance”. The card adds <b>Approaching</b> or <b>Moving away</b>.</li><li>Only you are alerted, not your group. <b>Give way to the</b>: left or right (Automatic follows your country).</li></ul></div>
<div class=col><h3>Horns</h3><ul><li>Two close horns, or one long very close horn: “Horn close by. Check your mirrors.”</li><li><b>Horn alerts</b>: <b>Automatic</b> (only when earbuds, a helmet set, music or a call may stop you hearing traffic), On or Off. Your own horn is ignored.</li></ul>
<div class='box teal' style='margin-top:2mm'><b>Where to keep the phone.</b> CoRoute listens with the phone's own microphone, never the earbud or helmet mic. Best on a handlebar mount or in a tank bag; in a jacket pocket at speed, wind can hide a siren.</div></div></div>
<div class='box warn' style='margin-top:1mm'><b>Good to know.</b> One microphone cannot tell direction, so CoRoute says “close by”, never “behind”: use your mirrors. <b>Privacy:</b> checked on your phone during rides only; nothing is recorded or sent.</div>""", 0, U))

u.append(page(f"""<div class=eyebrow>6 · Clear intercom and the lock screen</div><h1>Your voice, without the wind</h1>
<div class=grid><div class=col>
<h3>Clean up my voice</h3><p>On by default. Before your voice reaches the group, CoRoute takes out wind rumble and engine drone, background noise and breathing, and keeps your level steady so a whisper is heard and a shout does not blast. It adds about 12 milliseconds, which you will not notice.</p>
<h3>Hands-free tips</h3><ul><li>Hands-free sends only when you speak. Breathing, wind and hiss do <b>not</b> open the mic, so the group hears silence, not your breath.</li><li>Start speaking normally; the first word is kept.</li><li><b>With a helmet set:</b> push-to-talk uses the helmet mic while you hold the button; hands-free uses the phone's microphone (cleaned up), so siren alerts keep working. For the clearest voice, use push-to-talk.</li><li>Very heavy gusts may still cut a syllable.</li><li>A phone call pauses talk; hands-free returns after the call.</li><li>One very loud rider is evened out for everyone else.</li></ul>
<h3>On the lock screen</h3><ul><li>The ride notification shows your speed, the limit, the next warning and the intercom: <b>Talking</b>, <b>Receiving Asha</b>, <b>Hands-free on</b>, <b>Group voice muted</b> or <b>Voice paused (call)</b>.</li><li><b>Talk</b> turns hands-free talk on or off; <b>Mute</b> stops hearing the group. No unlocking needed.</li><li>Another rider's SOS appears over the lock screen with an alarm sound.</li></ul></div>
<div class=col style='max-width:62mm'>{phone('m_i14_lockscreen.png','Lock screen: ride line with SOS, Talk, Mute and Leave','mock','s')}</div></div>""", 0, U))

u.append(page(f"""<div class=eyebrow>7 · Changing settings during a ride</div><h1>Change it now, it works now</h1>
<p class=lead>You never need to stop or restart a ride for a setting. Every change applies straight away, for you and, for group settings, for everyone.</p>
<div class=grid><div class=col>
<h3>Speed limit: the stricter one wins</h3><p>Your own speed warning and the group's limit are compared, and the <b>lower</b> one warns you. Lower it mid-ride and the next warning uses it; the cockpit and the lock screen show the same number. Near towns and planned stops the group's lower town limit applies on your phone too.</p>
<h3>Your settings</h3><ul><li>Voice off silences waiting lines at once (emergencies are always spoken).</li><li>Break reminder, solo check-in, data saver and battery saver follow the switch immediately.</li><li>Quick settings show the real state after every tap.</li><li>Change bike in Garage and your group sees the new colour within seconds.</li></ul></div>
<div class=col><h3>Group settings (trip owner, trip head or lead)</h3><ul><li>Distance and stop sliders send when you lift your finger, once.</li><li>No signal? The app says the change was not sent, instead of losing it.</li><li>Spoken alerts off stops queued group lines too.</li></ul>
<h3>Crash detection switched off in a countdown?</h3><div class='box warn'>The running alarm carries on (you might be hurt, or the switch was bumped). The screen says: “Crash detection is off for new alarms. This alarm is still running: tap I'm OK to cancel it.” New alarms stop at once.</div>
{phone('m_i03_groupsettings.png','Group settings: changes reach every rider at once','ill','xs')}</div></div>""", 0, U))

u.append(page(f"""<div class=eyebrow>8 · Riding as a group</div><h1>Lead, middle, sweeper: everyone knows their place</h1>
<div class=phones>{phone('d_05_Group_riders.png','Group: spread, riding order, fuel of each rider','design','xs')}{phone('m_i01_roles.png','Set a rider’s role; they are told to move to the front or back','ill','xs')}{phone('m_i11_missing.png','Missing-rider check: I&#39;m OK, Need help, or hold Send SOS','mock','xs')}{phone('m_i07_offroute.png','Missed a turn? Route back to the group (when stopped)','ill','xs')}</div>
<div class='box' style='font-size:9pt;padding:3mm 4mm;margin:1mm 0 2mm'><b>Who is who.</b> <b>Trip owner</b>: created the group or trip. <b>Trip head</b>: can change this trip's settings only; only the trip owner removes riders or ends the trip, and choosing a trip head does not make them Lead. <b>Lead</b>: rides first and guides the group; <b>Middle</b> rides between and the <b>Sweeper</b> rides last. Riding roles are positions, not management rights.</div>
<div class=grid><div class=col><ul>
<li><b>Riding roles.</b> The trip owner or the lead sets any rider as Lead (front), Middle or Sweeper (back), or swaps two riders. The rider hears “You are now the sweeper. When it is safe, drop back to the end of the group.”</li>
<li><b>Automatic roles</b> (off by default): the rider at the front leads and the last rider sweeps, with no flickering in a tight pack. An automatic lead only guides; running the trip stays with the trip owner.</li>
<li><b>Stretch alert.</b> The lead hears “Group spread 3 km, slow down” and gets a suggested regroup stop ahead (fuel, dhaba, rest area).</li></ul></div>
<div class=col><ul>
<li><b>Missing-rider check.</b> If you stop while the group moves on, your phone asks “Are you OK?”. <b>Need help</b> asks the group to wait. For an emergency, hold the red <b>Send SOS</b> for 1.5 s: it sends a real SOS. No answer in 90 s and the lead is told. Riding as a pair? If you or your pillion answers, it counts for both.</li>
<li><b>Route to group.</b> Leave the group's route and you can route back to them, ask the group to wait, or continue your way.</li>
<li><b>Buddy pairs</b> for groups of 7 or more, a <b>group break planner</b> when several riders are tired (only a level is shared, never names), and a <b>roll call</b> at the start and at arrival.</li>
<li><b>Swap bikes</b> or change places (rider and pillion) mid-ride; the other rider accepts first (when stopped, chapter 3). Riding pillion from the start: chapter 17.</li></ul></div></div>""", 5, U))

u.append(page(f"""<div class=eyebrow>9 · Safety features (free for every rider)</div><h1>Help comes even when you can't ask for it</h1>
<div class=phones>{phone('d_09_Emergency_SOS.png','SOS: a countdown, then your group, contact and helpline are alerted','design','xs')}{phone('m_i12_bikedown.png','“Bike down?” when your bike falls while stopped','ill','xs')}{phone('d_08_Guardian.png','Guardian: family follows your ride and is alerted','design','xs')}{phone('m_i02_hazard.png','Potholes and speed breakers felt by the lead warn everyone behind','ill','xs')}</div>
<table><tr><th>Feature</th><th>What it does for you</th></tr>
<tr><td><b>Crash detection</b></td><td>Senses a fall or impact. A 15-second alarm lets you cancel; otherwise your group, emergency contact and helpline are alerted with your location. It learns from your “I'm OK” answers on your bike, but never ignores a severe impact.</td></tr>
<tr><td><b>SOS</b></td><td>Hold the SOS button (or Send SOS on the missing-rider card). Delivered to your group; if there is no data, it goes by SMS and is resent until delivered.</td></tr>
<tr><td><b>Medical info</b></td><td>Always on your lock screen. During your SOS or crash alert it goes to the people helping you: your group, your guardian and a rider who accepts to help (with your emergency contact). Nothing to switch on; it is not shared once the alert is closed.</td></tr>
<tr><td><b>Guardian and arrival</b></td><td>A family member follows your ride live. When you arrive they get “Arrived safely” and the link stops.</td></tr>
<tr><td><b>Solo check-in</b></td><td>On a solo ride, if you have not arrived by your expected time plus a margin, CoRoute asks if you are OK, then texts your contact.</td></tr>
<tr><td><b>Road warnings</b></td><td>Potholes, speed breakers and rough road felt by the rider at the front; sharp-bend warnings; speed limits (stricter near schools and hospitals); stretches where many riders brake hard.</td></tr>
<tr><td><b>Care on long rides</b></td><td>Break reminders that adapt to how you ride, earlier breaks after sunset, high-altitude reminders above 3,000 m, engine-rest advice for your bike, an SOS battery reserve below 10%.</td></tr>
<tr><td><b>Nearby riders can help</b></td><td>With your permission, riders of other groups and public rides near you are asked to help in an emergency.</td></tr></table>""", 6, U))

u.append(page(f"""<div class=eyebrow>10 · Fuel, places and reviews</div><h1>Never run dry, never miss the good stops</h1>
<div class=phones>{phone('d_06_Fuel.png','Fuel: your real range and stations ahead for your fuel type','design','xs')}{phone('m_i06_heritage.png','Historic places on your way','ill','xs')}{phone('m_i04_review.png','After a stop, a polite request to rate it','ill','xs')}{phone('m_i05_placecard.png','CoRoute rider reviews with photos and ratings','ill','xs')}</div>
<div class=grid><div class=col><h3>Fuel</h3><ul><li>Usable range from your bike's tank and mileage, updated as you ride.</li><li>Warnings before long stretches without fuel; one tap routes you to the next station that sells your fuel. Your group's plan does not change.</li><li>Stations marked by fuel type (petrol, diesel, CNG, EV).</li></ul></div>
<div class=col><h3>Places</h3><ul><li>Hospitals, mechanics, police, food, stays, toilets, ATMs and viewpoints on the map, with medium-size icons you can read at a glance.</li><li><b>Historic places</b>: forts, temples, monuments and museums near your route, with a gentle “worth a stop?” card.</li><li><b>Rider reviews</b>: after you spend a while at a place, CoRoute asks (only when you are stopped) for a quick star rating, a note and a photo, to help the riders coming after you. Missed it? After the ride you can rate up to 2 places you stopped at.</li></ul></div></div>""", 7, U))

u.append(page(f"""<div class=eyebrow>11 · Finishing a ride</div><h1>Every ride becomes a story you keep</h1>
<div class=phones>{phone('d_10_Stop_or_pause_ride.png','Stopping: tell the group why, so nobody worries','design','xs')}{phone('d_12_Ride_summary.png','Ride complete: distance, time, speed, fuel','design','xs')}{phone('m_i10_summary.png','A private safety summary, only for you','ill','xs')}{phone('d_13_Trips.png','Trips: upcoming and past rides, replay and GPX','design','xs')}</div>
<ul><li><b>Stopping:</b> quick break (the group pauses with you), “I'll catch up”, or end my ride.</li><li><b>Trip report:</b> the route of every rider on one map, replay, share card and GPX export.</li><li><b>Safety summary:</b> hard brakes, minutes over the limit, km after dark, breaks and tiredness. It stays on your phone.</li><li><b>Rate the trip</b> and, with your permission, share your story on the CoRoute website.</li></ul>""", 8, U))

u.append(page(f"""<div class=eyebrow>12 · Your profile and username</div><h1>Your name on the road, your numbers</h1>
<div class=grid><div class=col>
<p class=lead>Open <b>Profile › My profile &amp; friends</b>. This is what other riders see of you, plus the story of your riding so far.</p>
<h3>Your username</h3><ul><li>Every rider gets a <b>unique username</b> automatically, for example <b>SwiftFalcon482</b>. It never uses your real name.</li>
<li>Other riders, your crews and the leaderboards know you by it. Your ride group sees it on your rider card as <b>@SwiftFalcon482</b>.</li>
<li>Want your own? Tap <b>Change username</b>. CoRoute checks it as you type (<b>Available</b>). You can change it <b>once every 30 days</b>; changing only capital letters is always possible.</li>
<li>3 to 20 letters, digits or _ , starting with a letter. No real name, phone number or e-mail: it is shown publicly. Names like “admin” or “coroute” and rude words are refused.</li></ul>
<h3>Profile picture</h3><p><b>Take a photo</b> or <b>Choose from photos</b> (JPEG, PNG or WebP). CoRoute makes it smaller and removes location data before it leaves your phone. No picture? Your initials show instead. <b>Remove picture</b> any time.</p>
<h3>Ride analytics</h3><p>Trips, distance, riding hours, longest trip, largest group, your rider score (chapter 15), bikes in your garage and member since. A group ride counts once, from the trip report.</p>
<div class='box teal'><b>Your full name</b> is only on your own profile. Friends see your first name; everyone else sees only your username and picture.</div></div>
<div class=col style='max-width:58mm'>{phone('m_s01_profile.png','My profile: picture, username, ride analytics, friends, crews and the leaderboard switch','mock','s')}</div></div>""", 0, U))

u.append(page(f"""<div class=eyebrow>13 · Friends</div><h1>Ride with people you know</h1>
<div class=grid><div class=col>
<h3>Add a friend</h3><ul class=steps>
<li><span class=num>1</span><b>By username:</b> Friends › <b>Add a friend</b>, type their username, <b>Send request</b>.</li>
<li><span class=num>2</span><b>By invite link:</b> tap <b>Invite friends to CoRoute</b> and share the link (“Ride with me on CoRoute”) on WhatsApp or anywhere. It opens CoRoute and sends you a request; a new rider gets the request after signing up.</li>
<li><span class=num>3</span><b>Both must agree.</b> They see <b>Wants to be friends</b> with <b>Accept</b> and <b>Decline</b>. Until then your request waits under <b>Sent</b>, and you can cancel it.</li></ul>
<p>A red number on <b>My profile &amp; friends</b> shows new requests. When CoRoute is closed, a request arrives as a phone notification (chapter 14); during a ride it is a quiet notification, never a ride alert.</p>
<h3>What friends see</h3>
<table><tr><th>Who</th><th>Sees</th></tr>
<tr><td>Any rider</td><td>Your username and picture</td></tr>
<tr><td>Friends</td><td>Also your first name and ride totals: trips, km, hours, rider score</td></tr>
<tr><td>Nobody</td><td>Your phone, e-mail, medical info, emergency contacts, home or any location, plan or payments</td></tr></table>
<h3>Remove or block</h3><p>Tap <b>⋯</b> next to a friend: <b>Remove friend</b> (you can add each other again later) or <b>Block</b>. A blocked rider cannot send you requests or see your profile, and is <b>not told</b>. Unblock any time under <b>Blocked</b>.</p>
<p class=muted>Limits keep it friendly: up to 20 requests a day and 500 friends.</p></div>
<div class=col style='max-width:58mm'>{phone('m_s02_friends.png','Friends: a new request with Accept and Decline, a sent request, your friends','mock','s')}</div></div>""", 0, U))

u.append(page(f"""<div class=eyebrow>14 · Crews and polls</div><h1>Your riding crew, without the chat noise</h1>
<div class=grid><div class=col>
<p class=lead>A <b>crew</b> is your standing circle of riding friends, like “Sunday Riders”. Crews plan rides with <b>polls</b>. There is no chat: the only thing anyone posts is a vote.</p>
<h3>Create a crew and invite friends</h3><ul><li>Profile › My profile › <b>Crews</b> › <b>Create a crew</b>. You are the <b>crew admin</b>.</li>
<li><b>Invite friends</b>: you can invite your <b>friends only</b> (chapter 13), never strangers, phone numbers or e-mails. They join only when they tap <b>Join crew</b>; an invitation lasts 14 days.</li>
<li>Up to 100 riders per crew. Members see each other's username, first name and picture, nothing else.</li></ul>
<h3>Who can do what</h3>
<table><tr><th></th><th>Crew admin</th><th>Co-admin (up to 3)</th><th>Member</th></tr>
<tr><td>Invite friends</td><td>yes</td><td>yes</td><td>no</td></tr>
<tr><td>Start a poll</td><td>yes</td><td>yes</td><td>if the crew allows it</td></tr>
<tr><td>Close or delete a poll</td><td>yes</td><td>yes</td><td>their own polls</td></tr>
<tr><td>Remove riders, roles, settings, delete crew</td><td>yes</td><td>no</td><td>no</td></tr></table>
<h3>Polls</h3><ul><li><b>New poll</b>: a question with 2 to 6 options, <b>One answer</b> or <b>Multiple answers</b>, closing in 10 minutes to 30 days (3 days by default). <b>Use “Ride date” template</b> fills “When shall we ride?” with the next weekend days.</li>
<li>Tap an option to vote; change or remove your vote until the poll closes. Bars update live. Votes are named in the crew unless the poll has <b>Anonymous votes</b>.</li>
<li>Leaving as crew admin? Hand over to a member, or the oldest co-admin takes over.</li></ul></div>
<div class=col style='max-width:58mm'>{phone('m_s03_crew_poll.png','A crew with a live poll, a closed poll and the riders with their roles','mock','s')}</div></div>""", 0, U))

u.append(page(f"""<div class=eyebrow>14 · Crews and polls (continued)</div><h1>Start a ride with your crew</h1>
<p class=lead>The poll picked the day. Now one tap invites the crew to the ride, and each rider joins with <b>Accept</b>. Nobody needs the join code.</p>
<div class=phones style='margin:2mm 0'>{phone('m_s11_crew_ride_pick.png','You pick the riders to invite; their status shows as they answer','mock','s')}{phone('m_s10_ride_invite.png','Your friend gets a notification and this invitation screen','mock','s')}</div>
<div class=grid><div class=col><h3>Invite your crew</h3><ul class=steps>
<li><span class=num>1</span>On the crew screen tap <b>Start a ride</b>. Plan and start the ride as usual; then the list of crew members opens. Already riding? The button reads <b>Invite crew to my ride</b>.</li>
<li><span class=num>2</span>Tick riders, or <b>Select all</b>, and tap <b>Invite 3 riders</b>. Each one shows <b>Waiting</b>, <b>Joined</b>, <b>Declined</b> or <b>Expired</b>, and you get a message when someone answers.</li>
<li><span class=num>3</span>Seats follow your plan: a Community plan rides solo, so get a group plan to invite (chapter 18). A full ride says “no seat left”.</li></ul>
<p class=muted>Only the trip owner of the ride can invite. Invitations end after 12 hours or when the ride ends.</p></div>
<div class=col><h3>When you are invited</h3><ul>
<li>A <b>Ride invitation</b> notification arrives, even when CoRoute is closed: “SwiftFalcon482 invited you to Nandi Hills sunrise with Sunday Riders.”</li>
<li>Tap it: the invitation shows who invited you, the crew, the ride, where it goes and how many riders are in. Tap <b>Accept</b> or <b>Decline</b>.</li>
<li><b>Accept</b> joins like any ride: your bike details if they are missing (or “I'm riding pillion”), then the pre-ride check.</li></ul>
<div class='box teal' style='font-size:9pt'><b>Notifications when CoRoute is closed.</b> Friend requests, crew invites, new polls and ride invitations reach your phone as notifications. They name riders by username only, never your location, and hide the text on the lock screen. Turn them off in Settings › Account &amp; privacy › <b>Push notifications</b>.</div></div></div>""", 0, U))

u.append(page(f"""<div class=eyebrow>15 · Rider score and leaderboards</div><h1>A score for safe riding, never for speed</h1>
<div class=phones>{phone('m_s04_score.png','Your rider score: level, the four parts and tips','mock','xs')}{phone('m_s05_leaderboard.png','Leaderboard: usernames only, with your own place','mock','xs')}</div>
<div class=grid><div class=col><h3>How it is worked out</h3>
<table><tr><th>Part</th><th>Weight</th><th>What counts</th></tr>
<tr><td><b>Speed discipline</b></td><td>40%</td><td>Time over the speed limit, and how far over. Under the limit, faster never adds a point.</td></tr>
<tr><td><b>Smoothness</b></td><td>25%</td><td>Hard brakes per 100 km</td></tr>
<tr><td><b>Safety habits</b></td><td>25%</td><td>A break at least every 2–2.5 h on long rides; staying with your group</td></tr>
<tr><td><b>Regular riding</b></td><td>10%</td><td>Riding most fortnights</td></tr></table>
<p>Score 0–100 after <b>3 rides of 10 km or more</b>. Levels: <b>Learner</b> (under 50), <b>Steady</b> (50–69), <b>Skilled</b> (70–84), <b>Ace Rider</b> (85+). Recent rides count most, so improvement shows within weeks.</p></div>
<div class=col><div class='box teal' style='margin-top:4mm'><b>Never held against you:</b> SOS, crash alarms, “Bike down?”, hard stops, losing signal and riding at night. Speed is never rewarded.</div>
<h3>Tips to raise it</h3><ul><li>Keep within the limit on highways, even when the road is empty.</li><li>Leave more gap ahead so you brake gently.</li><li>Take a 10-minute break every 2 hours.</li><li>Stay with your group; one separation in traffic is free.</li></ul>
<h3>Private, and your choice</h3><ul><li>Only you see your score. <b>Use my ride safety report for my rider score</b> sends counts only (no route); turn it off and they are deleted.</li>
<li><b>Leaderboards</b> (Trips › Leaderboard, and the website): top score, longest ride, most km, hours and rides, by username. To leave, turn off <b>Show my username on public leaderboards</b> in My profile.</li></ul></div></div>""", 0, U))

BT = [('commuter','Commuter','Splendor, Shine, Platina'),('scooter','Scooter','Activa, Jupiter, Access'),('sport','Sport','R15, Duke, Apache RTR'),('cruiser','Cruiser','Meteor, Avenger, X440'),('adventure','Adventure / Tourer','Himalayan, Xpulse 200T, Scram'),('offroad','Off-road / Dirt','Xpulse, CRF'),('electric','Electric','Ather, Ola, Chetak, iQube'),('retro','Cafe racer / Retro','Classic 350, Interceptor, Hunter')]
_types = ''.join(f"<div style='text-align:center;width:22mm'>{bike_svg(k, '#D32F2F', 70)}<div style='font-size:7.5pt;font-weight:800;line-height:1.15'>{n}</div><div class=src style='line-height:1.2'>{e}</div></div>" for k, n, e in BT)
u.append(page(f"""<div class=eyebrow>16 · Your bike: details and shape</div><h1>Your group sees your bike, not a dot</h1>
<div class=grid><div class=col>
<h3>Bike details are needed before you ride</h3><p>To <b>create or join a ride as a rider</b>, your bike needs its details. If something is missing, <b>Complete your bike</b> opens right there, already filled in from your model: check it and tap <b>Save and continue</b>.</p>
<table><tr><th>Detail</th><th>Petrol, diesel, CNG</th><th>Electric</th></tr>
<tr><td>Make and model, bike type, colour</td><td>needed</td><td>needed</td></tr>
<tr><td>Engine size</td><td>50–2500 cc</td><td>not asked</td></tr>
<tr><td>Tank</td><td>2–40 L</td><td>battery kWh (optional)</td></tr>
<tr><td>Mileage</td><td>5–120 km/L</td><td>2–25 km/kWh</td></tr></table>
<div class='box teal'><b>Never in your way in an emergency.</b> SOS always works, the sheet never appears mid-ride, and closing it only cancels that create or join. No bike? Tap <b>I'm riding pillion (no bike)</b> (chapter 17).</div>
</div>
<div class=col style='max-width:84mm'><div class=phones style='gap:4mm;margin-top:0'>{phone('m_s09_completebike.png','Complete your bike: type picker with each shape','mock','xs')}{phone('m_s06_bikemap.png','Ride map: bike shapes and colours, one with a pillion','mock','xs')}</div><h3>On the map</h3><p>Every bike is one marker: its <b>shape</b> (bike type) in its <b>colour</b>, facing the way it travels. The ring shows the rider's colour while moving, <b>amber</b> when stopped, <b>red</b> for SOS; a teal glow is you; <b>L</b> and <b>S</b> mark the lead and sweeper. A bike with two people has a pillion seated.</p></div></div>
<h3 style='margin-top:2mm'>Bike types</h3><p class=muted style='margin-bottom:1mm'>CoRoute guesses the type from your model; you confirm it in Garage. The same shapes show in your garage and on the map.</p>
<div style='display:flex;justify-content:space-between'>{_types}</div>""", 0, U))

u.append(page(f"""<div class=eyebrow>17 · Riding pillion</div><h1>Two people, one bike, both protected</h1>
<div class=phones>{phone('m_s07_pillion.png','The pillion picks the bike and confirms','mock','s')}{phone('m_s08_pillion_rider.png','The rider is told and can decline for a minute','mock','s')}{phone('m_s06_bikemap.png','The group sees one bike with two people','mock','s')}</div>
<div class=grid><div class=col><h3>If you sit pillion</h3><ul class=steps>
<li><span class=num>1</span>Join the ride with the code and tap <b>I'm riding pillion (no bike)</b>.</li>
<li><span class=num>2</span><b>Whose bike are you on?</b> Pick your rider's bike. A bike that already has a pillion cannot be picked.</li>
<li><span class=num>3</span>Check “You'll ride pillion on Asha's Royal Enfield Classic 350 (Red). Confirm?” and tap <b>Confirm</b>.</li></ul>
<p>Your phone keeps <b>every safety feature</b>: crash detection, SOS and fall checks work exactly as on your own bike. Keep it with you.</p></div>
<div class=col><h3>If someone sits on your bike</h3><ul>
<li>Everyone hears and sees “<b>Kiran is riding pillion with Asha</b>.”</li>
<li>You get “Kiran is riding pillion with you”. Not right? Tap <b>Decline</b> within 60 seconds (while riding it waits as a chip until you stop). Later, use <b>Remove pillion</b> on their rider card.</li>
<li>Declined, removed, or the rider left the ride? The pillion is asked “Pick the bike you ride on.”</li></ul>
<div class='box' style='font-size:9pt'><b>Group safety counts the bike once</b>: the missing-rider check, group spread and break planner see one bike, not two riders. If the rider's phone loses signal, the pillion's phone keeps the bike on the map. When the bike stops and the app asks “Are you OK?”, <b>one answer counts for both</b>: whoever answers first, on either phone, closes the question on both.</div></div></div>""", 0, U))

u.append(page(f"""<div class=eyebrow>18 · Your plan, garage and settings</div><h1>Your details, your garage, your plan</h1>
<div class=phones>{phone('d_15_Profile.png','Account: emergency contacts and medical info','design','xs')}{phone('m_i08_garage.png','Garage: engine cc, colour, cooling, tank, mileage (bike type: chapter 16)','ill','xs')}{phone('d_11_More_and_settings.png','Settings: intercom, guardian, speed warnings and more','design','xs')}</div>
<table><tr><th>Plan</th><th>Price*</th><th>What you get</th></tr>
<tr><td><b>Community</b></td><td>Free</td><td>Solo rides with every safety feature; join anyone's group ride for free.</td></tr>
<tr><td><b>Small Group (2–6)</b></td><td>₹49 / month</td><td>Host group rides for up to 6 riders: live group map, intercom, regroup, roles, group alerts.</td></tr>
<tr><td><b>Large Group (7–12)</b></td><td>₹99 / month</td><td>Everything in Small Group for up to 12 riders, plus buddy pairs.</td></tr></table>
<div class='box teal'><b>One plan per group ride.</b> Only the host needs a plan. Everyone who joins with the code rides free and gets the host's group features for that ride.</div>
<p class=muted><b>Medical info</b> in your profile: “Shown to responders in an emergency and on your lock screen.”</p>
<p class=src>*Default prices in the app's plan catalogue; CoRoute may change them. Safety features are never locked behind a plan.</p>""", 9, U))

u.append(page(f"""<div class=eyebrow>19 · Privacy, offline use and help</div><h1>Built to protect you, and your data</h1>
<div class=grid><div class=col><h3>Privacy</h3><ul><li>Your location is shared only with your group while you ride, and with your guardian if you set one.</li><li>The microphone is used only for the intercom while you talk, and for siren and horn alerts during rides (the phone's own microphone); sound is checked on the phone and never recorded or sent.</li><li>Medical info leaves your phone only during your emergency, to the people helping you.</li><li>Phones share levels and events, never raw sensor data. Road reports and hard-brake spots are stored without names.</li><li>Other riders see your <b>username</b> and picture; friends also see your first name and ride totals. Never your phone, e-mail, medical info or location. Leaderboards show usernames and rounded totals only; you can leave them (chapter 15).</li><li>Website numbers are totals only, rounded down, shown only once 10 or more rides are behind a number.</li><li>No ads, no selling of data. Delete your account any time: rides, reviews and plans go with it.</li></ul>
<h3>When there is no internet</h3><ul><li><b>Still works:</b> navigation on the saved route, crash detection, the crash alarm, Medical ID, fuel range and warnings, bend and break reminders.</li><li><b>SOS:</b> sent by SMS when there is mobile signal but no data; saved and sent as soon as signal returns.</li><li><b>Phone-to-phone:</b> today this works when riders join one phone's Wi-Fi hotspot (short range); a no-setup offline link is planned.</li><li><b>Needs internet:</b> intercom voice, chat, live group map beyond hotspot range.</li></ul></div>
<div class=col><h3>Quick fixes</h3><table><tr><td><b>Group map not updating</b></td><td>Check mobile data; CoRoute reconnects by itself and never ends the ride.</td></tr><tr><td><b>Crash alarm by mistake</b></td><td>Tap “I'm OK”. CoRoute learns from it for your bike.</td></tr><tr><td><b>“Fix permission” banner</b></td><td>Tap it and allow location, notifications or microphone again.</td></tr><tr><td><b>No fuel stations</b></td><td>Map data can be patchy in rural areas; use the nearby list or ask your group.</td></tr><tr><td><b>No siren alerts</b></td><td>Allow the microphone for CoRoute; put the phone on a mount or in a tank bag.</td></tr><tr><td><b>Speed below the bike's</b></td><td>Normal: speedometers read high by law. CoRoute shows your real GPS speed (chapter 3).</td></tr><tr><td><b>Asked to complete your bike</b></td><td>Fill in the missing details once (chapter 16), or join as a pillion.</td></tr><tr><td><b>Guest sign-in gone</b></td><td>Guest mode was retired; create a free Community account.</td></tr></table>
<div class='box teal'><b>Ride safe.</b> CoRoute helps, but it does not replace a helmet, good gear, rest and your own judgement. In an emergency, call 112.</div></div></div>""", 10, U))

# ------------------------------------------------------------------ INVESTOR MANUAL
T = 'Investor overview'
v = []
v.append(f"""<div class='page cover'><img class=hero src='{S}feature.png'><div class=in>
<div class=eyebrow style='color:#5CCAD3'>Investor overview · November 2026</div>
<h1>CoRoute: the safety and coordination layer for India's riders</h1><p class=lead>A free, phone-only safety app for motorcycle riders, with paid group coordination. Version 3.55 is code-complete and heading into device testing and launch.</p>
<div style='margin:6mm 0'><span class=pill>No hardware needed</span><span class=pill>Safety free forever</span><span class=pill>Freemium group plans</span><span class=pill>Near-zero infrastructure cost</span><span class=pill>Privacy by design</span><span class=pill>Hears sirens and horns</span><span class=pill>Friends, crews, leaderboards</span></div>
<h2 style='color:#fff'>Contents</h2><ol class=toc style='color:#D6F0F3;columns:2;column-gap:10mm'><li>The problem</li><li>The product today</li><li>What makes it different</li><li>What is built (status)</li><li>New in 3.55: sound, calls and live settings</li><li>New in 3.55: community and growth loop</li><li>New in 3.55: campaigns and public impact</li><li>Business model</li><li>Roadmap and next features</li><li>Go-to-market</li><li>Status, risks and the ask</li></ol></div></div>""")

v.append(page(f"""<div class=eyebrow>1 · The problem</div><h1>Two-wheeler riders are India's most exposed road users</h1>
<div class=kpis><div class=kpi><b>1,72,890</b><span>people died in road accidents in India in 2023</span></div><div class=kpi><b>44.8%</b><span>of them were two-wheeler riders (≈ 77,000 lives)</span></div><div class=kpi><b>19.61 M</b><span>two-wheelers sold in India in FY2025 (12.25 M motorcycles)</span></div></div>
<p>Most of these riders carry a smartphone, yet almost none of it is used for their safety. When a rider crashes alone on a highway at night, help depends on someone passing by. In groups, riders lose each other at the first junction, run out of fuel, or ride on unaware that a friend has stopped.</p>
<div class=grid><div class=col><h3>Riders tell us they need</h3><ul><li>Someone to know when they fall, even if they cannot call.</li><li>A group that stays together without constant phone calls.</li><li>Fuel, food and hospitals they can trust on unfamiliar roads.</li><li>Something that works where signal is weak.</li></ul></div>
<div class=col><h3>Why now</h3><ul><li>Leisure and touring riding is growing fast: Royal Enfield alone crossed 1 million sales in FY2025.</li><li>Phones now carry the sensors (accelerometer, gyroscope, GPS) needed for crash detection.</li><li>Riding clubs organise on WhatsApp, with no safety tooling at all.</li></ul></div></div>
<p class=src>Sources: MoRTH Road Accidents in India 2023 as reported by DT Next (Aug 2025); SIAM FY2025 dispatches as reported by Autocar Professional; Royal Enfield FY2025 as reported by Free Press Journal.</p>""", 2, T))

v.append(page(f"""<div class=eyebrow>2 · The product today</div><h1>One app from planning to home</h1>
<div class=phones>{phone('d_01_Start_a_ride.png','Home','design','xs')}{phone('d_02_Navigation_while_riding.png','Navigation cockpit','design','xs')}{phone('d_05_Group_riders.png','Live group','design','xs')}{phone('d_09_Emergency_SOS.png','Crash alarm / SOS','design','xs')}</div>
<div class=phones>{phone('d_06_Fuel.png','Fuel range','design','xs')}{phone('d_08_Guardian.png','Guardian for family','design','xs')}{phone('d_12_Ride_summary.png','Trip report','design','xs')}{phone('m_i09_flags.png','Admin feature switches','ill','xs')}</div>
<p class=muted style='text-align:center'>Plan → ride solo or with a group → be protected on the road → come home with a story. Plus usernames, friends and crews between rides, a private rider score, an admin console with a marketing studio, and a public website with all-time, privacy-safe impact numbers and leaderboards.</p>""", 3, T))

v.append(page(f"""<div class=eyebrow>3 · What makes it different</div><h1>Safety for everyone, coordination for groups</h1>
<table><tr><th>CoRoute</th><th>Typical alternatives</th></tr>
<tr><td><b>Phone only.</b> Crash detection, bike-down check, road hazard detection from the phone's own sensors.</td><td>Crash-detecting helmets and devices cost thousands of rupees.</td></tr>
<tr><td><b>Safety free forever.</b> Every safety feature on the free Community plan.</td><td>Safety features often sit behind premium tiers.</td></tr>
<tr><td><b>Built for groups.</b> Live map, intercom, Lead/Middle/Sweeper roles, regroup, missing-rider and stretch alerts, buddy pairs.</td><td>WhatsApp location sharing and phone calls.</td></tr>
<tr><td><b>Built for Indian roads.</b> Fuel by type (petrol/CNG/EV), dhabas and stays, speed breakers and potholes, rider reviews of places, historic places on the way.</td><td>Generic navigation apps.</td></tr>
<tr><td><b>Rider-first sound.</b> Hears sirens and close horns with the phone's own mic and tells riders in noise-cancelling earbuds or a helmet set; lowers music when speeding; holds ride voice during calls but lets emergencies through; cleans wind and breath out of the group intercom.</td><td>Helmet intercoms and music apps that know nothing about the ride.</td></tr>
<tr><td><b>Weak-signal first.</b> Saved route maps, SMS fallback for SOS, queued messages, solo check-in by ETA, no-signal-ahead notices.</td><td>Most apps fail silently without data.</td></tr>
<tr><td><b>Community data that compounds.</b> Every ride makes the map safer: road hazards, hard-brake hot spots and place reviews, anonymous and rounded (10+ riders behind any public number).</td><td>No shared rider intelligence.</td></tr>
<tr><td><b>Operationally light.</b> Two always-free cloud VMs with live failover; logic runs on the phone, the server relays.</td><td>Expensive per-user backends.</td></tr></table>
<div class=phones>{phone('m_i02_hazard.png','Community road warnings','ill','xs')}{phone('m_i01_roles.png','Riding roles','ill','xs')}{phone('m_i05_placecard.png','Rider reviews','ill','xs')}</div>""", 4, T))

v.append(page(f"""<div class=eyebrow>4 · What is built</div><h1>Version 3.55: code-complete</h1>
<div class=kpis><div class='kpi l'><b>70+</b><span>rider, group and community features</span></div><div class='kpi l'><b>66</b><span>features an admin can switch off live (4 safety ones locked on)</span></div><div class='kpi l'><b>904 / 904</b><span>automated server tests passing</span></div><div class='kpi l'><b>2</b><span>cloud servers with live failover</span></div></div>
<table><tr><th>Area</th><th>Built</th></tr>
<tr><td>Safety</td><td>Crash detection (learns per bike), SOS with SMS fallback, bike-down check, Medical ID (always given to responders during an emergency), guardian live link + arrival message, solo check-in by ETA, SOS battery reserve, fatigue score, night and altitude care, sharp-bend and speed-limit warnings, road hazards and hard-brake hot spots</td></tr>
<tr><td>Sound and calls</td><td>Emergency-vehicle siren and horn alerts for riders with earbuds or a helmet set, music lowered for alerts and when speeding, call-aware alerts, lock-screen ride controls (Talk / Mute), intercom voice cleanup, settings that apply live mid-ride</td></tr>
<tr><td>Groups</td><td>Live map with bike-shape markers (two riders when a pillion is seated), intercom, Trip owner / Trip head management, Lead/Middle/Sweeper roles and automatic roles, regroup, stretch alert with smart regroup point, missing-rider check with hold-to-send SOS, break planner, buddy pairs, roll call, route to group, pillion seat, bike and pillion swap</td></tr>
<tr><td>Community</td><td>Unique usernames, profiles with ride analytics and pictures, friends by username or invite link (mutual approval, blocks), crews with polls (no chat), crew ride invitations (pick members, they accept from a notification), push notifications when the app is closed, private rider score with tips, public leaderboards by username with opt-out</td></tr>
<tr><td>Navigation</td><td>Speed from a filtered GPS estimator (one number for the display and the speed warning; 7 accuracy fixes in 3.55)</td></tr>
<tr><td>Places</td><td>Fuel by type and range, hospitals and mechanics, rider reviews with photos, historic places on the way</td></tr>
<tr><td>Business</td><td>Free Community plan, Small and Large Group plans with prorated upgrades and coupons (Razorpay), marketing studio for coupon campaign images, admin console with plans, payments, moderation (incl. crews and profile pictures) and feature switches</td></tr>
<tr><td>Platform</td><td>Android app (iOS building), Node.js gateway on Oracle Cloud free tier with two-VM failover, encrypted backups, own domain coroute.devmonks.space (old address kept as an automatic fallback), push notifications (Firebase), privacy-safe public website with all-time totals and leaderboards</td></tr></table>
<div class='box warn'><b>Honest status.</b> Built and verified with automated tests and code analysis. The newest sound and call features also need their Android native code compiled and checked on phones; the new community screens, bike markers, pillion flow, push notifications (after the Firebase project is set up) and the domain move need a check on real phones. Next: final build, real-road testing on several phones, production deploy, Play Store launch. iPhone is in development.</div>""", 5, T))

v.append(page(f"""<div class=eyebrow>5 · New in 3.55: sound, calls and live settings</div><h1>The phone becomes the rider's ears</h1>
<p class=lead>Riders with noise-cancelling earbuds, helmet sets and music hear less of the road. 3.55 gives the phone ears, with no extra hardware: its own microphone hears the ambulance and CoRoute says it in the rider's ears. All on the phone.</p>
<div class=kpis><div class=kpi><b>1.9–2.9 s</b><span>to detect a siren 13 dB under the ride noise (synthetic)</span></div><div class=kpi><b>0</b><span>false siren or horn alerts in 20 min of synthetic road audio</span></div><div class=kpi><b>−30 dB</b><span>breath in intercom voice (wind gusts −34.5 dB); speech changed &lt; 1 dB</span></div><div class=kpi><b>12 ms</b><span>added intercom delay from voice cleanup</span></div></div>
<div class=grid><div class=col><table><tr><th>Shipped in 3.55</th><th>What it does</th><th>Admin switch</th></tr>
<tr><td><b>Siren alerts</b></td><td>Wail, yelp and hi-lo (incl. Indian ambulance hi-lo); approaching / moving away; “keep left and give way” in the earbuds or helmet when the rider can't hear outside</td><td>sirenDetector</td></tr>
<tr><td><b>Horn alerts</b></td><td>“Horn close by. Check your mirrors.” when earbuds, a helmet set or music may hide traffic</td><td>hornAlert</td></tr>
<tr><td><b>Clear intercom</b></td><td>Wind, engine, noise and breath removed; hands-free sends nothing on breath or wind</td><td>voiceCleanup</td></tr>
<tr><td><b>Music and alerts</b></td><td>Alerts lower music; emergencies pause it and play in the headset, or at alarm volume (even in DND)</td><td>—</td></tr>
<tr><td><b>Lower music when speeding</b></td><td>60% at 10% over, 30% at 25%, paused at 40%; back when under</td><td>speedAudio</td></tr>
<tr><td><b>Call-aware alerts</b></td><td>Ride voice waits during calls; critical alerts still get through; catch-up after the call</td><td>callAwareAlerts</td></tr>
<tr><td><b>Lock screen</b></td><td>Speed, limit, next warning, intercom state; Talk and Mute without unlocking</td><td>—</td></tr>
<tr><td><b>Live settings</b></td><td>Every setting applies mid-ride; stricter speed limit wins; bike colour updates live</td><td>riderVehicleLive</td></tr></table></div>
<div class=col style='max-width:42mm'>{phone('m_i15_siren.png','Siren card and spoken alert','mock','xxs')}</div></div>
<div class='box warn' style='font-size:8.5pt;padding:3mm 4mm'><b>How to read these numbers.</b> They are <b>lab results on synthesised audio</b> (engine, wind, speech, music and sirens mixed in software), run on the same code as the automated tests, not real-road results. Known limits: a phone in a pocket at speed may not hear a siren; one microphone cannot tell direction, so alerts never say “behind”; the Android native audio code still has to be compiled and checked on phones before launch.</div>""", 0, T))

v.append(page(f"""<div class=eyebrow>6 · New in 3.55: community and growth loop</div><h1>Riders bring friends, friends form crews</h1>
<p class=lead>Between rides CoRoute now gives riders a name, friends and a crew. Every piece feeds the next ride, and every ride feeds the loop.</p>
<div style='display:flex;align-items:stretch;gap:1.5mm;margin:3mm 0 3mm;font-size:9pt;line-height:1.3'>
<div class=box style='flex:1;margin:0;text-align:center;padding:2.5mm 1.5mm'><b>Username</b><div class=src>automatic and unique</div></div><b style='color:#0B6E78;align-self:center'>→</b>
<div class=box style='flex:1;margin:0;text-align:center;padding:2.5mm 1.5mm'><b>Invite link</b><div class=src>opens the app or the store</div></div><b style='color:#0B6E78;align-self:center'>→</b>
<div class=box style='flex:1;margin:0;text-align:center;padding:2.5mm 1.5mm'><b>Friends</b><div class=src>both agree</div></div><b style='color:#0B6E78;align-self:center'>→</b>
<div class=box style='flex:1;margin:0;text-align:center;padding:2.5mm 1.5mm'><b>Crew poll</b><div class=src>“When shall we ride?”</div></div><b style='color:#0B6E78;align-self:center'>→</b>
<div class=box style='flex:1;margin:0;text-align:center;padding:2.5mm 1.5mm'><b>Ride invite</b><div class=src>push, one-tap Accept</div></div><b style='color:#0B6E78;align-self:center'>→</b>
<div class='box teal' style='flex:1;margin:0;text-align:center;padding:2.5mm 1.5mm'><b>Group ride</b><div class=src>one host plan, friends free</div></div><b style='color:#0B6E78;align-self:center'>→</b>
<div class=box style='flex:1;margin:0;text-align:center;padding:2.5mm 1.5mm'><b>Score, boards</b><div class=src>a reason to ride again</div></div></div>
<table><tr><th style='width:30mm'>Built</th><th>What it does</th><th style='width:28mm'>Admin switch</th></tr>
<tr><td><b>Usernames, profiles</b></td><td>Unique username for every rider (e.g. SwiftFalcon482); profile with picture and ride analytics (trips, km, hours, longest trip, largest group, score)</td><td>profilePhotos (pictures; usernames are core)</td></tr>
<tr><td><b>Friends</b></td><td>By username or personal invite link; mutual approval; silent blocks; never phone, e-mail, medical info or location to others</td><td>friends</td></tr>
<tr><td><b>Crews and polls</b></td><td>Standing circles of friends (crew admin, co-admins, members, up to 100); invitation only; polls only, no chat to moderate</td><td>crews, crewPolls</td></tr>
<tr><td><b>Crew rides, push</b></td><td>The host invites chosen crew members; they join from a notification with Accept (no code). Friend, crew and poll notifications reach riders with the app closed</td><td>crewRides, pushNotifications</td></tr>
<tr><td><b>Leaderboards</b></td><td>Top score, longest ride, most km, hours and rides; by username only, with opt-out; in the app and on the website</td><td>leaderboard</td></tr>
<tr><td><b>Rider score</b></td><td>Private 0–100 safety score with levels and tips</td><td>riderScore</td></tr></table>
<div class=grid><div class=col>
<h3>Rider score: a safety incentive, not a speed game</h3><p>Built from speed discipline (40%), smoothness (25%), safety habits (25%) and regular riding (10%), with levels Learner, Steady, Skilled and Ace Rider and personal tips.</p>
<ul><li>Riding over the limit lowers it; going faster never raises it.</li><li>Using SOS or having a crash never lowers it.</li><li>It unlocks after 3 rides of 10 km or more, so riders come back; the top-score board makes safe riding the thing to show off.</li><li>Base for future partner offers (insurance, roadside help), shared only if the rider chooses.</li></ul>
<p class=src>Gateway tests for these features pass. Screens are mock-ups drawn from the app's code; phone checks pending.</p></div>
<div class=col style='max-width:76mm'><div class=phones style='gap:3mm;margin-top:2mm'>{phone('m_s04_score.png','Rider score','mock','xxs')}{phone('m_s10_ride_invite.png','Crew ride invitation','mock','xxs')}</div></div></div>""", 0, T))

v.append(page(f"""<div class=eyebrow>7 · New in 3.55: campaigns and public impact</div><h1>Market with real coupons, prove it with real numbers</h1>
<h3>Marketing studio (admin console)</h3>
<div class=grid><div class=col><p>The team makes coupon and offer posts inside the admin console, without a designer or another tool. Start from a template (festive offer, group plan discount, first ride free, referral, weekend flash sale) or a blank canvas, <b>bind a live coupon</b> and its code, discount, validity and plan fill in by themselves and follow later coupon edits. Add text, logo, badges, images and a <b>QR code</b> to the download page; export a 1080×1080 post, a 1080×1920 story / WhatsApp status and a 1200×628 banner in one go, with a ready caption to share.</p>
<ul><li>Admin only; no rider data in templates; expired or paused coupons ask before export; every change in the audit log.</li><li>Limits today: the QR link opens the download page, but the coupon is still typed by the rider; the editor needs a check on a device.</li></ul></div>
<div class=col style='max-width:84mm'><img src='{S}mk_starters.jpg' style='width:100%;border-radius:3mm;border:1px solid #E1E9EE'><div class=cap style='max-width:none'>Starter templates bound to a sample coupon (rendered by the visual-check copy of the studio's painter).</div></div></div>
<h3>Website: all-time impact</h3>
<div class=grid><div class=col style='max-width:98mm'><img src='{S}w_impact.png' style='width:100%;border-radius:3mm;border:1px solid #E1E9EE'><div class=cap style='max-width:none'><span class='tag t-real'>REAL WEBSITE SCREENSHOT</span> sample data, desktop light theme</div></div>
<div class=col><p>The home page now shows totals <b>since CoRoute began</b>: riders on the road, hours on the road, kilometres, rides, group rides, largest group, longest trip and bikes, plus what the safety features did (SOS resolved, crash alerts, alerts answered by fellow riders, road hazards) and a “this week” line. A <b>leaderboards</b> page shows the top 10 riders by username.</p>
<ul><li>Computed by one server every 5 minutes and served by both; rounded down and hidden until at least 10 rides or alerts are behind a number.</li><li>Never per rider, route or place. Leaderboards appear once riders pass the 3-ride rule.</li></ul></div></div>""", 0, T))

v.append(page(f"""<div class=eyebrow>8 · Business model</div><h1>Free safety builds trust; groups pay for coordination</h1>
<table><tr><th>Stream</th><th>How it works</th><th>Status</th></tr>
<tr><td><b>Group plans</b></td><td>Small Group (2–6) ₹49/month, Large Group (7–12) ₹99/month (default catalogue prices). Only the host pays; friends join free and get the host's group features for that ride.</td><td>Built, with Razorpay; campaigns from the marketing studio</td></tr>
<tr><td><b>Tour operators and clubs</b></td><td>Operator dashboard for paid tours: riders, back-up vehicle, alerts, messaging.</td><td>Next (concept)</td></tr>
<tr><td><b>Partners</b></td><td>Opt-in offers for safe riders: insurance renewals, roadside assistance, certified helmets and gear. The rider score now exists (private, 0–100); riders would share it once, never their rides.</td><td>Next (score built)</td></tr>
<tr><td><b>Events</b></td><td>Discover and join public rides and club events; featured listings for organisers.</td><td>Next (concept)</td></tr>
<tr><td><b>Fleets and delivery riders</b></td><td>Safety and check-ins for companies with riders on the road.</td><td>Explore</td></tr>
<tr><td><b>Road-safety insights</b></td><td>Aggregated, anonymous hazard and hard-brake hot spots for road authorities and city partners (always rounded, 10+ riders).</td><td>Explore</td></tr></table>
<h3>Cost structure</h3><p>The heavy logic (crash detection, fuel, route guidance) runs on riders' phones, and the server mostly relays messages. Today it runs on two always-free Oracle Cloud VMs; the next step is a load test that sets how many live riders they carry (current estimate 200–700 live riders) before paid capacity is needed.</p>""", 6, T))

v.append(page(f"""<div class=eyebrow>9 · Roadmap and next features</div><h1>Where CoRoute goes next</h1>
<div class=phones>{phone('m_c01_mesh.png','Offline group link phone to phone (Bluetooth / Wi-Fi Direct)','con','xxs')}{phone('m_c02_voice.png','“Hey CoRoute” voice assistant in Indian languages','con','xxs')}{phone('m_c03_events.png','Public rides and club events','con','xxs')}</div>
<div class=phones>{phone('m_c04_safescore.png','Partner offers for safe riders (the score itself is built in 3.55)','con','xxs')}{phone('m_c05_fleet.png','Tour operator dashboard','con','xxs')}{phone('m_c06_watch.png','Smartwatch crash confirmation','con','xxs')}</div>
<p class=muted style='margin:1mm 0'><b>Moved to built in 3.55:</b> rider score (was “safe rider score”), friends, crews with polls, crew ride invitations, push notifications, own domain, public leaderboards, marketing studio for campaigns, all-time website numbers.</p>
<table><tr><th>Next 3 months</th><th>6–12 months</th></tr><tr><td>Play Store launch · iPhone (TestFlight → App Store) · real-road tuning of sensors, siren and horn detection, and intercom voice cleanup on several phones · switch links to coroute.devmonks.space (built; old address kept as fallback) · load test and paid capacity plan</td><td>Offline phone-to-phone link · voice assistant · public events and tour operators · partner offers built on the rider score · coupon applied straight from the campaign QR link · smartwatch · more Indian languages</td></tr></table>""", 7, T))

v.append(page(f"""<div class=eyebrow>10 · Go-to-market</div><h1>Riders bring riders</h1>
<div class=grid><div class=col><ul>
<li><b>Riding clubs first.</b> One host brings 5–11 riders who join free; every group ride is a demo of the product. Clubs live on as <b>crews</b> in the app, planning the next ride with polls.</li>
<li><b>Invites that travel.</b> Every rider has a personal friend link; it opens the app or the download page and turns into a friend request after sign-up.</li>
<li><b>Free safety as the hook.</b> Solo riders adopt for crash detection and guardian; they upgrade when they start hosting groups.</li>
<li><b>Community content.</b> Rider stories, place reviews and road reports make CoRoute more useful in every new region.</li>
<li><b>Trust through transparency.</b> The website shows all-time real totals (riders, hours, kilometres, rides, SOS resolved), never inflated numbers, and public leaderboards by username.</li>
<li><b>Campaigns in minutes.</b> The admin marketing studio turns a live coupon into post, status and banner images with a QR code and caption.</li>
<li><b>Moments that matter.</b> Monsoon rides, Ladakh season, festival weekends, road-safety campaigns with clubs and helmet brands.</li></ul></div>
<div class=col style='max-width:62mm'>{phone('m_i09_flags.png','Admin console: switch any feature off live if it misbehaves','ill','s')}</div></div>
<h3>Success measures we track (admin console, staff excluded)</h3><p>Weekly riders · rides completed · Community-to-group conversion · friend invites accepted · riders in crews · share of riders with a rider score · crash false-alarm rate · SOS acknowledged within 2 minutes · Play Store rating.</p>""", 8, T))

v.append(page(f"""<div class=eyebrow>11 · Status, risks and the ask</div><h1>Ready for its first real riders</h1>
<div class=grid><div class=col><h3>Status (November 2026)</h3><ul><li>v3.55 code-complete across app, server and website: sound, calls and live settings (native audio code still to compile and phone-test) and the community round (usernames, friends, crews, rider score, leaderboards, marketing studio, bike markers, pillion seat; screens to check on phones), plus crew ride invitations, push notifications and the move to our own domain coroute.devmonks.space.</li><li>Nov 9 product decisions built: sirens for riders with earbuds, medical info always available to responders in an emergency, hold-to-send SOS in the missing-rider check, one host plan per group ride, clearer Trip owner / Trip head / Lead roles.</li><li>All 904 automated server tests pass (Nov 9); app logic covered by pure Dart tests; code analysis clean.</li><li>Next: final build, real-road testing, production deploy, Play Store.</li></ul>
<h3>Key risks and how we handle them</h3><ul><li><b>Gaming the score or misuse</b> → speed never rewarded; 3 server-recorded rides for the public board; implausible rides never count; friends-only crews, no chat, silent blocks, admin moderation.</li><li><b>False alarms</b> from phone sensors or the microphone → conservative thresholds, per-bike learning, 0 false alarms in synthetic sound tests so far, real-road tuning before launch; every sound feature has an admin switch.</li><li><b>Patchy map data</b> in rural India → features degrade gracefully; rider reports fill gaps.</li><li><b>Store review</b> of background location and SMS → permissions documented and justified.</li></ul></div>
<div class=col><h3>The ask</h3><div class='box teal' style='min-height:36mm'><p><b>[To be completed by the founders]</b></p><p>Amount · use of funds (launch and growth, device testing, iOS, team) · milestones for the next 12 months.</p></div>
<h3>Contact</h3><p>CoRoute · coroute.devmonks.space<br>[Founder name, e-mail, phone]</p>
<h3>More risks</h3><ul><li><b>Scale</b> → load test, then paid capacity as riders grow.</li><li><b>A feature misbehaves</b> → admins switch it off for everyone in seconds; SOS and crash detection can never be switched off.</li></ul>
<div style='font-size:8pt'>{LEGEND}</div></div></div>""", 9, T))

os.makedirs('/home/claude/manual/out', exist_ok=True)
open('/home/claude/manual/out/user.html', 'w').write(doc(u, 'CoRoute rider guide'))
open('/home/claude/manual/out/investor.html', 'w').write(doc(v, 'CoRoute investor overview'))
print('ok')
