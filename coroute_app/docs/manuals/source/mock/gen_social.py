# Round 4 (Nov 9) mock-ups: profile, friends, crew poll, rider score, leaderboard, bike markers, pillion, complete bike.
# Bike shapes come from bike_shapes.json, the same path data as lib/presentation/garage/bike_silhouette.dart
# (glyph() mirrors the visual-check renderer of the bike agent). Run from /home/claude/manual/mock.
import json, os
import gen  # noqa: F401  (re-writes the older mock html; gives CSS, ROADS, page)
from gen import page, ROADS

from bikeglyph import glyph, bike_svg  # noqa: E402
MOCK = 'MOCK-UP · BUILT IN 3.55'


def marker(x, y, t, colour, ring, people=1, label='', role='', glow=False, dot='#2E7D32', flip=False, faded=False):
    """A map marker plate like BikeMarker: white plate, ring colour, bike in its colour, role letter, status dot."""
    sh = 'box-shadow:0 0 0 6px rgba(11,110,120,.28),0 3px 8px rgba(21,35,46,.25);' if glow else 'box-shadow:0 3px 8px rgba(21,35,46,.25);'
    rl = f"<div style='position:absolute;left:-8px;top:-8px;width:20px;height:20px;border-radius:10px;background:#15232E;color:#fff;font-size:11px;font-weight:900;display:flex;align-items:center;justify-content:center;border:2px solid #fff'>{role}</div>" if role else ''
    dt = f"<div style='position:absolute;right:-5px;top:-5px;width:12px;height:12px;border-radius:6px;background:{dot};border:2px solid #fff'></div>"
    lb = f"<div style='position:absolute;top:44px;left:50%;transform:translateX(-50%);white-space:nowrap;background:rgba(255,255,255,.95);border-radius:8px;padding:1px 7px;font-size:11.5px;font-weight:800;color:#15232E'>{label}</div>" if label else ''
    op = 'opacity:.45;' if faded else ''
    return (f"<div style='position:absolute;left:{x}px;top:{y}px;width:58px;height:40px;border-radius:14px;background:#fff;border:3.5px solid {ring};{sh}{op}display:flex;align-items:center;justify-content:center'>"
            f"{bike_svg(t, colour, 50, people, flip)}{rl}{dt}{lb}</div>")


def bar(pct, colour='#0B6E78'):
    return f"<div style='height:8px;border-radius:4px;background:#E1E9EE;margin-top:6px'><div style='height:8px;border-radius:4px;width:{pct}%;background:{colour}'></div></div>"


def av(t, bg='#E3F3F5', fg='#0B6E78', size=44):
    return f"<div style='width:{size}px;height:{size}px;border-radius:{size//2}px;background:{bg};color:{fg};font-weight:800;display:flex;align-items:center;justify-content:center;font-size:{size*0.34:.0f}px;flex-shrink:0'>{t}</div>"


def stat(v, k):
    return f"<div style='background:#F4F7F9;border-radius:12px;padding:6px 10px'><div style='font-size:17px;font-weight:800'>{v}</div><div class=muted style='font-size:11px'>{k}</div></div>"


# ------------------------------------------------------------------ profile
page('s01_profile', f"""<div class=hd><div class=back>‹</div><div><h1>My profile</h1><div class=sub>What other riders see, and your ride analytics</div></div></div>
<div class=card style='display:flex;gap:14px;align-items:center'>
<div style='position:relative'>{av('AR', 'linear-gradient(135deg,#0B6E78,#5CCAD3)', '#fff', 68)}<div style='position:absolute;right:-2px;bottom:-2px;width:24px;height:24px;border-radius:12px;background:#15232E;color:#fff;font-size:12px;display:flex;align-items:center;justify-content:center;border:2px solid #fff;font-weight:900'>+</div></div>
<div style='min-width:0'><div style='font-size:19px;font-weight:800'>@SwiftFalcon482</div><div class=muted style='font-size:13px'>Asha Rao · Member since Mar 2026</div><div class=teal style='font-weight:800;font-size:13px;margin-top:4px'>Change username</div></div></div>
<div class=ov style='margin-top:4px'>Ride analytics</div>
<div class=card style='display:grid;grid-template-columns:1fr 1fr;gap:6px;padding:10px'>
{stat('42', 'Trips')}{stat('6,480 km', 'Distance')}{stat('151 h', 'Riding hours')}{stat('612 km', 'Longest trip')}{stat('9 riders', 'Largest group')}{stat('77 · Skilled', 'Rider score')}{stat('2', 'Bikes in garage')}{stat('Mar 2026', 'Member since')}</div>
<div class=ov style='margin-top:4px'>Friends</div><div class=card style='padding:4px 16px'>
<div class=row style='padding:10px 0'><div>Friends<div class=muted>12 friends</div></div><div style='background:#C8202F;color:#fff;border-radius:10px;padding:1px 8px;font-size:12px'>1</div></div>
<div class=row style='padding:10px 0'><div>Crews<div class=muted>Sunday Riders, Ghat Crew</div></div><div style='background:#C8202F;color:#fff;border-radius:10px;padding:1px 8px;font-size:12px'>2</div></div>
<div class=row style='padding:10px 0'><div class=teal>Invite friends to CoRoute</div><div class=muted>›</div></div></div>
<div class=ov style='margin-top:4px'>Privacy</div><div class=card style='padding:4px 16px'>
<div class=row style='padding:10px 0;border-bottom:0'><div style='max-width:260px'>Show my username on public leaderboards<div class=muted>Only your username and rounded totals are shown on the CoRoute website.</div></div><div class='tg on'></div></div></div>""", label=MOCK)

# ------------------------------------------------------------------ friends
def frow(a, u, sub, right='', bg='#E3F3F5', fg='#0B6E78'):
    return f"<div class=row style='padding:10px 0'><div style='display:flex;gap:12px;align-items:center'>{av(a, bg, fg, 40)}<div>{u}<div class=muted>{sub}</div></div></div><div class=muted>{right}</div></div>"

page('s02_friends', f"""<div class=hd><div class=back>‹</div><div><h1>Friends</h1><div class=sub>By username or invite link · both must agree</div></div></div>
<div class=card style='padding:12px 16px'><div style='font-weight:800;font-size:14px;margin-bottom:8px'>Add a friend</div>
<div style='display:flex;gap:8px'><div class=field style='flex:1;margin:0;padding:10px 12px'><span style='font-size:15px'>desert_fox</span></div><div class=btn style='margin:0;height:46px;padding:0 14px;font-size:14px'>Send request</div></div>
<div class=muted style='margin-top:8px'>Invite code <b style='color:#15232E;letter-spacing:.08em'>K7P2MX9Q</b> · <span class=teal style='font-weight:800'>Share invite link</span></div></div>
<div class=ov>Requests (1)</div><div class=card style='padding:10px 16px;border:2px solid #0B6E78'>
<div style='display:flex;gap:12px;align-items:center'>{av('T', '#FFF1E6', '#B4541C', 40)}<div><b>ThrottleTiger907</b><div class=muted>Wants to be friends</div></div></div>
<div style='display:flex;gap:8px;margin-top:10px'><div class=btn style='flex:1;margin:0;height:42px'>Accept</div><div class='btn o' style='flex:1;margin:0;height:42px'>Decline</div></div></div>
<div class=ov>Sent (1)</div><div class=card style='padding:2px 16px'>{frow('G', 'ghat_hopper', 'Waiting for an answer', 'Cancel')}</div>
<div class=ov>My friends (3)</div><div class=card style='padding:2px 16px'>
{frow('MR', 'MonsoonMira', 'Mira · 58 trips · 9,120 km', '⋯', '#E9E2F5', '#6B4FA0')}{frow('KK', 'konkan_kid', 'Kiran · 31 trips · 4,050 km', '⋯')}{frow('RR', 'RidgeRunner77', 'Ravi · 77 trips · 12,300 km', '⋯', '#FDE8EA', '#C8202F')}</div>
<div class=muted style='margin:0 24px'>Friends see your username, first name and ride totals, never your phone, e-mail or locations.</div>""", label=MOCK)

# ------------------------------------------------------------------ crew + poll
def opt(t, pct, n, lead=False, mine=False):
    c = '#0B6E78' if lead else '#8FB9BF'
    return (f"<div style='padding:7px 0'><div style='display:flex;justify-content:space-between;font-weight:700;font-size:14px'><span>{'✓ ' if mine else ''}{t}{' <span style=\"font-size:10px;background:#E3F3F5;color:#084F57;border-radius:6px;padding:1px 5px;margin-left:4px\">LEADING</span>' if lead else ''}</span>"
            f"<span class=muted style='font-size:13px'>{pct}% · {n}</span></div>{bar(pct, c)}</div>")

page('s03_crew_poll', f"""<div class=hd><div class=back>‹</div><div><h1>Sunday Riders</h1><div class=sub>Crew · 8 riders · you are the crew admin</div></div></div>
<div style='display:flex;gap:8px;margin:0 20px 12px'><div class=btn style='flex:1;margin:0;height:44px'>＋ New poll</div><div class='btn o' style='flex:1;margin:0;height:44px'>Invite friends</div></div>
<div class=ov style='margin-top:0'>Polls</div>
<div class=card style='padding:12px 16px'><div style='display:flex;justify-content:space-between'><b style='font-size:16px'>When shall we ride?</b><span class=muted>Closes in 2 days</span></div>
<div class=muted>One answer · names shown to the crew · 6 of 8 voted</div>
{opt('Sat 15 Nov', 50, 3, lead=True, mine=True)}{opt('Sun 16 Nov', 33, 2)}{opt('Sat 22 Nov', 17, 1)}{opt('Sun 23 Nov', 0, 0)}
<div style='display:flex;justify-content:space-between;margin-top:6px;font-weight:800;font-size:13px'><span class=teal>Who voted</span><span class=teal>Close poll</span></div></div>
<div class=card style='padding:12px 16px'><div style='display:flex;justify-content:space-between'><b style='font-size:15px'>Where to?</b><span class=muted>Closed</span></div>
<div class=muted>Multiple answers · anonymous votes</div>{opt('Nandi Hills', 86, 6, lead=True)}{opt('Savandurga', 43, 3)}</div>
<div class=ov>Riders (8)</div><div class=card style='padding:2px 16px'>
<div class=row style='padding:9px 0'><div style='display:flex;gap:10px;align-items:center'>{av('AR', size=34)}<div>SwiftFalcon482 <span class=muted>(you)</span></div></div><span class=chip style='margin:0;padding:3px 9px;font-size:11px'>ADMIN</span></div>
<div class=row style='padding:9px 0'><div style='display:flex;gap:10px;align-items:center'>{av('MR', '#E9E2F5', '#6B4FA0', 34)}<div>MonsoonMira</div></div><span class=chip style='margin:0;padding:3px 9px;font-size:11px'>CO-ADMIN</span></div>
<div class=row style='padding:9px 0;border-bottom:0'><div style='display:flex;gap:10px;align-items:center'>{av('KK', size=34)}<div>konkan_kid</div></div><span class=chip style='margin:0;padding:3px 9px;font-size:11px'>MEMBER</span></div></div>""", label=MOCK)

# ------------------------------------------------------------------ rider score
def comp(t, w, v, sub):
    return f"<div style='padding:8px 0'><div style='display:flex;justify-content:space-between;font-weight:800;font-size:14px'><span>{t} <span class=muted style='font-size:11px'>{w}</span></span><span>{v}</span></div><div class=muted style='font-size:11.5px'>{sub}</div>{bar(v)}</div>"

page('s04_score', f"""<div class=hd><div class=back>‹</div><div><h1>Your rider score</h1><div class=sub>How safely you ride, 0 to 100</div></div></div>
<div class=card style='display:flex;gap:16px;align-items:center'>
<svg width=92 height=92 viewBox='0 0 92 92'><circle cx=46 cy=46 r=38 fill=none stroke='#E1E9EE' stroke-width=9 /><circle cx=46 cy=46 r=38 fill=none stroke='#0B6E78' stroke-width=9 stroke-linecap=round stroke-dasharray='{238.8*0.77:.1f} 238.8' transform='rotate(-90 46 46)'/><text x=46 y=55 text-anchor=middle font-size=28 font-weight=800 fill='#15232E' font-family='Manrope,sans-serif'>77</text></svg>
<div><div style='font-size:20px;font-weight:800'>Skilled</div><div class=muted style='font-size:13px'>Safe, steady riding with a few things to polish.</div><div class=muted style='margin-top:4px'>11 rides counted</div></div></div>
<div class=ov style='margin-top:4px'>What makes your score</div><div class=card style='padding:6px 16px'>
{comp('Speed discipline', '40%', 82, 'Time over the limit, and how far over')}{comp('Smoothness', '25%', 71, 'Hard brakes per 100 km')}{comp('Safety habits', '25%', 80, 'Breaks on long rides, staying with the group')}{comp('Regular riding', '10%', 69, 'Riding most fortnights')}</div>
<div class=ov style='margin-top:4px'>Tips</div><div class=card style='padding:10px 16px;font-size:13px;font-weight:600'>
<div>• Leave more gap to the vehicle ahead, so you brake less hard.</div><div style='margin-top:6px'>• Take a 10-minute break at least every 2 hours.</div></div>
<div class=card style='padding:4px 16px'><div class=row style='border-bottom:0;padding:10px 0'><div style='max-width:265px;font-size:14px'>Use my ride safety report for my rider score<div class=muted>Sends only counts per ride. Never your route or position.</div></div><div class='tg on'></div></div></div>
<div class=muted style='margin:0 24px'>Only you can see your score. Speed is never rewarded, and using SOS never lowers your score.</div>""", label=MOCK)

# ------------------------------------------------------------------ leaderboard (app)
def lrow(n, u, v, me=False):
    medal = {1: '#F2C14E', 2: '#C9D3DA', 3: '#E09A6B'}.get(n)
    num = f"<div style='width:26px;height:26px;border-radius:13px;background:{medal};display:flex;align-items:center;justify-content:center;font-weight:800;font-size:12px'>{n}</div>" if medal else f"<div style='width:26px;text-align:center;font-weight:800;color:#5B6B78'>{n}</div>"
    st = 'background:#E3F3F5;margin:0 -16px;padding:10px 16px;' if me else 'padding:10px 0;'
    return f"<div class=row style='{st}'><div style='display:flex;gap:12px;align-items:center'>{num}<div>{u}</div></div><div style='font-weight:800'>{v}</div></div>"

page('s05_leaderboard', f"""<div class=hd><div class=back>‹</div><div><h1>Leaderboard</h1><div class=sub>All time · usernames only</div></div></div>
<div style='margin:0 20px 10px;display:flex;flex-wrap:wrap;gap:6px'><span class='chip on' style='margin:0;padding:5px 10px;font-size:12px'>Top score</span><span class='chip' style='margin:0;padding:5px 10px;font-size:12px'>Longest ride</span><span class='chip' style='margin:0;padding:5px 10px;font-size:12px'>Most km</span><span class='chip' style='margin:0;padding:5px 10px;font-size:12px'>Most hours</span><span class='chip' style='margin:0;padding:5px 10px;font-size:12px'>Most rides</span></div>
<div class=card style='padding:2px 16px'>{lrow(1, 'RidgeRunner77', '96')}{lrow(2, 'ladakh_lata', '94')}{lrow(3, 'spiti.sam', '93')}{lrow(4, 'konkan_kid', '91')}{lrow(5, 'night_owl', '90')}{lrow(6, 'GhatHopper', '89')}{lrow(7, 'desert_fox', '88')}</div>
<div class=card style='padding:2px 16px'>{lrow(42, 'SwiftFalcon482 (you)', '77', me=True)}</div>
<div class=muted style='margin:0 24px'>Score ranks safe riding; speed never earns points. Riders appear after 3 rides of 10 km or more, with a username and the leaderboard on. Turn the leaderboard off in your profile to leave it.</div>""", label=MOCK)

# ------------------------------------------------------------------ map with bike markers
page('s06_bikemap', f"""<div class=map>{ROADS}
{marker(232, 250, 'sport', '#1E63D6', '#1E63D6', 1, 'Vikram', 'L')}
{marker(196, 380, 'retro', '#D32F2F', '#7A4DB0', 2, 'Asha + Kiran')}
{marker(150, 520, 'electric', '#F4F4F4', '#2E7D32', 1, 'Meera')}
{marker(40, 455, 'cruiser', '#1B1B1B', '#E0A21B', 1, 'Dev · stopped', dot='#E0A21B', flip=True)}
{marker(70, 620, 'commuter', '#D32F2F', '#0B6E78', 1, 'You', 'S', glow=True)}
</div>
<div class=dock><b>One marker per bike</b><div class=muted style='margin-top:4px;font-size:12.5px'>The bike's shape (its type) in its colour. Two people = a pillion is seated. Ring: rider colour while moving, amber stopped, red SOS; teal glow = you. L = lead, S = sweeper. Faded = no recent update.</div></div>""", label=MOCK)

# ------------------------------------------------------------------ pillion pick sheet
def pick(t, c, name, bike, sel=False, dis=False):
    st = 'border:2.5px solid #0B6E78;background:#E3F3F5;' if sel else 'border:2px solid #E1E9EE;background:#fff;'
    if dis: st += 'opacity:.45;'
    return (f"<div style='{st}border-radius:16px;padding:8px 12px;margin-bottom:8px;display:flex;align-items:center;gap:10px'>{bike_svg(t, c, 52, 2 if dis else 1)}"
            f"<div style='flex:1;min-width:0'><div style='font-weight:800;font-size:15px'>{name}</div><div class=muted>{bike}</div></div>{'<div class=teal style=\"font-size:20px;font-weight:900\">✓</div>' if sel else ''}</div>")

page('s07_pillion', f"""<div class=map>{ROADS}</div><div class=sheet style='height:640px'><div class=grab></div>
<h1 style='font-size:22px'>Whose bike are you on?</h1><div class=sub style='margin-bottom:12px'>Ride pillion? Pick the bike, then confirm.</div>
{pick('retro', '#D32F2F', 'Asha', 'Royal Enfield Classic 350 (Red)', sel=True)}
{pick('sport', '#1E63D6', 'Vikram', 'Pulsar NS200 (Blue)')}
{pick('electric', '#F4F4F4', 'Meera', 'Ather 450X (White) · has a pillion', dis=True)}
<div style='background:#F4F7F9;border-radius:14px;padding:10px 12px;font-weight:700;font-size:14px;margin-top:4px'>You'll ride pillion on Asha's Royal Enfield Classic 350 (Red). Confirm?</div>
<div style='display:flex;gap:8px;margin-top:8px'><div class=btn style='flex:1'>Confirm</div><div class='btn o' style='flex:1'>Not now</div></div>
<div class=muted style='text-align:center'>Your group sees one bike with two people. Your phone keeps its safety features on.</div>
<div class=teal style='text-align:center;font-weight:800;font-size:13px;margin-top:8px'>I am not riding pillion</div></div>""", label=MOCK)

# ------------------------------------------------------------------ rider sees the offer (decline)
page('s08_pillion_rider', f"""<div class=map>{ROADS}
{marker(196, 420, 'retro', '#D32F2F', '#0B6E78', 2, 'You + Kiran', glow=True)}
{marker(232, 250, 'sport', '#1E63D6', '#1E63D6', 1, 'Vikram', 'L')}</div>
<div style='position:relative;margin-top:8px'><div class='alert t'><div style='display:flex;gap:12px;align-items:center'>{bike_svg('retro', '#D32F2F', 46, 2)}<div style='flex:1'><div class=at>Kiran is riding pillion with you</div><div class=am>Not right? Decline within a minute, or remove them later from their rider card.</div></div></div>
<div style='display:flex;gap:8px;margin-top:10px'><div class='btn w' style='flex:1;margin:0;height:42px'>Decline · 0:48</div><div class='btn o' style='flex:1;margin:0;height:42px'>OK</div></div></div></div>
<div class=dock><b>🔊 Everyone hears: “Kiran is riding pillion with Asha.”</b><div class=muted style='margin-top:6px'>While you ride, the Decline button waits as a chip until you stop. Kiran's phone keeps crash detection and SOS on.</div></div>""", label=MOCK)

# ------------------------------------------------------------------ complete your bike
TYPES = [('commuter', 'Commuter'), ('scooter', 'Scooter'), ('sport', 'Sport'), ('cruiser', 'Cruiser'), ('adventure', 'Adventure'), ('offroad', 'Off-road'), ('electric', 'Electric'), ('retro', 'Cafe racer / Retro')]
tiles = ''.join(f"<div style='border:2px solid {'#0B6E78' if k == 'retro' else '#E1E9EE'};background:{'#E3F3F5' if k == 'retro' else '#fff'};border-radius:12px;padding:3px 2px;text-align:center'>{bike_svg(k, '#D32F2F', 54)}<div style='font-size:9.5px;font-weight:800;line-height:1.1'>{n}</div></div>" for k, n in TYPES)
page('s09_completebike', f"""<div class=map>{ROADS}</div><div class=sheet style='height:735px'><div class=grab></div>
<h1 style='font-size:22px'>Complete your bike</h1><div class=sub style='margin-bottom:10px'>Riders need these before a ride: your group sees your bike, and fuel stops use the tank and mileage.</div>
<div class=field style='padding:8px 12px'><b>MAKE AND MODEL</b><span>Royal Enfield Classic 350</span></div>
<div style='font-size:11px;font-weight:800;color:#5B6B78;letter-spacing:.06em;margin:2px 0 6px'>BIKE TYPE</div>
<div style='display:grid;grid-template-columns:repeat(4,1fr);gap:6px;margin-bottom:10px'>{tiles}</div>
<div style='font-size:11px;font-weight:800;color:#5B6B78;letter-spacing:.06em;margin:2px 0 6px'>COLOUR</div>
<div style='margin-bottom:6px'><span class='chip on' style='padding:5px 11px'>Red</span><span class=chip style='padding:5px 11px'>Black</span><span class=chip style='padding:5px 11px'>Silver</span><span class=chip style='padding:5px 11px'>White</span></div>
<div style='display:flex;gap:8px'><div class=field style='flex:1;padding:8px 10px'><b>ENGINE</b><span>349 cc</span></div><div class=field style='flex:1;padding:8px 10px'><b>TANK</b><span>13 L</span></div><div class=field style='flex:1;padding:8px 10px'><b>MILEAGE</b><span>35 km/L</span></div></div>
<div class=btn style='margin-top:2px'>Save and continue</div>
<div class=teal style='text-align:center;font-weight:800;font-size:13px'>I'm riding pillion (no bike)</div></div>""", label=MOCK)

# ------------------------------------------------------------------ latest round: crew ride invitation (invitee) and picker (host)
# Texts from lib/presentation/social/ride_invite_screen.dart and lib/domain/social/ride_invite_rules.dart.
def irow(icon, text):
    return f"<div style='display:flex;gap:12px;align-items:center;padding:7px 0;font-size:15px;font-weight:700'><span style='width:24px;text-align:center;color:#0B6E78;font-size:17px'>{icon}</span><span>{text}</span></div>"

page('s10_ride_invite', f"""<div class=hd><div class=back>‹</div><div><h1>Ride invitation</h1></div></div>
<div class=card style='display:flex;gap:14px;align-items:center'>{av('AR', 'linear-gradient(135deg,#0B6E78,#5CCAD3)', '#fff', 60)}
<div style='min-width:0'><div style='font-size:18px;font-weight:800'>Asha (@SwiftFalcon482)</div><div class=muted style='font-size:13.5px'>invited you to ride with Sunday Riders</div></div></div>
<div class=card style='padding:14px 18px'><div style='font-size:22px;font-weight:800;letter-spacing:-.01em;margin-bottom:4px'>Nandi Hills sunrise</div>
{irow('⚑', 'Cubbon Park Gate → Nandi Hills')}{irow('◷', 'Started 05:40')}{irow('👥', '3 of 6 riders')}</div>
<div class=muted style='margin:4px 24px 10px;font-size:12.5px'>Joining shares your live location with this group while you ride, like any group ride.</div>
<div style='margin:0 20px'><div class=btn style='height:60px;font-size:18px'>✓&nbsp; Accept</div><div class='btn o' style='height:56px'>✕&nbsp; Decline</div></div>
<div class=dock style='bottom:16px'><div class=muted style='font-weight:800;color:#0B6E78'>AFTER ACCEPT: THE NORMAL JOIN</div><div style='font-size:13px;font-weight:700;margin-top:4px'>Profile check → permissions → <b>Complete your bike</b> (or “I'm riding pillion”) → pre-ride checklist. No join code is shared.</div></div>""", label=MOCK)

def prow(a, u, sub, on=False, status='', bg='#E3F3F5', fg='#0B6E78'):
    box = (f"<div style='width:24px;height:24px;border-radius:7px;background:#0B6E78;color:#fff;display:flex;align-items:center;justify-content:center;font-weight:900;font-size:15px'>✓</div>" if on
           else "<div style='width:24px;height:24px;border-radius:7px;border:2px solid #C2CED6'></div>")
    st = f"<span style='font-size:11px;background:#F4F7F9;border-radius:6px;padding:2px 7px;color:#5B6B78;font-weight:800'>{status}</span>" if status else ''
    return f"<div class=row style='padding:9px 0'><div style='display:flex;gap:12px;align-items:center'>{box}{av(a, bg, fg, 36)}<div>{u}<div class=muted>{sub}</div></div></div>{st}</div>"

page('s11_crew_ride_pick', f"""<div class=hd><div class=back>‹</div><div><h1>Sunday Riders</h1><div class=sub>Crew · 8 riders · you run a live ride</div></div></div>
<div style='display:flex;gap:8px;margin:0 20px 12px'><div class=btn style='flex:1;margin:0;height:44px'>Invite crew to my ride</div></div>
<div class=sheet style='height:640px'><div class=grab></div>
<h1 style='font-size:21px'>Invite Sunday Riders to your ride</h1>
<div class=sub style='margin:6px 0 10px'>Pick who to invite. They get a notification and join when they accept. Your join code is not shared.</div>
<div class=row style='padding:8px 0'><div style='display:flex;gap:12px;align-items:center'><div style='width:24px;height:24px;border-radius:7px;background:#8FB9BF;color:#fff;display:flex;align-items:center;justify-content:center;font-weight:900'>–</div><b>Select all (5)</b></div></div>
{prow('MR', 'MonsoonMira', 'Mira', True, '', '#E9E2F5', '#6B4FA0')}{prow('KK', 'konkan_kid', 'Kiran', True)}{prow('RR', 'RidgeRunner77', 'Ravi', False, 'Joined', '#FDE8EA', '#C8202F')}{prow('T', 'ThrottleTiger907', 'Tanvi', False, 'Waiting', '#FFF1E6', '#B4541C')}{prow('G', 'ghat_hopper', 'Gopal', True)}
<div class=btn style='margin-top:10px'>Invite 3 riders</div></div>""", label=MOCK)

print('ok social')
