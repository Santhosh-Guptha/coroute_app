"""Extra v3.58-style mock screens for the website and the Play listing (round 12).

Same CSS, icons and helpers as gen_redesign.py (the round 11 redesign mocks): crash check, SOS sent,
rescue finder ("Find Ravi"), offline link and trip report. Demo data and fictional names only.
Theme: append #light to the URL (default dark).

    python3 gen_extra.py <out dir>
"""
import math, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

# Reuse the redesign kit: everything above the first screen in gen_redesign.py (CSS, icons, ic, art, status, nav, page).
_src = open(os.path.join(HERE, 'gen_redesign.py')).read()
_head = _src[:_src.index('# ------------------------------------------------------------------ Home')]
_ns = {'__file__': os.path.join(HERE, 'gen_redesign.py'), '__name__': 'kit'}
_argv = sys.argv
sys.argv = [_argv[0], OUT]
exec(compile(_head, 'gen_redesign.py', 'exec'), _ns)
sys.argv = _argv
ic, art, page, CSS = _ns['ic'], _ns['art'], _ns['page'], _ns['CSS']

EXTRA_CSS = """
.ring{position:relative;width:220px;height:220px;margin:0 auto}
.ring b{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center;font-size:64px;font-weight:700;line-height:1}
.ring b span{font-size:14px;font-weight:500;color:var(--muted);margin-top:6px}
.red{background:var(--sos);color:#fff}
.btn.r{background:var(--sos);color:#fff}
.tick{width:28px;height:28px;border-radius:50%;background:var(--success);display:flex;align-items:center;justify-content:center;flex:none}
.tick.w{background:var(--asoft)}
.meter{height:14px;border-radius:7px;background:var(--alt);overflow:hidden;position:relative}
.meter i{position:absolute;left:0;top:0;bottom:0;border-radius:7px}
.mapbox{position:relative;overflow:hidden}
.chipx{display:inline-flex;align-items:center;gap:8px;height:40px;padding:0 14px;border-radius:999px;font-size:14px;font-weight:600}
.kpi{flex:1;background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:12px}
.kpi b{display:block;font-size:22px;font-weight:700;font-variant-numeric:tabular-nums}
.kpi span{font-size:12px;color:var(--muted)}
.status{position:relative;z-index:5}
"""


def page_x(name, body, navon=None):
    """page() with the extra CSS appended to the kit's stylesheet."""
    page(name, body.replace('</body>', ''), navon)
    p = os.path.join(OUT, name + '.html')
    html = open(p).read().replace('</style>', EXTRA_CSS + '</style>', 1)
    open(p, 'w').write(html)


def town_map(w, h, route=True, seed=0, dark_tiles=False):
    """A calm stylised map: blocks, roads, a river and (optionally) the planned route in teal."""
    blocks = ''
    for i in range(9):
        for j in range(14):
            x = i * 52 - 20 + (j % 2) * 18
            y = j * 70 - 30
            blocks += f'<rect x="{x}" y="{y}" width="40" height="54" rx="6" fill="var(--alt)" opacity=".7"/>'
    roads = ''.join(f'<path d="M{-40 + k * 120},{h + 20} C{60 + k * 120},{h * .6} {k * 120 - 30},{h * .35} {90 + k * 120},-20" stroke="var(--surface)" stroke-width="12" fill="none"/>' for k in range(4))
    roads += ''.join(f'<path d="M-20,{y} L{w + 20},{y - 60}" stroke="var(--surface)" stroke-width="10" fill="none"/>' for y in (h * .3, h * .62))
    river = f'<path d="M{w * .78},-10 C{w * .62},{h * .3} {w + 30},{h * .55} {w * .7},{h + 10}" stroke="#7FB6D6" stroke-opacity=".55" stroke-width="22" fill="none"/>'
    r = ''
    if route:
        r = (f'<path id="rt" d="M{w * .3},{h + 10} C{w * .32},{h * .72} {w * .5},{h * .62} {w * .46},{h * .45} S{w * .62},{h * .2} {w * .58},-10" '
             f'stroke="var(--primary)" stroke-width="9" fill="none" stroke-linecap="round" opacity=".95"/>')
    return f'<svg width="{w}" height="{h}" viewBox="0 0 {w} {h}" style="position:absolute;inset:0;background:var(--bg)">{blocks}{roads}{river}{r}</svg>'


def dot(x, y, label, color, ring=False, small=False):
    s = 30 if small else 38
    ringc = f'<div style="position:absolute;inset:-8px;border-radius:50%;border:3px solid {color};opacity:.35"></div>' if ring else ''
    return (f'<div style="position:absolute;left:{x - s / 2}px;top:{y - s / 2}px;width:{s}px;height:{s}px;border-radius:50%;background:{color};'
            f'border:3px solid #fff;color:#fff;font-size:{12 if small else 14}px;font-weight:700;display:flex;align-items:center;justify-content:center;'
            f'box-shadow:0 2px 8px rgba(0,0,0,.3)">{ringc}{label}</div>')


# ------------------------------------------------------------------ Crash check (30 s countdown)
circ = 2 * math.pi * 96
crash = f'''<div class="page" style="padding-top:28px;text-align:center">
<div style="width:64px;height:64px;border-radius:50%;margin:0 auto;background:var(--asoft);display:flex;align-items:center;justify-content:center">{ic("crash",32,"var(--astrong)")}</div>
<div style="font-size:15px;font-weight:600;color:var(--astrong);margin-top:14px">Possible crash</div>
<div style="font-size:32px;font-weight:700;margin-top:4px">Are you OK?</div>
<div class="label" style="margin:10px 12px 0;line-height:1.45">We noticed a hard fall and no movement. If you do not answer, SOS goes out when the timer ends.</div>
<div class="ring" style="margin-top:22px"><svg width="220" height="220" viewBox="0 0 220 220"><circle cx="110" cy="110" r="96" stroke="var(--alt)" stroke-width="14" fill="none"/>
<circle cx="110" cy="110" r="96" stroke="var(--sos)" stroke-width="14" fill="none" stroke-linecap="round" stroke-dasharray="{circ * 0.8:.1f} {circ:.1f}" transform="rotate(-90 110 110)"/></svg><b>24<span>seconds left</span></b></div>
<div class="card" style="text-align:left;margin-top:22px;padding:6px 14px">
 <div class="label" style="padding:8px 0 2px">If you don't answer, SOS reaches</div>
 <div class="listrow">{ic("sms",22,"var(--primary)")}<div class="lbl">Amma, by SMS<div class="caption">Works without mobile data</div></div></div>
 <div class="listrow">{ic("groups",22,"var(--primary)")}<div class="lbl">Your group<div class="caption">Sunday Sunrise Crew · 6 riders</div></div></div>
 <div class="listrow">{ic("pin",22,"var(--primary)")}<div class="lbl">Your location<div class="caption">Ghat road, 2 km after the viewpoint</div></div></div>
</div>
<div class="btn p big" style="margin-top:20px">{ic("check",22,"var(--onp)",2.4)}I'm OK</div>
<div class="btn r big" style="margin-top:12px">{ic("sos",22,"#fff",1.6)}Need help now</div>
</div><div class="gesture"></div>'''
page_x('crash', crash)

# ------------------------------------------------------------------ SOS sent (no answer)
def step(icon_html, title, sub, done=True):
    t = f'<span class="tick">{ic("check",16,"#fff",2.6)}</span>' if done else f'<span class="tick w">{icon_html}</span>'
    return f'<div class="listrow" style="align-items:flex-start;padding:12px 0;gap:14px">{t}<div style="flex:1"><div style="font-weight:600;font-size:15px">{title}</div><div class="label" style="margin-top:2px;line-height:1.4">{sub}</div></div></div>'

sos = f'''<div style="background:var(--sos);color:#fff;padding:20px 20px 22px;margin-top:-32px;padding-top:52px">
 <div class="row gap12">{ic("sos",34,"#fff",1.6)}<div style="flex:1"><div style="font-size:26px;font-weight:700">SOS sent</div><div style="font-size:14px;opacity:.9">No answer to the crash check · 1 min ago</div></div></div>
</div>
<div class="page" style="padding-top:16px">
<div class="card" style="padding:2px 14px">
 {step('', 'SMS sent to Amma and Dev', 'Your location as a map link. Sent from this phone, no data needed.')}
 {step('', 'Your group was alerted', 'Meera and Imran are coming back · 1.4 km away')}
 {step('', 'Live link shared', 'Your family can follow your position in any browser.')}
 {step(ic("bt",16,"var(--astrong)"), 'Rescue beacon on', 'The siren gets louder and your phone sends a locator signal. Helps riders find you in the last stretch.', False)}
</div>
<div class="card row gap12" style="margin-top:14px">{ic("health",26,"var(--sos)")}<div style="flex:1"><div class="title">Medical ID</div><div class="label">Blood group B+ · no known allergies</div></div><span class="chev">{ic("chev",22)}</span></div>
<div class="btn r big" style="margin-top:22px">{ic("phone",22,"#fff")}Call 112</div>
<div class="btn o big" style="margin-top:12px">I'm OK, cancel SOS</div>
<div class="caption" style="text-align:center;margin-top:14px;line-height:1.45">CoRoute adds to emergency services. It does not replace them.</div>
</div><div class="gesture"></div>'''
page_x('sos', sos)

# ------------------------------------------------------------------ Rescue finder: "Find Ravi"
arc_len = math.pi * 130
finder = f'''<div class="page" style="padding-top:12px">
<div class="row gap12"><div class="round">{ic("back",24)}</div><div style="flex:1"><div style="font-size:22px;font-weight:700">Find Ravi</div><div class="label">SOS · crash, no answer</div></div><span class="chipx" style="background:var(--asoft);color:var(--astrong)">{ic("speed",18)}Siren on</span></div>
<div class="card" style="margin-top:16px;text-align:center;padding:18px 16px 16px">
 <div style="position:relative;width:300px;height:200px;margin:0 auto">
 <svg width="300" height="200" viewBox="0 0 300 200" style="display:block">
  <defs><linearGradient id="hc" x1="0" x2="1"><stop offset="0" stop-color="#79A8E8"/><stop offset=".5" stop-color="var(--accent)"/><stop offset="1" stop-color="var(--sos)"/></linearGradient></defs>
  <path d="M20,160 A130,130 0 0 1 280,160" stroke="var(--alt)" stroke-width="22" fill="none" stroke-linecap="round"/>
  <path d="M20,160 A130,130 0 0 1 280,160" stroke="url(#hc)" stroke-width="22" fill="none" stroke-linecap="round" stroke-dasharray="{arc_len * .78:.1f} {arc_len:.1f}"/>
  <text x="20" y="194" font-size="12" text-anchor="middle" fill="var(--muted)" font-family="Manrope">Colder</text><text x="280" y="194" font-size="12" text-anchor="middle" fill="var(--muted)" font-family="Manrope">Hotter</text>
 </svg>
 <div style="position:absolute;left:0;right:0;top:92px;font-size:44px;font-weight:700;line-height:1">~30 m</div>
 <div class="caption" style="position:absolute;left:0;right:0;top:144px">estimated</div>
 </div>
 <div class="label" style="margin-top:8px">Close. Walk slowly and watch the meter rise.</div>
 <span class="chipx" style="background:var(--psoft);color:var(--primary);margin-top:14px">{ic("insights",18)}Getting warmer</span>
</div>
<div class="card" style="margin-top:12px">
 <div class="row" style="justify-content:space-between"><div style="font-weight:600;font-size:15px">{ic("bt",18,"var(--primary)")} Bluetooth signal</div><span class="label">In range</span></div>
 <div class="meter" style="margin-top:8px"><i style="width:72%;background:var(--primary)"></i></div>
 <div class="row" style="justify-content:space-between;margin-top:16px"><div style="font-weight:600;font-size:15px">{ic("speed",18,"var(--primary)")} Locator sound</div><span class="label">Heard</span></div>
 <div class="meter" style="margin-top:8px"><i style="width:58%;background:var(--accent)"></i></div>
 <div class="caption" style="margin-top:14px;line-height:1.45">Estimates from signal strength, not exact distances. GPS brought you here; these meters help in the last stretch.</div>
</div>
<div class="row gap8" style="margin-top:18px"><div class="btn o" style="flex:1">{ic("phone",20)}Call Ravi</div><div class="btn p" style="flex:1">{ic("check",20,"var(--onp)",2.4)}I'm with Ravi</div></div>
</div><div class="gesture"></div>'''
page_x('finder', finder)

# ------------------------------------------------------------------ Offline link (no signal in the forest)
W, H = 412, 640
offline = f'''<div class="mapbox" style="height:{H}px;margin-top:-32px">{town_map(W, H)}
 {dot(150, 470, 'Y', '#29707E', True)}{dot(190, 380, 'D', '#D9822B', small=True)}{dot(186, 300, 'K', '#3D7BC8', small=True)}{dot(232, 190, 'M', '#2B7A8C', small=True)}{dot(140, 540, 'I', '#B5577A', small=True)}
 <svg width="{W}" height="{H}" style="position:absolute;inset:0" viewBox="0 0 {W} {H}"><path d="M150,470 L190,380 L186,300 L232,190" stroke="var(--accent)" stroke-width="3" stroke-dasharray="2 8" stroke-linecap="round" fill="none"/></svg>
 <div style="position:absolute;left:16px;right:16px;top:44px" class="row gap8"><div class="round">{ic("back",24)}</div><div class="card row gap8" style="flex:1;height:56px;border-radius:28px;padding:0 16px">{ic("flag",20,"var(--primary)")}<div style="flex:1"><div style="font-weight:600">Kemmanagundi</div><div class="caption">38 km · 10:42 am</div></div></div></div>
 <div style="position:absolute;left:16px;top:112px" class="row gap8"><span class="chipx" style="background:var(--surface);color:var(--muted);border:1px solid var(--border)">{ic("nosignal",18)}No mobile signal</span></div>
 <div style="position:absolute;left:16px;top:160px"><span class="chipx" style="background:var(--asoft);color:var(--astrong);border:1px solid var(--aborder)">{ic("bt",18)}Offline link · 5 riders, 2 hops</span></div>
</div>
<div style="background:var(--surface);border-radius:20px 20px 0 0;border-top:1px solid var(--border);margin-top:-20px;position:relative;padding:8px 20px 40px">
 <div style="width:36px;height:4px;border-radius:2px;background:var(--border2);margin:4px auto 12px"></div>
 <div class="title">Offline link</div>
 <div class="label" style="margin-top:4px;line-height:1.45">No signal here. The group's phones pass messages along, a few hundred metres per hop.</div>
 <div class="listrow" style="margin-top:6px">{ic("person",22,"var(--primary)")}<div class="lbl">Meera <span class="caption">Lead</span></div><span class="label">2 hops</span></div>
 <div class="listrow">{ic("person",22,"var(--primary)")}<div class="lbl">Kiran</div><span class="label">1 hop</span></div>
 <div class="listrow">{ic("chat",22,"var(--primary)")}<div class="lbl" style="font-size:14px">Imran: Fuel stop after the bridge</div><span class="caption">via Dev</span></div>
</div><div class="gesture"></div>'''
page_x('offline', offline)

# ------------------------------------------------------------------ Trip report
def chart(w, h):
    xs = [0, 8, 16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, 128]
    vs = [0, 34, 52, 58, 46, 22, 38, 61, 66, 54, 30, 0, 28, 48, 57, 44, 0]
    px = lambda x: 34 + x / 128 * (w - 44)
    py = lambda v: h - 24 - v / 80 * (h - 40)
    pts = ' '.join(f'{px(x):.1f},{py(v):.1f}' for x, v in zip(xs, vs))
    grid = ''.join(f'<path d="M34,{py(v):.1f} H{w - 10}" stroke="var(--border)" stroke-width="1"/><text x="28" y="{py(v) + 4:.1f}" font-size="10" text-anchor="end" fill="var(--muted)" font-family="Manrope">{v}</text>' for v in (0, 40, 80))
    lim = f'<path d="M34,{py(60):.1f} H{w - 10}" stroke="var(--accent)" stroke-width="1.5" stroke-dasharray="5 4"/><text x="{w - 12}" y="{py(60) - 5:.1f}" font-size="10" text-anchor="end" fill="var(--astrong)" font-family="Manrope">limit 60</text>'
    xl = ''.join(f'<text x="{px(x):.1f}" y="{h - 6}" font-size="10" text-anchor="{a}" fill="var(--muted)" font-family="Manrope">{x} km</text>' for x, a in ((0, 'start'), (64, 'middle'), (128, 'end')))
    return f'<svg width="{w}" height="{h}" viewBox="0 0 {w} {h}">{grid}{lim}<polyline points="{pts}" fill="none" stroke="var(--primary)" stroke-width="2.5" stroke-linejoin="round"/>{xl}</svg>'

trip = f'''<div class="page" style="padding-top:12px">
<div class="row gap12"><div class="round">{ic("back",24)}</div><div style="flex:1"><div style="font-size:20px;font-weight:700">Nandi sunrise run</div><div class="label">Sun 16 Nov · 6 riders · everyone home</div></div><div class="round">{ic("share",22)}</div></div>
<div class="mapbox" style="height:200px;border-radius:16px;margin-top:14px;border:1px solid var(--border)">{town_map(372, 200)}
 <svg width="372" height="200" viewBox="0 0 372 200" style="position:absolute;inset:0"><path d="M100,210 C110,150 170,130 160,96 S220,40 214,-10" stroke="#D9822B" stroke-width="3" fill="none"/><path d="M114,210 C124,150 184,128 174,94 S232,40 226,-10" stroke="#B5577A" stroke-width="3" fill="none"/></svg>
 {dot(110, 172, 'S', '#3E8E5E', small=True)}{dot(220, 22, 'F', '#2B7A8C', small=True)}</div>
<div class="row gap8" style="margin-top:12px"><div class="kpi"><b>128 km</b><span>Distance</span></div><div class="kpi"><b>3 h 42 m</b><span>Moving time</span></div><div class="kpi"><b>3</b><span>Stops</span></div></div>
<div class="row gap8" style="margin-top:8px"><div class="kpi"><b>41 km/h</b><span>Avg moving</span></div><div class="kpi"><b>66 km/h</b><span>Peak</span></div><div class="kpi"><b>4 min</b><span>Over the limit</span></div></div>
<div class="card" style="margin-top:12px;padding:12px 10px 6px"><div class="title" style="padding-left:6px">Speed over the ride <span class="caption">km/h</span></div>{chart(350, 150)}</div>
<div class="card" style="margin-top:12px;padding:4px 14px">
 <div class="listrow">{ic("mail",22,"var(--primary)")}<div class="lbl">Ride summary e-mailed</div><span class="chev">{ic("chev",20)}</span></div>
 <div class="listrow">{ic("location",22,"var(--primary)")}<div class="lbl">Family followed on the live link</div><span class="chev">{ic("chev",20)}</span></div>
 <div class="listrow">{ic("insights",22,"var(--primary)")}<div class="lbl">Replay and GPX</div><span class="chev">{ic("chev",20)}</span></div>
</div>
</div><div class="gesture"></div>'''
page_x('trip', trip)
print('extra ok')
