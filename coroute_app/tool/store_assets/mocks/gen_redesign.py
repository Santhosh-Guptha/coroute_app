"""Generates self-contained HTML mocks of the v3.58 CoRoute screens (no external hosts).
Theme: append #light to the URL (default dark). Mirrors the Flutter layouts in lib/presentation."""
import base64, math, os, random, sys

OUT = sys.argv[1]
HERE = os.path.dirname(os.path.abspath(__file__))
FONT = base64.b64encode(open('/home/claude/app/assets/fonts/Manrope-Variable.ttf', 'rb').read()).decode()
LOGO = base64.b64encode(open(os.path.join(HERE, 'logo152.png'), 'rb').read()).decode()
# v3.58 helmet wordmark (currentColor, from tool/brand/build_brand.py)
WORDMARK = open(os.path.join(HERE, '..', '..', '..', 'docs', 'brand', 'svg', 'coroute-wordmark-currentcolor.svg')).read().replace('<svg ', '<svg style="height:30px;width:auto;display:block;color:var(--text)" ', 1)

CSS = """
@font-face{font-family:Manrope;src:url(data:font/ttf;base64,%FONT%) format('truetype');font-weight:200 800}
:root{--bg:#15181C;--surface:#1C2026;--alt:#242932;--border:#2F3540;--border2:#3E4652;--text:#E7E3DC;--muted:#A7A39B;--faint:#7C7A75;
--primary:#5FB3C4;--onp:#0E1A1D;--psoft:#1F3A40;--pfill:#29707E;--accent:#E9A55B;--asoft:#3A2C1D;--astrong:#E9A55B;--aborder:#5A4228;
--success:#6CC08B;--danger:#E5675C;--sos:#FF5A4E;--hill1:#3a7f8c;--hill2:#1d4f58;--road:rgba(255,255,255,.55);--shadow:rgba(0,0,0,.35)}
html.light{--bg:#F6F4F0;--surface:#FFFFFF;--alt:#EFECE6;--border:#E3DED6;--border2:#CFC8BD;--text:#1F2328;--muted:#5B616B;--faint:#8A8F96;
--primary:#2B7A8C;--onp:#FFFFFF;--psoft:#D7ECEF;--pfill:#2B7A8C;--accent:#D9822B;--asoft:#F7E6D3;--astrong:#94600F;--aborder:#EBCBA6;
--success:#3E8E5E;--danger:#C8463D;--sos:#D93A2F;--hill1:#4a93a2;--hill2:#215e6b;--shadow:rgba(31,35,40,.12)}
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:Manrope,sans-serif;background:var(--bg);color:var(--text);width:412px;min-height:915px;-webkit-font-smoothing:antialiased;overflow-x:hidden}
.status{height:32px;display:flex;align-items:center;justify-content:space-between;padding:0 22px;font-size:13px;font-weight:600;color:var(--text)}
.status .r{display:flex;gap:6px;align-items:center}
.page{padding:12px 20px 120px}
.h-greet{font-size:13px;font-weight:500;color:var(--muted)}
.h-name{font-size:26px;font-weight:600;color:var(--primary);line-height:1.3}
.round{width:48px;height:48px;border-radius:50%;background:var(--surface);border:1px solid var(--border);display:flex;align-items:center;justify-content:center;position:relative;flex:none}
.badge{position:absolute;top:-2px;right:-2px;min-width:18px;height:18px;border-radius:9px;background:var(--sos);color:#fff;font-size:11px;font-weight:700;display:flex;align-items:center;justify-content:center;padding:0 5px}
.row{display:flex;align-items:center}
.gap8{gap:8px}.gap12{gap:12px}
.card{background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:16px}
.tinted{background:var(--psoft);border-color:transparent}
.title{font-size:16px;font-weight:600}
.sec{display:flex;justify-content:space-between;align-items:center;margin:26px 0 10px}
.sec h2{font-size:18px;font-weight:600}
.sec a{font-size:13px;font-weight:600;color:var(--primary);text-decoration:none}
.label{font-size:13px;font-weight:500;color:var(--muted)}
.caption{font-size:12px;color:var(--muted)}
.pill{display:inline-flex;align-items:center;gap:6px;padding:6px 10px;border-radius:999px;background:var(--alt);font-size:12px;font-weight:500;color:var(--muted)}
.pill.ok{color:var(--success)}.pill.warn{color:var(--astrong)}.pill.teal{color:var(--primary);background:var(--psoft)}
.hero{position:relative;border-radius:16px;overflow:hidden;height:196px;flex:none}
.hero .art,.art{position:absolute;inset:0}
.hero .in{position:absolute;inset:0;padding:18px;display:flex;flex-direction:column}
.hero .t{color:#fff;font-size:22px;font-weight:600;line-height:1.25}
.hero .l{color:#D6F0F3;font-size:14px;margin-top:4px;line-height:1.4}
.hero .btn{margin-top:auto;align-self:flex-start;background:#fff;color:#1F2328;border-radius:999px;height:48px;padding:0 18px;display:flex;align-items:center;gap:8px;font-weight:600;font-size:15px}
.scrim{position:absolute;inset:0;background:linear-gradient(180deg,rgba(0,0,0,0) 35%,rgba(0,0,0,.45))}
.dots{display:flex;justify-content:center;gap:6px;margin-top:12px}.dots i{width:6px;height:6px;border-radius:3px;background:var(--border2)}.dots i.on{width:18px;background:var(--primary)}
.emerg{border:1.5px solid var(--sos);color:var(--sos);border-radius:999px;height:44px;padding:0 14px;display:flex;align-items:center;gap:6px;font-weight:700;font-size:14px}
.nudge{background:var(--asoft);border:1px solid var(--aborder);border-radius:14px;padding:8px 6px 8px 14px;display:flex;align-items:center;gap:10px;margin-top:12px;font-size:14px}
.nudge b{color:var(--astrong);font-weight:700;padding:0 10px}
.rail{display:flex;gap:12px;overflow:hidden;margin-right:-20px}
.ccard{width:220px;flex:none;background:var(--surface);border:1px solid var(--border);border-radius:14px;padding:12px;display:flex;flex-direction:column;height:214px}
.ccard.dash{border:1.5px dashed var(--border2)}
.ccard .media{height:78px;border-radius:12px;position:relative;overflow:hidden;display:flex;align-items:center;justify-content:center}
.ccard .ico{width:44px;height:44px;border-radius:50%;background:rgba(255,255,255,.92);display:flex;align-items:center;justify-content:center;position:relative}
.ccard .meta{font-size:12px;color:var(--muted);margin-top:10px}
.ccard .name{font-size:15px;font-weight:600;margin-top:2px;line-height:1.3}
.obtn{margin-top:auto;height:44px;border:1px solid var(--border2);border-radius:999px;display:flex;align-items:center;justify-content:center;font-weight:600;font-size:14px}
.stats{display:flex}.stats div{flex:1;text-align:center;padding:8px 0}.stats b{display:block;font-size:22px;font-weight:700}
.listrow{display:flex;align-items:center;gap:12px;min-height:52px;border-bottom:1px solid var(--border)}
.listrow:last-child{border-bottom:none}
.listrow .lbl{flex:1;font-size:15px;font-weight:500}
.listrow .val{font-size:14px;font-weight:600;color:var(--primary)}
.chev{color:var(--muted)}
.nav{position:fixed;left:0;right:0;bottom:0;width:412px;background:var(--surface);border-top:1px solid var(--border);height:92px;padding-bottom:24px;display:flex}
.nav .it{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;font-size:12px;font-weight:500;color:var(--muted);gap:4px;position:relative}
.nav .it.on{color:var(--primary);font-weight:600}
.nav .it.on:before{content:'';position:absolute;top:8px;width:24px;height:3px;border-radius:2px;background:var(--primary)}
.nav .plus{flex:1;display:flex;align-items:center;justify-content:center}
.nav .plus span{width:56px;height:56px;border-radius:50%;background:var(--primary);display:flex;align-items:center;justify-content:center;box-shadow:0 4px 16px var(--shadow)}
.gesture{position:fixed;bottom:8px;left:50%;transform:translateX(-50%);width:120px;height:4px;border-radius:2px;background:var(--text);opacity:.6}
.search{flex:1;height:56px;border-radius:12px;background:var(--surface);border:1px solid var(--border);display:flex;align-items:center;gap:10px;padding:0 14px;color:var(--faint);font-size:15px}
.fbtn{height:56px;padding:0 18px;border-radius:12px;background:var(--primary);color:var(--onp);display:flex;align-items:center;gap:6px;font-weight:600;font-size:15px}
.chip{height:44px;padding:0 16px;border-radius:999px;border:1px solid var(--border2);background:var(--surface);display:flex;align-items:center;gap:6px;font-size:14px;font-weight:500;color:var(--muted);flex:none}
.chip.on{background:var(--psoft);border:1.5px solid var(--primary);color:var(--text);font-weight:600}
.chips{display:flex;gap:8px;overflow:hidden;margin-right:-20px}
.rank{width:34px;height:34px;border-radius:50%;background:#fff;color:#29707E;font-weight:700;display:flex;align-items:center;justify-content:center}
.tag{background:rgba(0,0,0,.38);color:#fff;border-radius:999px;padding:7px 12px;font-size:13px;font-weight:500;display:flex;gap:6px;align-items:center}
.drow{display:flex;align-items:center;gap:12px;padding:10px 0;border-bottom:1px solid var(--border);min-height:84px}
.drow:last-child{border-bottom:none}
.drow .n{width:28px;text-align:center;font-size:16px;font-weight:600;color:var(--muted)}
.thumb{width:64px;height:64px;border-radius:12px;overflow:hidden;position:relative;flex:none}
.btn{height:52px;border-radius:12px;display:flex;align-items:center;justify-content:center;gap:8px;font-weight:600;font-size:15px}
.btn.p{background:var(--primary);color:var(--onp)}.btn.o{background:var(--surface);border:1px solid var(--border2);color:var(--text)}
.btn.big{height:56px;font-size:16px}
.check{display:flex;align-items:center;gap:12px;min-height:48px;font-size:15px}
.check .c{width:24px;height:24px;border-radius:50%;border:2px solid var(--border2);flex:none}
.check.done{color:var(--muted);text-decoration:line-through}
.check.done .c{border:none;background:var(--success);display:flex;align-items:center;justify-content:center}
.bar{height:8px;border-radius:4px;background:var(--alt);overflow:hidden}.bar i{display:block;height:100%;background:var(--primary)}
.srow{display:flex;align-items:center;gap:12px;min-height:56px;border-bottom:1px solid var(--border)}
.srow:last-child{border-bottom:none}
.srow .t{flex:1}.srow .t b{display:block;font-size:15px;font-weight:600}.srow .t span{font-size:12px;color:var(--muted)}
.sheet-h{font-size:28px;font-weight:600;margin:6px 0 12px}
svg{flex:none}
"""

ICONS = {
 'home':'<path d="M3 10.5 12 3l9 7.5V20a1 1 0 0 1-1 1h-5v-6H9v6H4a1 1 0 0 1-1-1z"/>',
 'compass':'<circle cx="12" cy="12" r="9"/><path d="m15.5 8.5-2 5-5 2 2-5z"/>',
 'groups':'<circle cx="9" cy="8" r="3.2"/><path d="M3 19c.6-3.2 3-5 6-5s5.4 1.8 6 5"/><circle cx="17" cy="9" r="2.5"/><path d="M16 14.2c2.4.2 4.3 1.8 5 4.8"/>',
 'chat':'<path d="M4 5h16v11H9l-5 4z"/>',
 'plus':'<path d="M12 5v14M5 12h14"/>',
 'bell':'<path d="M6 16V11a6 6 0 0 1 12 0v5l2 2H4z"/><path d="M10 20a2 2 0 0 0 4 0"/>',
 'sun':'<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
 'moon':'<path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z"/>',
 'search':'<circle cx="11" cy="11" r="7"/><path d="m20 20-4-4"/>',
 'chev':'<path d="m9 6 6 6-6 6"/>',
 'back':'<path d="m15 6-6 6 6 6"/>',
 'shield':'<path d="M12 3 4 6v6c0 5 3.5 8 8 9 4.5-1 8-4 8-9V6z"/>',
 'crash':'<path d="M5 16h14M6 16l1.5-5h9L18 16"/><circle cx="8" cy="17.5" r="1.6"/><circle cx="16" cy="17.5" r="1.6"/><path d="M12 3v4M8.5 4.5l1.5 2.5M15.5 4.5 14 7"/>',
 'phone':'<path d="M5 4h4l2 5-2.5 1.5a11 11 0 0 0 5 5L15 13l5 2v4a1 1 0 0 1-1 1A16 16 0 0 1 4 5a1 1 0 0 1 1-1z"/>',
 'sms':'<path d="M4 5h16v11H9l-5 4z"/><path d="M8 10h.01M12 10h.01M16 10h.01"/>',
 'bt':'<path d="m7 7 10 10-5 4V3l5 4L7 17"/>',
 'close':'<path d="M6 6l12 12M18 6 6 18"/>',
 'flag':'<path d="M5 21V4h11l-2 4 2 4H5"/>',
 'trophy':'<path d="M8 4h8v5a4 4 0 0 1-8 0z"/><path d="M8 6H5a3 3 0 0 0 3 4M16 6h3a3 3 0 0 1-3 4M12 13v4M8 20h8"/>',
 'mail':'<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m3 7 9 6 9-6"/>',
 'bike':'<circle cx="6" cy="16" r="3.5"/><circle cx="18" cy="16" r="3.5"/><path d="M6 16l4-6h5l3 6M10 10 8.5 7H6M15 10l1-3h2"/>',
 'gear':'<circle cx="12" cy="12" r="3"/><path d="M12 2.5v3M12 18.5v3M21.5 12h-3M5.5 12h-3M18.7 5.3l-2.1 2.1M7.4 16.6l-2.1 2.1M18.7 18.7l-2.1-2.1M7.4 7.4 5.3 5.3"/>',
 'camera':'<path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/>',
 'map':'<path d="M3 6l6-2 6 2 6-2v14l-6 2-6-2-6 2z"/><path d="M9 4v14M15 6v14"/>',
 'user':'<circle cx="12" cy="8" r="4"/><path d="M4 21c1-4.5 4.2-6.5 8-6.5s7 2 8 6.5"/>',
 'contrast':'<circle cx="12" cy="12" r="9"/><path d="M12 3v18a9 9 0 0 0 0-18z" fill="currentColor"/>',
 'lock':'<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>',
 'share':'<circle cx="18" cy="5" r="2.5"/><circle cx="6" cy="12" r="2.5"/><circle cx="18" cy="19" r="2.5"/><path d="m8.2 10.8 7.6-4.6M8.2 13.2l7.6 4.6"/>',
 'star':'<path d="m12 3 2.8 5.8 6.2.9-4.5 4.4 1 6.2L12 17.4l-5.5 2.9 1-6.2L3 9.7l6.2-.9z"/>',
 'help':'<circle cx="12" cy="12" r="9"/><path d="M9.5 9.5a2.5 2.5 0 1 1 3.5 2.3c-.7.3-1 .9-1 1.7M12 17h.01"/>',
 'tune':'<path d="M4 7h10M18 7h2M4 17h4M12 17h8"/><circle cx="16" cy="7" r="2"/><circle cx="10" cy="17" r="2"/>',
 'logout':'<path d="M14 4h5v16h-5M10 8l-4 4 4 4M6 12h10"/>',
 'trash':'<path d="M5 7h14M10 7V4h4v3M7 7l1 13h8l1-13"/>',
 'check':'<path d="m5 12 4 4 10-10"/>',
 'route':'<circle cx="6" cy="18" r="2.5"/><circle cx="18" cy="6" r="2.5"/><path d="M8.5 18H15a3 3 0 0 0 0-6H9a3 3 0 0 1 0-6h6.5"/>',
 'coffee':'<path d="M4 9h12v6a5 5 0 0 1-5 5H9a5 5 0 0 1-5-5z"/><path d="M16 11h2a2 2 0 0 1 0 4h-2M8 3v3M12 3v3"/>',
 'bed':'<path d="M3 18V7M3 13h18v5M21 13a4 4 0 0 0-4-4h-6v4"/><circle cx="7" cy="10.5" r="1.5"/>',
 'turn':'<path d="M6 20V10a4 4 0 0 1 4-4h8M15 3l3 3-3 3"/>',
 'mountain':'<path d="M3 19 9.5 8l3.5 6 2-3 6 8z"/>',
 'nav':'<path d="m12 3 7 18-7-4-7 4z"/>',
 'warn':'<path d="M12 3 2 20h20z"/><path d="M12 10v4M12 17h.01"/>',
 'road':'<path d="M8 3 4 21M16 3l4 18M12 4v3M12 10v3M12 16v3"/>',
 'clock':'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
 'fuel':'<path d="M5 20V5a1 1 0 0 1 1-1h7a1 1 0 0 1 1 1v15M4 20h11M14 9h2l2 2v6a1.5 1.5 0 0 0 3 0V8l-3-3"/><path d="M7 8h5"/>',
 'info':'<circle cx="12" cy="12" r="9"/><path d="M12 11v6M12 7h.01"/>',
 'key':'<circle cx="8" cy="15" r="4"/><path d="m11 12 9-9M17 6l2 2M15 8l2 2"/>',
 'forum':'<path d="M3 4h12v9H7l-4 3z"/><path d="M9 16h8l4 3V8h-3"/>',
 'nosignal':'<path d="M4 20h2v-3H4zM9 20h2v-6H9zM14 20h2V10h-2zM19 20h2V6h-2z"/><path d="M3 3l18 18"/>',
 'qr':'<rect x="4" y="4" width="6" height="6"/><rect x="14" y="4" width="6" height="6"/><rect x="4" y="14" width="6" height="6"/><path d="M14 14h2v2h-2zM18 18h2v2h-2zM14 18h2M18 14h2"/>',
 'pluscircle':'<circle cx="12" cy="12" r="9"/><path d="M12 8v8M8 12h8"/>',
 'insights':'<path d="M4 19 9 13l4 3 7-9"/><circle cx="20" cy="7" r="1.5"/>',
 'play':'<path d="M7 5v14l11-7z"/>',
 'health':'<path d="M12 3 4 6v6c0 5 3.5 8 8 9 4.5-1 8-4 8-9V6z"/><path d="M12 9v6M9 12h6"/>',
 'heart':'<path d="M12 20s-7-4.5-7-10a4 4 0 0 1 7-2.5A4 4 0 0 1 19 10c0 5.5-7 10-7 10z"/>',
 'speed':'<path d="M4 16a8 8 0 1 1 16 0"/><path d="m12 16 4-5"/>',
 'pin':'<path d="M12 21s-6-5.5-6-11a6 6 0 0 1 12 0c0 5.5-6 11-6 11z"/><circle cx="12" cy="10" r="2.2"/>',
 'inbox':'<path d="M4 13 6 5h12l2 8v6H4z"/><path d="M4 13h5l1 2h4l1-2h5"/>',
 'vote':'<rect x="4" y="11" width="16" height="9" rx="1"/><path d="m8 9 3 3 5-6"/>',
 'event':'<rect x="4" y="5" width="16" height="15" rx="2"/><path d="M4 10h16M9 3v4M15 3v4"/>',
 'sos':'<circle cx="12" cy="12" r="9.5"/><text x="12" y="15.3" text-anchor="middle" font-size="8.5" font-weight="800" font-family="Manrope" fill="currentColor" stroke="none">SOS</text>',
 'arrow':'<path d="M5 12h14M13 6l6 6-6 6"/>',
 'emergency':'<path d="M12 4v16M4 12h16"/><circle cx="12" cy="12" r="9"/>',
 'person':'<circle cx="12" cy="8" r="3.5"/><path d="M5 20c.8-3.8 3.6-5.8 7-5.8s6.2 2 7 5.8"/>',
 'location':'<path d="M12 2v3M12 19v3M2 12h3M19 12h3"/><circle cx="12" cy="12" r="6"/><circle cx="12" cy="12" r="2"/>',
}

def ic(name, size=22, color='currentColor', sw=1.8, fill='none'):
    return f'<svg width="{size}" height="{size}" viewBox="0 0 24 24" fill="{fill}" stroke="{color}" stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round">{ICONS[name]}</svg>'

def art(seed, w, h, night=False, scrim=False, radius=0):
    """Our own flat illustration, same idea as lib/core/ui/place_art.dart."""
    rnd = random.Random(seed)
    sky = 'var(--pfill)'
    orb = '#E9E4D8' if night else 'var(--accent)'
    def hills(base, amp, phase):
        pts = [f'0,{h}', f'0,{h*base:.1f}']
        for i in range(25):
            x = w * i / 24
            y = h*base - math.sin(i/24*math.pi*2+phase)*h*amp - math.sin(i/24*math.pi*5+phase*2)*h*amp*.25
            pts.append(f'{x:.1f},{y:.1f}')
        pts.append(f'{w},{h}')
        return ' '.join(pts)
    ox, oy = w*(0.62+rnd.random()*0.25), h*(0.22+rnd.random()*0.1)
    sx = w*(0.25+rnd.random()*0.2); ex = w*(0.5+rnd.random()*0.15)
    sw = max(2, h*0.035)
    far = 'rgba(255,255,255,.06)' if night else 'rgba(255,255,255,.12)'
    near = 'rgba(0,0,0,.34)' if night else 'rgba(0,0,0,.22)'
    s = f'''<svg class="art" viewBox="0 0 {w} {h}" preserveAspectRatio="none" style="border-radius:{radius}px">
<rect width="{w}" height="{h}" fill="{sky}"/><circle cx="{ox:.1f}" cy="{oy:.1f}" r="{min(w,h)*0.09:.1f}" fill="{orb}" opacity=".9"/>
<polygon points="{hills(0.58,0.12,rnd.random()*6)}" fill="{far}"/><polygon points="{hills(0.74,0.08,rnd.random()*6)}" fill="{near}"/>
<path d="M{sx:.1f},{h*1.02:.1f} C{w*0.75:.1f},{h*0.92:.1f} {w*0.15:.1f},{h*0.82:.1f} {ex:.1f},{h*0.7:.1f}" stroke="rgba(255,255,255,.55)" stroke-width="{sw:.1f}" fill="none" stroke-linecap="round"/></svg>'''
    if scrim:
        s += '<div class="scrim"></div>'
    return s

def status():
    return f'<div class="status"><span>9:41</span><span class="r">{ic("nosignal",15,sw=1.6)}<span style="font-size:12px">5G</span><svg width="22" height="11" viewBox="0 0 22 11"><rect x=".5" y=".5" width="18" height="10" rx="2.5" fill="none" stroke="currentColor"/><rect x="2" y="2" width="13" height="7" rx="1.5" fill="currentColor"/><rect x="19.5" y="3.5" width="2" height="4" rx="1" fill="currentColor"/></svg></span></div>'

def nav(on):
    items = [('home','Home'),('compass','Explore'),None,('groups','Community'),('chat','Chat')]
    out = '<div class="nav">'
    for it in items:
        if it is None:
            out += f'<div class="plus"><span>{ic("plus",30,"var(--onp)",2.4)}</span></div>'
            continue
        k, l = it
        badge = '<span class="badge" style="top:-6px;right:-10px">2</span>' if l == 'Community' else ''
        out += f'<div class="it {"on" if l==on else ""}"><span style="position:relative">{ic(k,24)}{badge}</span>{l}</div>'
    return out + '</div><div class="gesture"></div>'

def page(name, body, navon=None):
    html = f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=412">
<title>CoRoute mock: {name}</title><style>{CSS.replace("%FONT%", FONT)}</style>
<script>if(location.hash==='#light')document.documentElement.classList.add('light')</script></head>
<body>{status()}{body}{nav(navon) if navon else ''}</body></html>'''
    open(os.path.join(OUT, f'{name}.html'), 'w').write(html)

# ------------------------------------------------------------------ Home
def comm_card(title, meta, icon, action, seed, dash=False):
    media = (f'<div class="media" style="background:var(--psoft)">{ic(icon,34,"var(--primary)")}</div>' if dash else
             f'<div class="media">{art(seed,196,78)}<div class="ico">{ic(icon,24,"#29707E")}</div></div>')
    return f'<div class="ccard {"dash" if dash else ""}">{media}<div class="meta">{meta}</div><div class="name">{title}</div><div class="obtn">{action}</div></div>'

home = f'''<div class="page">
<div class="row gap8" style="align-items:flex-start">
 <div style="flex:1"><div class="h-greet">Good morning</div><div class="h-name">Arjun</div></div>
 <div class="round">{ic("bell",24)}<span class="badge">1</span></div>
 <div class="round">{ic("sun",24)}</div>
 <div class="round" style="background:var(--pfill);border:3px solid var(--primary);color:#fff;font-weight:600">AR</div>
</div>
<div style="display:flex;gap:10px;margin-top:16px;margin-right:-20px">
 <div class="hero" style="width:350px">{art("Savandurga",350,196,scrim=True)}<div class="in"><div class="t">Rides near you</div><div class="l">Nearest: Savandurga · ~45 km</div><div class="btn">{ic("compass",20,"#1F2328")}Find rides</div></div></div>
 <div class="hero" style="width:350px">{art("group",350,196,scrim=True)}<div class="in"><div class="t">Start a group ride</div></div></div>
</div>
<div class="dots"><i class="on"></i><i></i><i></i><i></i></div>
<div class="card" style="margin-top:16px;padding:12px 12px 12px 14px">
 <div class="row gap8">{ic("shield",20,"var(--primary)")}<div style="flex:1;font-size:15px;font-weight:600">Ride safety</div><div class="emerg">{ic("sos",20,"var(--sos)",1.6)}Emergency</div></div>
 <div style="display:flex;flex-wrap:wrap;gap:8px;margin-top:10px">
  <span class="pill ok">{ic("crash",16)}Crash detection on</span><span class="pill warn">{ic("info",16)}No emergency contact</span>
  <span class="pill ok">{ic("sms",16)}SOS works without data</span><span class="pill ok">{ic("bt",16)}Offline link ready</span></div>
</div>
<div class="nudge">{ic("health",22,"var(--astrong)")}<div style="flex:1">Add an emergency contact. SOS texts them first.</div><b>Add</b>{ic("close",20,"var(--muted)")}</div>
<div class="sec"><h2>Riding communities</h2><a>See all</a></div>
<div class="rail">{comm_card("Deccan Touring Club","Bengaluru · Club invite","flag","Accept","Deccan")}{comm_card("Sunday Sunrise Crew","8 members · 1 open poll","groups","Open","Sunrise")}{comm_card("Join a club","Have a club link or code?","qr","Join with code","", True)}</div>
<div class="sec"><h2>Your ride stats</h2><a>Full view</a></div>
<div class="card" style="padding:8px 8px 4px">
 <div class="stats"><div><b>1.2k</b><span class="caption">km ridden</span></div><div><b>14</b><span class="caption">rides</span></div><div><b>82</b><span class="caption">rider score</span></div></div>
 <div style="border-top:1px solid var(--border);display:flex;align-items:center;gap:10px;min-height:52px;padding:0 10px">{ic("trophy",22,"var(--accent)")}<div style="flex:1;font-weight:600">Leaderboard</div><span class="label">All India · #318</span><span class="chev">{ic("chev",20)}</span></div>
</div>
<div class="sec"><h2>Upcoming</h2></div>
<div class="card" style="padding:4px 14px">
 <div class="listrow">{ic("mail",22,"var(--primary)")}<div class="lbl">Nandi sunrise run</div><div class="val">Tomorrow 05:15</div><span class="chev">{ic("chev",20)}</span></div>
 <div class="listrow">{ic("event",22,"var(--primary)")}<div class="lbl">Club ride: Coorg weekend</div><div class="val">Sat 21 Nov</div><span class="chev">{ic("chev",20)}</span></div>
</div>
<div class="sec"><h2>Bike status</h2></div>
<div class="card" style="padding:4px 16px">
 <div class="listrow">{ic("fuel",22,"var(--primary)")}<div class="lbl">Usable range</div><div class="val">212 km</div></div>
 <div class="listrow">{ic("shield",22,"var(--primary)")}<div class="lbl">Crash detection</div><div class="val">On</div></div>
 <div class="listrow">{ic("bike",22,"var(--primary)")}<div class="lbl">Garage</div><div class="val">My bikes &amp; service</div><span class="chev">{ic("chev",20)}</span></div>
</div></div>'''
page('home', home, 'Home')

# ------------------------------------------------------------------ Explore
places = [('Savandurga','breakfast','coffee','Breakfast','~45 km','1 h'),('Nandi Hills','breakfast','coffee','Breakfast','~60 km','1.5 h'),
          ('Lepakshi','one_day','sun','One day','~120 km','2.5 h'),('Horsley Hills','one_day','turn','One day','~150 km','3.5 h'),
          ('Mysuru Palace','night','moon','Night','~165 km','3.5 h'),('Yercaud','one_day','mountain','One day','~260 km','6 h')]
rows = ''.join(f'<div class="drow"><div class="n">{i+2}</div><div class="thumb">{art(p[0],64,64,night=p[1]=="night")}</div><div style="flex:1"><div class="title">{p[0]}</div><div class="label row gap8" style="gap:4px;margin-top:2px">{ic(p[2],15,"var(--muted)")}{p[3]} · {p[4]} · {p[5]}</div></div><span class="chev">{ic("chev",22)}</span></div>' for i,p in enumerate(places[1:]))
explore = f'''<div class="page" style="padding-top:16px">
<div style="font-size:28px;font-weight:600">Explore</div>
<div class="row gap8" style="margin-top:12px"><div class="search">{ic("search",22,"var(--muted)")}Search places</div><div class="fbtn">{ic("plus",22,"var(--onp)",2.2)}Add</div></div>
<div style="font-size:18px;font-weight:600;margin-top:24px">Rides near you</div>
<div class="label" style="margin-top:2px">Nearest first, worked out on your phone</div>
<div class="chips" style="margin-top:12px"><div class="chip on">All</div><div class="chip">{ic("coffee",18)}Breakfast</div><div class="chip">{ic("moon",18)}Night</div><div class="chip">{ic("sun",18)}One day</div><div class="chip">{ic("bed",18)}Weekend</div><div class="chip">{ic("turn",18)}Twisty roads</div><div class="chip">{ic("mountain",18)}Ghats</div></div>
<div class="hero" style="height:230px;margin-top:16px">{art("Savandurga",372,230,scrim=True)}
 <div style="position:absolute;left:14px;top:14px;display:flex;gap:8px"><div class="rank">1</div><div class="tag">{ic("coffee",16,"#fff")}Breakfast ride</div></div>
 <div style="position:absolute;left:16px;right:16px;bottom:14px"><div style="color:#fff;font-size:26px;font-weight:700">Savandurga</div><div style="color:#D6F0F3;font-size:14px;margin-top:4px">Karnataka · ~45 km · 1 h each way</div></div>
</div>
<div class="card" style="margin-top:12px;padding:4px 12px">{rows}</div>
</div>'''
page('explore', explore, 'Explore')

# ------------------------------------------------------------------ Ride detail
def maprect():
    lines = ''.join(f'<path d="M{x},0 L{x+30},190" stroke="var(--border)" stroke-width="1"/>' for x in range(0,420,46))
    lines += ''.join(f'<path d="M0,{y} L372,{y+12}" stroke="var(--border)" stroke-width="1"/>' for y in range(0,200,38))
    return f'''<svg width="372" height="190" viewBox="0 0 372 190" style="display:block;border-radius:14px;background:var(--alt)">{lines}
<path d="M40,60 C110,40 150,140 220,120 S300,90 340,150" stroke="var(--border2)" stroke-width="6" fill="none"/>
<path d="M70,150 L300,48" stroke="var(--primary)" stroke-width="4" stroke-dasharray="12 10" fill="none" stroke-linecap="round"/>
<circle cx="70" cy="150" r="9" fill="var(--primary)" stroke="#fff" stroke-width="3"/>
<g transform="translate(286,14)" fill="var(--accent)"><path d="M14 34s-12-11-12-21a12 12 0 0 1 24 0c0 10-12 21-12 21z"/><circle cx="14" cy="13" r="4.5" fill="#fff"/></g></svg>'''
intel = [('warn','Hazard hotspots','3 (1 high)',True),('road','Rough road','2 stretches',False),('turn','Twistiness','64/100 · ghat',False),
         ('coffee','Where riders stop','Nandi foothills tea stall, Fuel stop',False),('fuel','Fuel','The planner checks fuel gaps on your route',False),
         ('clock','Risky times','Weekends 06:00-08:00: more hard braking here',True)]
irows = ''.join(f'<div class="listrow" style="align-items:flex-start;padding:8px 0">{ic(r[0],22,"var(--astrong)" if r[3] else "var(--primary)")}<div style="flex:1"><div style="font-weight:600;font-size:15px">{r[1]}</div><div class="label" style="color:{"var(--astrong)" if r[3] else "var(--muted)"}">{r[2]}</div></div></div>' for r in intel)
detail = f'''<div style="position:relative;height:272px;margin-top:-32px">{art("Nandi Hills",412,272,scrim=True)}
 <div class="round" style="position:absolute;left:16px;top:40px">{ic("back",24)}</div>
 <div style="position:absolute;left:20px;bottom:18px"><div style="color:#fff;font-size:28px;font-weight:700">Nandi Hills</div><div style="color:#D6F0F3;font-size:15px">Karnataka</div></div></div>
<div class="page" style="padding-top:16px;padding-bottom:190px">
<div style="display:flex;flex-wrap:wrap;gap:8px"><span class="pill teal">{ic("coffee",16)}Breakfast ride</span><span class="pill">{ic("turn",16)}Twisty roads</span><span class="pill">{ic("route",16)}~60 km · 1.5 h each way</span></div>
<div class="sec"><h2>Route preview</h2></div>{maprect()}
<div class="caption" style="margin-top:6px">Straight guide line from you. The planner and your maps app find the road; ~km is an estimate.</div>
<div class="sec" style="margin-bottom:2px"><h2>Road intel on the way</h2></div>
<div class="caption" style="margin-bottom:8px">From CoRoute riders, anonymous and only where enough riders passed.</div>
<div class="card" style="padding:4px 14px">{irows}</div>
<div class="card tinted row gap12" style="margin-top:24px">{ic("shield",24,"var(--primary)")}<div class="label" style="color:var(--text)">On this ride: crash detection, SOS that works without data, hazard and twisty-road warnings, and a live link your family can follow.</div></div>
</div>
<div style="position:fixed;left:0;right:0;bottom:0;width:412px;background:var(--bg);border-top:1px solid var(--border);padding:12px 20px 28px">
 <div class="row gap8"><div class="btn o" style="flex:1">{ic("person",20)}Ride solo</div><div class="btn p" style="flex:1">{ic("groups",20,"var(--onp)")}Plan group ride</div></div>
 <div class="row" style="justify-content:center;gap:8px;height:48px;color:var(--primary);font-weight:600;margin-top:4px">{ic("nav",20,"var(--primary)")}Navigate in your maps app</div></div><div class="gesture"></div>'''
page('ride_detail', detail)

# ------------------------------------------------------------------ Community
avatars = ''.join(f'<div style="width:64px;text-align:center"><div style="width:56px;height:56px;border-radius:50%;margin:0 auto;background:var(--{c});display:flex;align-items:center;justify-content:center;color:#fff;font-weight:600">{i}</div><div class="caption" style="color:var(--text);margin-top:6px">{n}</div></div>' for i,n,c in [('KR','Kiran','pfill'),('MS','Meera','accent'),('DV','Dev','pfill'),('AS','Asha','accent'),('RV','Ravi','pfill')])
community = f'''<div class="page" style="padding-top:16px">
<div class="row"><div style="flex:1;font-size:28px;font-weight:600">Community</div><div class="round">{ic("share",22)}</div></div>
<div class="search" style="margin-top:12px;height:52px">{ic("search",22,"var(--muted)")}Search riders by username</div>
<div class="card tinted row gap12" style="margin-top:12px">{ic("inbox",24,"var(--primary)")}<div style="flex:1;font-weight:600;font-size:15px">2 requests are waiting</div><span class="chev">{ic("chev",22)}</span></div>
<div class="sec"><h2>Crews and clubs</h2><a>See all</a></div>
<div class="rail">{comm_card("Sunday Sunrise Crew","8 members · 1 open poll","groups","Open","Sunrise")}{comm_card("Ghat Riders BLR","23 members","groups","Open","Ghat")}{comm_card("Start a crew","Your riding friends, polls and group rides","pluscircle","Create","",True)}</div>
<div class="sec"><h2>Ride better together</h2></div>
<div class="card row gap12"><svg width="64" height="64" viewBox="0 0 64 64"><circle cx="32" cy="32" r="27" stroke="var(--alt)" stroke-width="7" fill="none"/><circle cx="32" cy="32" r="27" stroke="var(--primary)" stroke-width="7" fill="none" stroke-dasharray="{2*math.pi*27*0.82:.1f} 200" transform="rotate(-90 32 32)" stroke-linecap="round"/><text x="32" y="38" text-anchor="middle" font-size="18" font-weight="700" fill="var(--text)" font-family="Manrope">82</text></svg><div style="flex:1"><div class="title">Your rider score</div><div class="label">Steady · tap for tips</div></div><span class="chev">{ic("chev",22)}</span></div>
<div class="card row gap12" style="margin-top:12px">{ic("trophy",24,"var(--accent)")}<div style="flex:1"><div style="font-weight:600;font-size:15px">Leaderboard</div><div class="caption">Top riders by score, km, hours and rides</div></div><span class="chev">{ic("chev",22)}</span></div>
<div class="sec"><h2>Friends</h2><a>All friends</a></div>
<div class="row" style="gap:12px">{avatars}</div>
<div class="card row gap12" style="margin-top:12px">{ic("bike",24,"var(--primary)")}<div style="flex:1;font-weight:600;font-size:15px">4 riders you rode with</div><span class="chev">{ic("chev",22)}</span></div>
</div>'''
page('community', community, 'Community')

# ------------------------------------------------------------------ Chat
chat = f'''<div class="page" style="padding-top:16px">
<div style="font-size:28px;font-weight:600">Chat</div>
<div class="sec" style="margin-top:16px"><h2>Live ride</h2></div>
<div class="card" style="border-color:var(--primary)">
 <div class="row gap8">{ic("forum",22,"var(--primary)")}<div class="title" style="flex:1">Nandi sunrise run</div><span class="badge" style="position:static">3</span></div>
 <div class="label" style="color:var(--text);margin-top:8px">Kiran: Fuel stop at the next pump</div>
 <div class="label" style="color:var(--text);margin-top:2px">Meera: Wait for me (2 min)</div>
 <div class="label" style="color:var(--primary);font-weight:600;margin-top:8px">Open on the ride screen</div></div>
<div class="sec" style="margin-bottom:2px"><h2>Recent rides</h2></div>
<div class="caption" style="margin-bottom:8px">Kept on this phone for your last 10 rides. Read only.</div>
<div class="card" style="padding:4px 14px">
{''.join(f'<div class="listrow" style="min-height:68px"><div style="width:44px;height:44px;border-radius:50%;background:var(--psoft);display:flex;align-items:center;justify-content:center">{ic("bike",22,"var(--primary)")}</div><div style="flex:1"><div style="font-weight:600;font-size:15px">{t}</div><div class="label">{m}</div></div><span class="caption">{c}</span><span class="chev">{ic("chev",20)}</span></div>' for t,m,c in [('Coorg weekend · 8 Nov','Dev: Reached the homestay, all good','86'),('Savandurga breakfast · 2 Nov','Asha: I\'m OK','24'),('Lepakshi day out · 26 Oct','Ravi: Regroup here','41')])}
</div>
<div class="card tinted row gap12" style="margin-top:24px">{ic("groups",24,"var(--primary)")}<div class="label" style="color:var(--text)">Crews plan in polls. Start a ride with your crew to chat live.</div></div>
</div>'''
page('chat', chat, 'Chat')

# ------------------------------------------------------------------ Profile
checks = [('Add an emergency contact',True,True),('Add your Medical ID',False,True),('Add your bike',True,False),('Allow Nearby devices (SOS without signal)',False,True),('Run the pre-ride phone check',True,True),('Add a profile picture',False,False),('Pick your riding interests',False,False)]
crow = ''.join(f'<div class="check {"done" if d else ""}"><span class="c">{ic("check",16,"#fff",2.6) if d else ""}</span><span style="flex:1">{t}</span>{"" if d else (ic("shield",18,"var(--primary)") if s else "")}{"" if d else ic("chev",20,"var(--muted)")}</div>' for t,d,s in checks)
srows = [('map','My trips',''),('user','Account','Name, phone and vehicle'),('bell','Notifications',''),('contrast','Theme','System'),('phone','Emergency contact &amp; Medical ID','Meera · No Medical ID'),('lock','Privacy &amp; terms',''),('share','Invite friends',''),('star','Rate CoRoute',''),('help','Send feedback','Help &amp; support'),('trophy','Leaderboard',''),('tune','Advanced','All settings')]
srow = ''.join(f'<div class="srow">{ic(i,22,"var(--primary)")}<div class="t"><b>{t}</b>{f"<span>{s}</span>" if s else ""}</div><span class="chev">{ic("chev",20)}</span></div>' for i,t,s in srows)
profile = f'''<div style="position:relative;height:234px;margin-top:-32px">
 <div style="position:absolute;left:0;right:0;top:0;height:182px">{art("Arjun Rao",412,182)}
  <div style="position:absolute;left:50%;top:66px;transform:translateX(-50%);background:rgba(0,0,0,.35);color:#fff;border-radius:999px;padding:10px 14px;display:flex;gap:8px;font-weight:600;font-size:14px">{ic("camera",18,"#fff")}Add a cover photo</div></div>
 <div class="round" style="position:absolute;left:16px;top:40px">{ic("back",24)}</div>
 <div class="round" style="position:absolute;right:16px;top:40px">{ic("gear",22)}</div>
 <div style="position:absolute;left:50%;top:130px;transform:translateX(-50%);width:112px;height:112px;border-radius:50%;border:4px solid var(--bg);background:var(--pfill);display:flex;align-items:center;justify-content:center;color:#fff;font-size:34px;font-weight:600;box-shadow:inset 0 0 0 3px var(--primary)">AR</div>
</div>
<div style="text-align:center;margin-top:20px"><div style="font-size:24px;font-weight:600">Arjun Rao</div><div class="label">@arjun_rides</div><div class="caption" style="margin-top:2px">Riding since Nov 2026</div></div>
<div class="page" style="padding-top:16px">
<div class="card"><div class="row"><div class="title" style="flex:1">Complete your riding profile</div><span class="label">3 of 7 done</span></div>
 <div class="caption" style="margin:4px 0 10px">Safety first: these help riders and responders reach you.</div><div class="bar"><i style="width:43%"></i></div><div style="margin-top:6px">{crow}</div></div>
<div class="card" style="margin-top:16px;padding:12px 16px 4px"><div class="row"><div class="title" style="flex:1">My preferences</div><span style="color:var(--primary);font-weight:600;font-size:14px;padding:12px 8px">Edit</span></div>
 <div style="display:flex;flex-wrap:wrap;gap:8px;margin-bottom:8px"><span class="pill teal">{ic("speed",16)}Touring</span><span class="pill">{ic("heart",16)}Breakfast rides</span><span class="pill">{ic("heart",16)}Ghats</span></div>
 <div class="listrow" style="border:none">{ic("bike",22,"var(--primary)")}<div class="lbl">My bikes</div><div class="val">Himalayan 450</div><span class="chev">{ic("chev",20)}</span></div></div>
<div class="sec"><h2>My rides</h2><a>All trips</a></div>
<div class="card" style="padding:4px 16px">
 <div class="listrow">{ic("mail",22,"var(--primary)")}<div class="lbl">Nandi sunrise run</div><div class="val">Invite</div><span class="chev">{ic("chev",20)}</span></div>
 <div class="listrow">{ic("route",22,"var(--primary)")}<div class="lbl">Coorg weekend</div><div class="val">512 km</div><span class="chev">{ic("chev",20)}</span></div>
 <div class="listrow">{ic("route",22,"var(--primary)")}<div class="lbl">Savandurga breakfast</div><div class="val">96 km</div><span class="chev">{ic("chev",20)}</span></div></div>
<div class="sec"><h2>Settings &amp; info</h2></div>
<div class="card" style="padding:4px 16px">{srow}</div>
<div class="card" style="padding:4px 16px;margin-top:24px">
 <div class="srow" style="color:var(--danger)">{ic("logout",22,"var(--danger)")}<div class="t"><b>Sign out</b></div></div>
 <div class="srow" style="color:var(--sos)">{ic("trash",22,"var(--sos)")}<div class="t"><b>Delete account</b></div></div></div>
<div class="caption" style="text-align:center;margin-top:24px">CoRoute 3.55.0 (build 10029)</div><div class="caption" style="text-align:center">Ride together. Stay safe.</div>
</div>'''
page('profile', profile)

# ------------------------------------------------------------------ Welcome
welcome = f'''<div style="position:absolute;inset:0;background:linear-gradient(180deg,var(--psoft),var(--bg) 50%);z-index:-1"></div>
<div style="padding:64px 24px 0;min-height:860px;display:flex;flex-direction:column">
<img src="data:image/png;base64,{LOGO}" width="76" height="76" style="border-radius:20px" alt="CoRoute">
<div style="margin-top:16px">{WORDMARK}</div>
<div style="font-size:38px;font-weight:700;line-height:1.15;margin-top:32px">Ride together.<br><span style="color:var(--primary)">Stay safe.</span></div>
<div style="font-size:16px;color:var(--muted);margin-top:16px;line-height:1.45">Crash detection, SOS that works without signal, live group tracking and helmet intercom. In one app.</div>
<div style="display:flex;flex-wrap:wrap;gap:8px;margin-top:24px"><span class="pill">{ic("crash",16)}Crash detection</span><span class="pill">{ic("nosignal",16)}SOS without signal</span><span class="pill">{ic("phone",16)}Helmet intercom</span><span class="pill">{ic("location",16)}Live link for family</span></div>
<div style="margin-top:auto"></div>
<div class="btn p big">Get started{ic("arrow",22,"var(--onp)")}</div>
<div class="btn o big" style="margin-top:12px;font-size:15px">I already have an account</div>
<div class="row" style="justify-content:center;gap:8px;height:48px;color:var(--sos);font-weight:600;margin-top:8px">{ic("emergency",22,"var(--sos)")}Emergency? Call 112</div>
</div><div class="gesture"></div>'''
page('welcome', welcome)
print('ok')
