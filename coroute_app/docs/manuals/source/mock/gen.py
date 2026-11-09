# Generates labelled mock-up screens (Illustration = built in 3.55; Concept = next features) in the CoRoute design style.
import os
OUT='/home/claude/manual/mock/html'; os.makedirs(OUT,exist_ok=True)
CSS="""
*{box-sizing:border-box}body{margin:0;background:#fff;font-family:Manrope,system-ui,sans-serif;color:#15232E}
.ph{width:390px;height:844px;background:#F4F7F9;position:relative;overflow:hidden;border-radius:0}
.sb{height:44px;display:flex;justify-content:space-between;align-items:center;padding:0 22px;font-size:14px;font-weight:700;color:#15232E}
.hd{display:flex;align-items:center;gap:12px;padding:6px 20px 12px}.back{width:40px;height:40px;border-radius:20px;background:#fff;border:1px solid #E1E9EE;display:flex;align-items:center;justify-content:center;font-size:20px;color:#15232E}
h1{font-size:24px;font-weight:800;margin:0;letter-spacing:-.02em}.sub{font-size:13px;color:#5B6B78;font-weight:600}
.card{background:#fff;border:1px solid #E1E9EE;border-radius:18px;padding:16px;margin:0 20px 12px}
.ov{font-size:11px;font-weight:800;letter-spacing:.1em;color:#5B6B78;text-transform:uppercase;margin:14px 20px 8px}
.row{display:flex;align-items:center;justify-content:space-between;padding:12px 0;border-bottom:1px solid #E1E9EE;font-weight:700;font-size:15px}.row:last-child{border-bottom:0}
.muted{color:#5B6B78;font-size:12px;font-weight:600}.teal{color:#0B6E78}
.btn{height:52px;border-radius:16px;display:flex;align-items:center;justify-content:center;font-weight:800;font-size:15px;background:#0B6E78;color:#fff;margin:8px 0}
.btn.o{background:#fff;color:#0B6E78;border:2px solid #E1E9EE}.btn.w{background:#fff;color:#B4541C;border:2px solid #F0C9B3}
.seg{display:flex;gap:8px}.seg div{flex:1;height:56px;border-radius:14px;border:2px solid #E1E9EE;background:#fff;display:flex;flex-direction:column;align-items:center;justify-content:center;font-weight:800;font-size:14px}.seg div small{font-size:11px;color:#5B6B78;font-weight:600}.seg .on{background:#0B6E78;border-color:#0B6E78;color:#fff}.seg .on small{color:#D6F0F3}
.tg{width:48px;height:28px;border-radius:14px;background:#C2CED6;position:relative}.tg:after{content:'';position:absolute;top:3px;left:3px;width:22px;height:22px;border-radius:11px;background:#fff}.tg.on{background:#0B6E78}.tg.on:after{left:23px}
.chip{display:inline-block;padding:8px 14px;border-radius:20px;border:2px solid #E1E9EE;background:#fff;font-weight:700;font-size:13px;margin:0 6px 8px 0}.chip.on{background:#E3F3F5;border-color:#0B6E78;color:#084F57}
.av{width:44px;height:44px;border-radius:22px;background:#E3F3F5;color:#0B6E78;font-weight:800;display:flex;align-items:center;justify-content:center;font-size:15px}
.alert{border-radius:18px;padding:14px 16px;background:#fff;border:2px solid #F0C9B3;box-shadow:0 8px 24px rgba(21,35,46,.14);margin:0 14px 10px}.alert.t{border-color:#0B6E78}.alert.r{border-color:#C8202F}
.at{font-weight:800;font-size:16px}.am{font-size:13px;color:#3E4F5C;font-weight:600;margin-top:3px}
.map{position:absolute;inset:0;background:#E4EBEE}
.badge{position:absolute;top:12px;left:50%;transform:translateX(-50%);white-space:nowrap;font-size:10px;font-weight:800;letter-spacing:.08em;padding:5px 9px;border-radius:8px;z-index:99}
.ill{background:#084F57;color:#fff}.con{background:#B4541C;color:#fff}
.dock{position:absolute;left:14px;right:14px;bottom:18px;background:#fff;border-radius:22px;padding:14px 16px;box-shadow:0 8px 24px rgba(21,35,46,.14)}
.star{font-size:34px;color:#E0A21B;letter-spacing:4px}.star .e{color:#C2CED6}
.sheet{position:absolute;left:0;right:0;bottom:0;background:#fff;border-radius:28px 28px 0 0;padding:10px 20px 24px;box-shadow:0 -8px 30px rgba(21,35,46,.18)}.grab{width:44px;height:5px;border-radius:3px;background:#C2CED6;margin:0 auto 14px}
.field{border:2px solid #E1E9EE;border-radius:14px;padding:12px 14px;font-size:14px;font-weight:600;color:#5B6B78;margin-bottom:10px}.field b{display:block;font-size:11px;color:#5B6B78;letter-spacing:.06em;margin-bottom:3px}.field span{color:#15232E;font-size:16px;font-weight:800}
"""
ROADS="""<svg width="390" height="844" style="position:absolute;inset:0"><path d="M-20 700 C 80 600 150 640 210 520 S 300 260 420 160" stroke="#fff" stroke-width="26" fill="none"/><path d="M-20 700 C 80 600 150 640 210 520 S 300 260 420 160" stroke="#0B6E78" stroke-width="7" fill="none"/><path d="M0 300 L 390 380" stroke="#fff" stroke-width="14"/><path d="M120 0 L 170 844" stroke="#fff" stroke-width="10"/></svg>"""
def page(name, body, kind='ill', label=None):
    lab = label or ('ILLUSTRATION · BUILT IN 3.55' if kind=='ill' else 'CONCEPT · NEXT FEATURE')
    html=f"<!doctype html><html><head><meta charset=utf-8><style>{CSS}</style></head><body><div class=ph id=ph><div class='badge {kind if kind=='ill' else 'con'}'>{lab}</div><div class=sb><span>10:24</span><span>▮▮▮ 78%</span></div>{body}</div></body></html>"
    open(f'{OUT}/{name}.html','w').write(html)
def rider(av,name,sub,right='',hl=False):
    return f"<div class=row style='{'background:#E3F3F5;margin:0 -16px;padding:12px 16px' if hl else ''}'><div style='display:flex;gap:12px;align-items:center'><div class=av>{av}</div><div>{name}<div class=muted>{sub}</div></div></div><div class=muted>{right}</div></div>"

page('i01_roles', f"""<div class=hd><div class=back>‹</div><div><h1>Arjun K.</h1><div class=sub>Royal Enfield Classic 350 · KA 05 MX 4821</div></div></div>
<div class=card><div style='display:flex;gap:10px;flex-wrap:wrap'><span class=chip>Riding · 64 km/h</span><span class=chip>1.4 km behind you</span></div>
<div style='display:flex;gap:10px'><div style='flex:1' class=card0><div class=muted>Battery</div><b>82%</b></div><div style='flex:1'><div class=muted>To destination</div><b>58 km</b></div></div></div>
<div class=ov>Riding role</div><div style='margin:0 20px'><div class=seg><div>Lead<small>front</small></div><div>Middle<small>middle</small></div><div class=on>Sweeper<small>back</small></div></div>
<p class=muted style='margin:10px 2px'>Arjun is told by voice: “You are now the sweeper. When it is safe, drop back to the end of the group.”</p>
<div class='btn o'>⇅ Swap roles with me</div><div class='btn o'>✆ Call Arjun</div><div class='btn o'>Show on map</div></div>""")

page('i02_hazard', f"""<div class=map>{ROADS}<div style='position:absolute;left:226px;top:470px;width:34px;height:34px;border-radius:17px;background:#B4541C;border:3px solid #fff;color:#fff;font-weight:900;display:flex;align-items:center;justify-content:center'>!</div><div style='position:absolute;left:96px;top:640px' class=av>VP</div></div>
<div style='position:relative;margin-top:8px'><div class=alert><div style='display:flex;gap:12px;align-items:center'><div style='width:42px;height:42px;border-radius:12px;background:#FFF1E6;color:#B4541C;font-size:22px;display:flex;align-items:center;justify-content:center'>⚠</div><div><div class=at style='color:#B4541C'>Pothole ahead</div><div style='font-weight:800;font-size:18px'>300 m · felt by Sandeep (Lead)</div></div></div></div>
<div class='alert t'><div class=at>Speed breaker ahead · 650 m</div><div class=am>Reported by CoRoute riders · 14 reports · <b class=teal>Fixed?</b></div></div></div>
<div class=dock><b>🔊 “Caution. Pothole ahead in 300 metres. Slow down.”</b><div class=muted style='margin-top:6px'>Saved for every rider who takes this road later. No names are stored.</div></div>""")

page('i03_groupsettings', f"""<div class=hd><div class=back>‹</div><div><h1>Group settings</h1><div class=sub>Bangalore Highway Ride · 9 riders</div></div></div>
<div class=ov>Riding roles</div><div class=card><div class=row><div>Automatic roles<div class=muted style='max-width:250px'>The rider at the front leads and the last rider sweeps. Riders are told when their role changes.</div></div><div class='tg on'></div></div></div>
<div class=ov>Group safety</div><div class=card><div class=row><div>Group stretch alert<div class=muted>Lead hears “Group spread 3 km, slow down”</div></div></div><div style='margin:6px 0 4px'><span class=chip>1 km</span><span class=chip>2 km</span><span class='chip on'>3 km</span><span class=chip>5 km</span></div>
<div class=row><div>Buddy pairs<div class=muted>Your buddy: Kiran · each rider watches one buddy</div></div><div class=teal style='font-weight:800'>Reassign</div></div>
<div class=row><div>Lower limit near stops and towns</div><div class=teal style='font-weight:800'>40 km/h</div></div></div>
<div class=ov>Spoken alerts</div><div class=card><div class=row><div>Spoken alerts<div class=muted>Separation and emergency warnings are read out.</div></div><div class='tg on'></div></div></div>""")

page('i04_review', f"""<div class=map>{ROADS}</div><div class=sheet style='height:600px'><div class=grab></div><h1 style='font-size:22px'>How was Sri Sai Dhaba?</h1><div class=sub>You spent 25 min there. A quick rating helps the riders coming after you.</div>
<div class=star style='margin:18px 0 10px;text-align:center'>★★★★<span class=e>★</span></div>
<div class=field><b>YOUR NOTE (OPTIONAL)</b><span style='font-size:15px;font-weight:600'>Clean washrooms, quick parathas, safe parking for bikes.</span></div>
<div class='btn o'>📷 Add a photo</div><div class=muted style='margin:4px 2px 12px'>Photos appear after a quick check. Shown with your first name only.</div>
<div class=btn>Send rating</div><div class=muted style='text-align:center;font-weight:800'>Not now</div></div>""")

page('i05_placecard', f"""<div class=map>{ROADS}<div style='position:absolute;left:200px;top:330px;width:40px;height:40px;border-radius:20px;background:#C25B12;border:3px solid #fff;color:#fff;display:flex;align-items:center;justify-content:center;font-size:18px'>🍴</div><div style='position:absolute;left:226px;top:318px;background:#fff;border-radius:10px;padding:2px 6px;font-size:11px;font-weight:800'>★4.4</div></div>
<div class=sheet style='height:560px'><div class=grab></div><h1 style='font-size:22px'>Sri Sai Dhaba</h1><div class=sub>Place to eat · 1.2 km ahead on your route · open now</div>
<div class=ov style='margin-left:0'>CoRoute rider reviews</div><div style='display:flex;align-items:center;gap:10px'><span style='font-size:30px;font-weight:800'>4.4</span><span class=star style='font-size:20px'>★★★★<span class=e>★</span></span><span class=muted>12 ratings</span></div>
<div style='display:flex;gap:8px;margin:12px 0'><div style='flex:1;height:84px;border-radius:12px;background:linear-gradient(135deg,#D9A066,#8A5A2B)'></div><div style='flex:1;height:84px;border-radius:12px;background:linear-gradient(135deg,#9DB7A4,#4D6B57)'></div><div style='flex:1;height:84px;border-radius:12px;background:linear-gradient(135deg,#C9C2A8,#7C735A)'></div></div>
<div class=row><div>Priya ★★★★★<div class=muted>Bike parking right in front, very friendly. · 2 days ago</div></div></div><div class=row><div>Ravi ★★★★<div class=muted>Good chai stop on the Hosur road. · last week</div></div></div>
<div class=btn>Rate this place</div></div>""")

page('i06_heritage', f"""<div class=map>{ROADS}<div style='position:absolute;left:300px;top:250px;width:38px;height:38px;border-radius:19px;background:#6B4FA0;border:3px solid #fff;color:#fff;display:flex;align-items:center;justify-content:center;font-size:18px'>🏛</div><div style='position:absolute;left:96px;top:640px' class=av>VP</div></div>
<div style='position:relative;margin-top:8px'><div class='alert t'><div class=at>Historic place on your way: Golconda Fort</div><div class=am>12 km ahead, 600 m off the route. Worth a stop?</div><div style='display:flex;gap:10px;margin-top:10px'><div class='btn o' style='flex:1;margin:0;height:44px'>Show</div><div class=btn style='flex:1;margin:0;height:44px'>Add stop</div></div></div></div>
<div class=dock><b>Historic places</b><div class=muted style='margin-top:4px'>Forts, temples, monuments and museums from OpenStreetMap, shown on the map along your route.</div></div>""")

page('i07_offroute', f"""<div class=map>{ROADS}<svg width=390 height=844 style='position:absolute;inset:0'><path d='M150 600 C 120 520 60 470 20 420' stroke='#B4541C' stroke-width='5' stroke-dasharray='8 8' fill='none'/></svg><div style='position:absolute;left:10px;top:400px' class=av>VP</div><div style='position:absolute;left:236px;top:440px;background:#0B6E78;color:#fff' class=av>SB</div></div>
<div style='position:relative;margin-top:8px'><div class=alert><div class=at>You left the group's route</div><div class=am>The group is 1.8 km away on the planned route.</div>
<div class=btn style='margin-top:12px'>Route to group</div><div class='btn o' style='margin:0 0 8px'>Ask group to wait</div><div class=muted style='text-align:center;font-weight:800'>Continue my way</div></div></div>""")

page('i08_garage', f"""<div class=hd><div class=back>‹</div><div><h1>Edit bike</h1><div class=sub>Garage · used for fuel range and engine care</div></div></div>
<div style='margin:0 20px'><div class=field><b>BIKE NAME</b><span>My Classic 350</span></div>
<div style='display:flex;gap:10px'><div class=field style='flex:1'><b>ENGINE (CC)</b><span>349</span></div><div class=field style='flex:1'><b>TANK (L)</b><span>13</span></div><div class=field style='flex:1'><b>KM/L</b><span>35</span></div></div>
<div class=ov style='margin-left:0'>Colour</div><span class='chip on'>Black</span><span class=chip>Red</span><span class=chip>Blue</span><span class=chip>Grey</span><span class=chip>White</span>
<div class=ov style='margin-left:0'>Cooling</div><span class=chip>Not sure</span><span class=chip>Air-cooled</span><span class='chip on'>Air/oil-cooled</span><span class=chip>Liquid-cooled</span>
<div class=card style='margin:10px 0'><b>Full tank ≈ 455 km</b><div class=muted>Engine rest advised after 90 min of hard riding (earlier above 35 °C).</div></div><div class=btn>Save to garage</div></div>""")

page('i09_flags', f"""<div class=hd><div class=back>‹</div><div><h1>Feature switches</h1><div class=sub>Admin · changes reach every app within seconds</div></div></div>
<div class=ov>Safety</div><div class=card><div class=row><div>SOS<div class=muted>Always on</div></div><div class=muted>🔒</div></div><div class=row><div>Crash detection<div class=muted>Always on</div></div><div class=muted>🔒</div></div><div class=row><div>Road hazards<div class=muted>Live pothole and speed-breaker warnings</div></div><div class='tg on'></div></div><div class=row><div>Sharp-bend warning</div><div class='tg on'></div></div></div>
<div class=ov>Group</div><div class=card><div class=row><div>Automatic roles<div class=muted>Turned off by Asha · “testing on tours” · 2 h ago</div></div><div class=tg></div></div><div class=row><div>Buddy pairs</div><div class='tg on'></div></div><div class=row><div>Bike swap</div><div class='tg on'></div></div></div>
<div class=ov>Places</div><div class=card><div class=row><div>Place reviews</div><div class='tg on'></div></div><div class=row><div>Historic places</div><div class='tg on'></div></div></div>""")

page('i10_summary', f"""<div class=hd><div class=back>‹</div><div><h1>Ride complete</h1><div class=sub>Bengaluru → Hosur · today</div></div></div>
<div class=card style='background:#0B6E78;color:#fff;border:0'><div style='display:flex;justify-content:space-between'><div><div style='font-size:11px;opacity:.8'>DISTANCE</div><b style='font-size:24px'>82 km</b></div><div><div style='font-size:11px;opacity:.8'>TIME</div><b style='font-size:24px'>2h 05</b></div><div><div style='font-size:11px;opacity:.8'>AVG SPEED</div><b style='font-size:24px'>46</b></div></div></div>
<div class=ov>Safety summary · only you see this</div><div class=card><div class=row><div>Hard brakes</div><b>3</b></div><div class=row><div>Minutes over the limit</div><b>4</b></div><div class=row><div>Km after dark</div><b>12</b></div><div class=row><div>Breaks</div><b>2</b></div><div class=row><div>Highest tiredness</div><b class=teal>Low</b></div><div class=row><div>Road hazards met</div><b>5</b></div></div>""")

page('i11_missing', f"""<div class=map>{ROADS}</div><div style='position:relative;margin-top:30px'><div class=alert style='border-color:#E0A21B'><div class=at>Are you OK? The group is moving on</div><div class=am>You have been stopped for 4 min and the group is 1.3 km ahead.</div>
<div class=btn style='margin-top:12px'>I'm OK</div><div class='btn w' style='margin:0 0 6px'>Need help</div><div><span class=chip>Waiting for fuel</span><span class=chip>Photo stop</span><span class=chip>Taking a break</span></div></div>
<div class=alert style='border-color:#E1E9EE;box-shadow:none;padding:10px 12px'><div class=muted style='font-size:13px;margin:0 2px 8px'>Need help asks the group to wait. For an emergency, hold Send SOS.</div>
<div style='height:52px;border-radius:26px;background:#C8202F;color:#fff;display:flex;align-items:center;justify-content:center;font-weight:900;font-size:15px;gap:8px'><span style='font-size:18px'>⚠</span>Send SOS · hold to send</div></div></div>
<div class=dock><b>Hold Send SOS for 1.5 s</b> (the label says “Keep holding…”). It sends the same SOS as the big SOS button. A quick tap sends nothing.<div class=muted style='margin-top:6px'>No answer in 90 s: your lead is told.</div></div>""", label='MOCK-UP · BUILT IN 3.55')

page('i12_bikedown', f"""<div style='position:absolute;inset:0;background:#C8202F;color:#fff;padding:60px 24px'><div style='font-size:12px;font-weight:800;letter-spacing:.1em'>BIKE DOWN?</div>
<div style='margin:40px auto 20px;width:180px;height:180px;border-radius:90px;border:8px solid rgba(255,255,255,.4);display:flex;flex-direction:column;align-items:center;justify-content:center'><div style='font-size:64px;font-weight:800'>12</div><div style='font-size:12px'>SECONDS</div></div>
<h1 style='text-align:center;color:#fff'>Your bike fell and has not moved</h1><p style='text-align:center;opacity:.9;font-weight:600'>We alert your group and emergency contact unless you cancel.</p>
<div style='position:absolute;left:24px;right:24px;bottom:60px'><div class=btn style='background:#fff;color:#C8202F'>✕ I'm OK, cancel</div><div class=btn style='background:transparent;border:2px solid #fff'>Send now, don't wait</div></div></div>""")

page('i13_plan', f"""<div class=hd><div class=back>‹</div><div><h1>Change plan</h1><div class=sub>Admin · Ravi Kumar</div></div></div>
<div class=card><div class=row><div>Community (free)<div class=muted>Solo rides, every safety feature</div></div><div class=chip>○</div></div><div class=row style='background:#E3F3F5;margin:0 -16px;padding:12px 16px'><div>Small Group (2–6)<div class=muted>₹49 / month</div></div><div class='chip on'>●</div></div><div class=row><div>Large Group (7–12)<div class=muted>₹99 / month · buddy pairs</div></div><div class=chip>○</div></div></div>
<div style='margin:0 20px'><div class=field><b>DAYS</b><span>30</span></div><div class=field><b>NOTE</b><span style='font-size:14px'>Club lead, monsoon rides</span></div><div class=btn>Save</div><div class=muted>The rider's app shows the plan at once. Every change is audited.</div></div>""")

# Concepts
page('c01_mesh', f"""<div class=map style='background:#DCE4E8'>{ROADS}{''.join(f"<div style='position:absolute;left:{x}px;top:{y}px' class=av>{t}</div>" for x,y,t in [(80,620,'VP'),(130,560,'SB'),(190,500,'AK'),(240,420,'RK'),(280,330,'PR')])}<svg width=390 height=844 style='position:absolute;inset:0'><g stroke='#0B6E78' stroke-width='2' stroke-dasharray='4 5' fill='none'><path d='M102 642 L152 582 L212 522 L262 442 L302 352'/></g></svg></div>
<div style='position:relative;margin-top:8px'><div class='alert t'><div class=at>No internet · 5 riders connected nearby</div><div class=am>Positions and SOS travel phone to phone over Bluetooth and Wi-Fi Direct. No hotspot to set up.</div></div></div>
<div class=dock><b>Offline group link</b><div class=muted style='margin-top:4px'>Each phone relays for the next, so the link stretches along the group. Voice notes queue and play when in range.</div></div>""",kind='con')

page('c02_voice', f"""<div class=map>{ROADS}</div><div class=sheet style='height:420px;text-align:center'><div class=grab></div><div style='width:96px;height:96px;border-radius:48px;background:#0B6E78;margin:10px auto;display:flex;align-items:center;justify-content:center;color:#fff;font-size:40px'>🎙</div>
<h1 style='font-size:22px'>“Hey CoRoute, nearest fuel”</h1><div class=sub style='margin:8px 0 16px'>Indian Oil, 4.2 km ahead on your route, open now. Add it as a stop?</div><div style='display:flex;gap:10px'><div class='btn o' style='flex:1'>No</div><div class=btn style='flex:1'>Yes, add stop</div></div><div class=muted>Hands-free in English, Hindi, Tamil, Telugu, Kannada. Works through the helmet headset.</div></div>""",kind='con')

page('c03_events', f"""<div class=hd><div><h1>Rides near you</h1><div class=sub>Public rides and club events · Bengaluru</div></div></div>
<div class=card style='background:#0B6E78;color:#fff;border:0'><div style='font-size:11px;opacity:.8;font-weight:800'>SUN 16 NOV · 05:30</div><b style='font-size:20px'>Nandi Hills Sunrise Ride</b><div style='opacity:.9;font-size:13px'>BLR Weekend Riders · 18 going · 61 km</div><div class=btn style='background:#fff;color:#0B6E78;margin-top:12px'>Request to join</div></div>
<div class=card><b>Coorg Monsoon Tour</b><div class=muted>3 days · 265 km · verified tour operator · ₹6,500</div></div><div class=card><b>Women Riders Meetup</b><div class=muted>Sat 22 Nov · 16:00 · Indiranagar</div></div><div class=card><b>Charity Ride for Road Safety</b><div class=muted>Sun 30 Nov · 120 riders · helmets donated</div></div>""",kind='con')

page('c04_safescore', f"""<div class=hd><div><h1>Safe rider score</h1><div class=sub>Built on your phone from your own rides</div></div></div>
<div class=card style='text-align:center'><div style='font-size:64px;font-weight:800;color:#0B6E78'>92</div><div class=muted>Top 10% of riders this month</div></div>
<div class=ov>Partner offers (opt-in)</div><div class=card><b>Two-wheeler insurance renewal</b><div class=muted>Up to 15% off for safe riders · share your score once, never your rides</div></div><div class=card><b>24×7 roadside assistance</b><div class=muted>Flat tyre, fuel, towing · one tap from the ride screen</div></div><div class=card><b>Helmet and gear</b><div class=muted>Certified helmets at partner prices</div></div>""",kind='con')

page('c05_fleet', f"""<div class=hd><div><h1>Tour operator</h1><div class=sub>Coorg Monsoon Tour · 14 riders · day 2</div></div></div>
<div style='display:flex;gap:10px;margin:0 20px 12px'><div class=card style='flex:1;margin:0'><div class=muted>Riding</div><b style='font-size:22px'>13</b></div><div class=card style='flex:1;margin:0'><div class=muted>Spread</div><b style='font-size:22px'>2.1 km</b></div><div class=card style='flex:1;margin:0'><div class=muted>Alerts</div><b style='font-size:22px;color:#B4541C'>1</b></div></div>
<div class=card>{rider('MS','Meera S.','Stopped 6 min · fuel','Check on',True)}{rider('RK','Rahul K.','Lead · 72 km/h','')}{rider('AN','Anil N.','Sweeper · 58 km/h','')}</div>
<div class=card><b>Back-up vehicle</b><div class=muted>4.5 km behind the sweeper · spare parts, first aid</div></div><div class='btn' style='margin:0 20px'>Message all riders</div>""",kind='con')

page('c06_watch', f"""<div style='position:absolute;inset:0;background:#15232E;display:flex;align-items:center;justify-content:center;flex-direction:column'><div style='width:230px;height:270px;border-radius:56px;background:#000;border:10px solid #2A3842;display:flex;flex-direction:column;align-items:center;justify-content:center;color:#fff;text-align:center;padding:20px'><div style='font-size:12px;color:#F0C9B3;font-weight:800'>CRASH CHECK</div><div style='font-size:44px;font-weight:800;margin:8px 0'>♥ 132</div><div style='font-size:14px;font-weight:700'>High pulse after impact. Are you OK?</div><div style='margin-top:12px;background:#0B6E78;border-radius:20px;padding:8px 18px;font-weight:800'>I'm OK</div></div>
<p style='color:#fff;max-width:300px;text-align:center;font-weight:600;margin-top:28px'>Smartwatch confirms a crash with heart rate and lets the rider cancel from the wrist.</p></div>""",kind='con')
# ---- 3.55 round 3: sound, calls, lock screen (labelled MOCK-UP) ----
MOCK='MOCK-UP · BUILT IN 3.55'
page('i14_lockscreen', f"""<div style='position:absolute;inset:0;background:linear-gradient(170deg,#1D3440 0%,#0B1517 70%)'></div>
<div style='position:relative;color:#fff;text-align:center;margin-top:40px'><div style='font-size:15px;font-weight:700;opacity:.8'>Sunday 9 November</div><div style='font-size:84px;font-weight:300;letter-spacing:-2px;line-height:1'>10:24</div></div>
<div style='position:relative;margin:28px 12px 0;background:rgba(244,247,249,.96);border-radius:24px;padding:14px 16px 12px'>
<div style='display:flex;align-items:center;gap:8px;font-size:12px;font-weight:700;color:#5B6B78'><div style='width:20px;height:20px;border-radius:6px;background:#0B6E78;color:#fff;display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:900'>C</div>CoRoute · Ride in progress</div>
<div style='font-weight:800;font-size:16px;margin-top:8px'>Bangalore Highway Ride · 6 riders</div>
<div style='font-size:14px;font-weight:700;color:#15232E;margin-top:4px'>55 km/h · limit 60 · Warning in 1.2 km</div>
<div style='font-size:14px;font-weight:700;color:#0B6E78;margin-top:2px'>Receiving Asha</div>
<div style='display:flex;gap:8px;margin-top:12px'>
<div style='flex:1;height:44px;border-radius:14px;background:#C8202F;color:#fff;display:flex;align-items:center;justify-content:center;font-weight:900;font-size:14px'>SOS</div>
<div style='flex:1;height:44px;border-radius:14px;background:#0B6E78;color:#fff;display:flex;align-items:center;justify-content:center;font-weight:800;font-size:14px'>Talk</div>
<div style='flex:1;height:44px;border-radius:14px;background:#fff;border:2px solid #E1E9EE;color:#0B6E78;display:flex;align-items:center;justify-content:center;font-weight:800;font-size:14px'>Mute</div>
<div style='flex:1;height:44px;border-radius:14px;background:#fff;border:2px solid #E1E9EE;color:#5B6B78;display:flex;align-items:center;justify-content:center;font-weight:800;font-size:14px'>Leave</div></div></div>
<div style='position:relative;margin:10px 12px 0;background:rgba(244,247,249,.9);border-radius:20px;padding:12px 16px'><div style='font-size:12px;font-weight:700;color:#5B6B78'>Intercom states shown on the line above</div><div style='font-size:13px;font-weight:700;margin-top:4px'>Talking · Receiving (name) · Hands-free on · Group voice muted · Voice paused (call)</div></div>
<div style='position:absolute;left:24px;right:24px;bottom:40px;color:#D6F0F3;text-align:center;font-size:13px;font-weight:600'>Talk turns hands-free talk on or off. Mute stops hearing the group. Both work without unlocking. No map or location is shown here.</div>""", label=MOCK)

page('i15_siren', f"""<div class=map>{ROADS}<div style='position:absolute;left:96px;top:560px' class=av>VP</div><div style='position:absolute;left:140px;top:720px;width:30px;height:30px;border-radius:15px;background:#C8202F;opacity:.18'></div></div>
<div style='position:relative;margin-top:8px'><div class='alert r' style='padding:14px'><div style='display:flex;gap:12px;align-items:center'><div style='width:44px;height:44px;border-radius:22px;background:#FDE8EA;display:flex;align-items:center;justify-content:center;font-size:22px'>🚨</div>
<div style='flex:1;min-width:0'><div style='color:#C8202F;font-weight:900;font-size:15px;letter-spacing:.04em'>EMERGENCY VEHICLE SIREN</div>
<div style='display:flex;gap:6px;align-items:center;margin-top:4px'><span style='background:#C8202F;color:#fff;font-size:11px;font-weight:800;padding:2px 6px;border-radius:5px;white-space:nowrap'>GIVE WAY</span><span style='font-size:12.5px;font-weight:700;color:#3E4F5C'>Hi-lo siren · ambulance-like · Approaching · Close</span></div></div><div style='color:#5B6B78;font-size:20px'>✕</div></div></div></div>
<div class=dock><div class=muted style='font-weight:800;color:#0B6E78'>EARBUDS, HELMET SET OR MUSIC</div><b>🎧 In your ears: “Emergency vehicle approaching, sounds like an ambulance. Keep left and give way.”</b><div class=muted style='margin-top:6px'>Music paused · strong vibration · this card · a heads-up on the lock screen. Heard even with noise cancelling on.</div><div class=muted style='font-weight:800;color:#0B6E78;margin-top:10px'>PHONE SPEAKER, NO MUSIC</div><div class=muted>A short tone, a vibration and this card: you can hear the siren yourself.</div></div>""", label=MOCK)

page('i16_horn', f"""<div class=map>{ROADS}<div style='position:absolute;left:96px;top:560px' class=av>VP</div></div>
<div style='position:relative;margin-top:8px'><div class=alert style='background:#FFF1E6;border-color:#E0A21B'><div style='display:flex;gap:12px;align-items:center'><div style='width:40px;height:40px;border-radius:20px;background:#FBE3BD;display:flex;align-items:center;justify-content:center;font-size:20px'>📣</div>
<div><div style='color:#8A4B12;font-weight:900;font-size:15px;letter-spacing:.04em'>HORN CLOSE BY</div><div style='font-size:13px;font-weight:700;color:#3E4F5C'>Check your mirrors</div></div></div></div></div>
<div class=dock><b>With earbuds, a helmet set or music (Automatic):</b><div style='font-weight:800;margin-top:4px'>🎧 “Horn close by. Check your mirrors.”</div><div class=muted style='margin-top:6px'>On the phone speaker you can hear traffic yourself, so Automatic stays quiet (choose On for a vibration and this card). The card clears after about 4 s. Your own horn is ignored.</div></div>""", label=MOCK)

page('i18_movingchip', f"""<div class=map>{ROADS}<svg width=390 height=844 style='position:absolute;inset:0'><path d='M150 600 C 120 520 60 470 20 420' stroke='#B4541C' stroke-width='5' stroke-dasharray='8 8' fill='none'/></svg><div style='position:absolute;left:30px;top:440px' class=av>VP</div></div>
<div style='position:relative;margin:10px 14px 0'><div style='display:inline-flex;align-items:center;gap:8px;padding:9px 14px;border-radius:999px;background:#FFF1E6;border:2px solid #F0C9B3;color:#8A4B12;font-weight:800;font-size:14px'>✋ Off the group's route · Stop to choose</div>
<div style='margin-top:8px;display:inline-flex;align-items:center;gap:8px;padding:9px 14px;border-radius:999px;background:#fff;border:2px solid #E1E9EE;font-weight:800;font-size:14px'><span style='color:#0B6E78'>🏛</span> Historic place ahead: Golconda Fort</div></div>
<div class=dock><b>🔊 “You're off the route. Stop when safe to route to your group.”</b><div class=muted style='margin-top:6px'>While you ride: one line, once, and a small chip with nothing to tap. When you stop (3 km/h or less for 5 s) the full card comes back with its buttons. A pillion can tap at any time. Safety alerts are never held back.</div></div>""", label='MOCK-UP · BUILT IN 3.55')

def srow(t, sub, on=True, last=False):
    return f"<div class=row style='padding:9px 0;{'border-bottom:0' if last else ''}'><div style='max-width:265px'>{t}<div class=muted>{sub}</div></div><div class='tg{' on' if on else ''}'></div></div>"
def crow(t, sub, chips, sel):
    cs=''.join(f"<span class='chip{' on' if c==sel else ''}' style='padding:5px 11px;margin:6px 6px 0 0'>{c}</span>" for c in chips)
    return f"<div class=row style='display:block;padding:9px 0'>{t}<div class=muted>{sub}</div><div>{cs}</div></div>"
page('i17_voicesound', f"""<div class=hd><div class=back>‹</div><div><h1>Settings</h1><div class=sub>Voice & sound</div></div></div>
<div class=ov style='margin-top:2px'>Voice & sound</div><div class=card style='padding:6px 16px'>
{srow('Speak warnings and directions','Emergency alerts are always spoken.')}
{srow('Pause music during alerts','Off: music only gets quieter.', on=False)}
{srow('Lower music when speeding','Well over the limit, music gets quieter, then pauses.')}
{srow('Siren alerts','Warns you about sirens, even when your earphones block outside sound.')}
{crow('Give way to the','The side the siren alert tells you to keep to.',['Automatic','Left','Right'],'Automatic')}
{crow('Horn alerts','Automatic: only when earphones or music may stop you hearing traffic.',['Automatic','On','Off'],'Automatic')}
{srow('Clean up my voice','Takes out breathing, wind and engine noise.', last=True)}</div>
<div class=muted style='margin:0 24px'>Siren and horn alerts listen on your phone during rides only. Nothing is recorded or sent.</div>""", label=MOCK)

print('ok')
