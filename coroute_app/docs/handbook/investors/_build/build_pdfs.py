"""Renders one_pager.pdf and investor_memo.pdf from this folder's Markdown/HTML with Chromium (Playwright).

Run: python3 docs/handbook/investors/_build/build_pdfs.py
"""
import os
import re
import markdown
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                      # docs/handbook/investors
FONT = os.path.abspath(os.path.join(ROOT, '..', '..', '..', 'assets', 'fonts', 'Manrope-Variable.ttf'))

BASE_CSS = f"""
@font-face {{ font-family: 'Manrope'; src: url('file://{FONT}') format('truetype'); font-weight: 200 800; }}
:root {{ --teal:#2B7A8C; --teal-soft:#D7ECEF; --amber:#D9822B; --amber-soft:#F7E6D3; --amber-text:#94600F;
  --bg:#F6F4F0; --surface:#FFFFFF; --alt:#EFECE6; --border:#E3DED6; --text:#1F2328; --muted:#5B616B; --sos:#D93A2F; }}
* {{ box-sizing: border-box; }}
html, body {{ margin:0; padding:0; background: var(--bg); color: var(--text);
  font-family: 'Manrope', system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif; -webkit-print-color-adjust: exact; print-color-adjust: exact; }}
a {{ color: var(--teal); text-decoration: none; word-break: break-word; }}
code {{ font-family: ui-monospace, 'SFMono-Regular', Menlo, monospace; font-size: .86em; background: var(--alt); padding: 0 .25em; border-radius: 3px; }}
"""

# ------------------------------------------------------------------ one pager
ONE_PAGER = """<!doctype html><html><head><meta charset=utf-8><title>CoRoute one pager</title><style>
""" + BASE_CSS + """
@page { size: A4; margin: 0; }
html, body { width: 210mm; height: 296mm; overflow: hidden; } body { font-size: 8.4pt; line-height: 1.34; position: relative; }
.top { background: var(--teal); color: #fff; padding: 8mm 12mm 6mm; position: relative; }
.top .brand { display:flex; align-items:center; gap:3mm; font-weight:800; font-size:12pt; letter-spacing:.2px; }
.top .brand img { width: 9mm; height: 9mm; border-radius: 2mm; }
.top h1 { font-size: 18pt; line-height: 1.15; margin: 3mm 0 1.5mm; font-weight: 800; max-width: 150mm; }
.top p { margin: 0; color: #D7ECEF; font-size: 9.6pt; max-width: 150mm; }
.top .status { position:absolute; right: 12mm; top: 9mm; background: var(--amber); color:#fff; font-weight:700; font-size:7.6pt; padding: 1.2mm 3mm; border-radius: 10mm; }
.wrap { padding: 4.5mm 12mm 0; display: grid; grid-template-columns: 1fr 1fr; gap: 3.2mm 7mm; }
h2 { font-size: 10.2pt; color: var(--teal); margin: 0 0 1.5mm; font-weight: 800; text-transform: none; }
.card { background: var(--surface); border: 1px solid var(--border); border-radius: 3mm; padding: 2.6mm 3.6mm; }
ul { margin: 0; padding-left: 4.2mm; } li { margin: .4mm 0; }
.full { grid-column: 1 / -1; }
.diff { display:grid; grid-template-columns: repeat(3, 1fr); gap: 2.6mm; }
.diff div { background: var(--surface); border:1px solid var(--border); border-left: 1.2mm solid var(--teal); border-radius: 2mm; padding: 2.2mm 2.8mm; }
.diff b { display:block; font-size: 8.8pt; margin-bottom: .6mm; }
.diff div.am { border-left-color: var(--amber); }
.stat { display:flex; gap: 3mm; margin: 1mm 0 2mm; }
.stat div { flex:1; background: var(--teal-soft); border-radius: 2mm; padding: 2mm 2.5mm; }
.stat b { display:block; font-size: 13pt; color: var(--teal); line-height:1.1; }
.stat span { font-size: 7.4pt; color: var(--muted); }
.phones { display:flex; gap: 2.5mm; justify-content: center; margin-top: 1mm; }
.phones img { width: 19mm; border-radius: 2mm; border: 1px solid var(--border); }
.ask { background: var(--amber-soft); border: 1px solid #EBCBA6; border-radius: 3mm; padding: 3mm 4mm; }
.ask b { color: var(--amber-text); }
.src { font-size: 6.3pt; color: var(--muted); padding: 2.5mm 12mm 0; line-height: 1.32; }
.foot { position:absolute; bottom: 6mm; left: 12mm; right: 12mm; font-size: 7pt; color: var(--muted); display:flex; justify-content: space-between; border-top: 1px solid var(--border); padding-top: 2mm; }
</style></head><body>
<div class=top>
 <div class=brand><img src="assets/icon_256.png" alt="">CoRoute</div>
 <div class=status>Pre-launch · November 2026</div>
 <h1>Ride together, come home safe.</h1>
 <p>The safety and coordination app for India's motorcycle riders, solo and in groups. The phone the rider already carries becomes a crash detector, an SOS beacon that works without signal, and a group radio. No extra hardware.</p>
</div>
<div class=wrap>
 <div>
  <h2>The problem</h2>
  <div class=stat><div><b>1,72,890</b><span>road deaths in India, 2023 [1]</span></div><div><b>44.8 %</b><span>were two-wheeler riders, the highest share [1]</span></div></div>
  <ul>
   <li>A solo crash depends on a passer-by; dead zones on ghats and highways stop calls.</li>
   <li>Group rides run on WhatsApp: location expires, separate bubbles, no roles, no SOS, nothing without data [2].</li>
   <li>Riders in noise-cancelling earbuds or helmet sets often can't hear an ambulance.</li>
  </ul>
 </div>
 <div>
  <h2>Why now</h2>
  <ul>
   <li><b>85.5 %</b> of Indian households own a smartphone, with the sensors crash detection needs [3].</li>
   <li><b>19.61 M</b> two-wheelers and <b>12.25 M</b> motorcycles dispatched in FY2025 [4]; Royal Enfield sold over <b>1 M</b> motorcycles in FY2025 [5] and its One Ride 2025 drew <b>150,000+</b> riders [6].</li>
   <li>Indian group-ride apps compete on community and planning; none we found ships crash detection, offline SOS and live voice together.</li>
  </ul>
  <div class=phones><img src="assets/screens/phone_03_crash.jpg"><img src="assets/screens/phone_06_sirens.jpg"><img src="assets/screens/phone_01_ride_together.jpg"><img src="assets/screens/phone_04_intercom.jpg"></div>
 </div>
 <div class=full>
  <h2>What CoRoute does that others don't</h2>
  <div class=diff>
   <div><b>Crash detection, 30 s check</b>"Possible crash. Are you OK?" No answer sends the SOS. Suppresses potholes, speed breakers, rough road and loose phones; learns per bike.</div>
   <div class=am><b>SOS without signal</b>Text from the rider's phone, text from the server to emergency contacts, and a phone-to-phone relay between nearby riders.</div>
   <div><b>Siren alerts for ANC earbuds</b>The phone's mic recognises ambulance, police and fire sirens and says "Keep left and give way" in the rider's ears.</div>
   <div class=am><b>Live hands-free intercom</b>Push-to-talk or hands-free over mobile data, wind and breath cleaned up; relayed live, never recorded.</div>
   <div><b>Guardian live link</b>Family follow the ride in a browser, no app needed; first name and position only; ends on its own.</div>
   <div class=am><b>Privacy by design</b>Encrypted in transit; no ads; no trackers; no sale of data; routes deleted after 90 days.</div>
  </div>
 </div>
 <div class=card>
  <h2>Business model</h2>
  <ul>
   <li><b>Safety free for every rider</b>, in every plan and mode.</li>
   <li><b>Group plans</b>: one host pays, everyone joins free. Sold only on the website (Google Play payments policy).</li>
   <li><b>Access modes</b> switchable in the web admin: Paid · Free for everyone · Free up to limits.</li>
   <li><b>Operators and clubs (B2B)</b>: approved web console with roster, rides, live map, attendance.</li>
   <li><b>Later</b>: partner perks, insurance safe-rider certificate, fleet safety.</li>
  </ul>
 </div>
 <div class=card>
  <h2>Status</h2>
  <ul>
   <li>Android app and gateway code-complete (v3.55; 3.56 adds web payments, access modes, operator console).</li>
   <li>904 / 904 server tests at the last full run (Nov 2026); 66 admin feature switches, safety core locked on.</li>
   <li>Two Oracle Cloud VMs with live failover; website live at coroute.devmonks.space.</li>
   <li><b>Next:</b> real-device validation, Google Play launch, iOS. No users or revenue yet.</li>
  </ul>
 </div>
 <div class="ask full"><b>The ask: [OWNER TO FILL]</b> amount, instrument, use of funds and the 12-month milestones it buys. &nbsp;·&nbsp; <b>Contact: [OWNER TO FILL]</b> founder name, e-mail, phone.</div>
</div>
<div class=src>[1] MoRTH, Road Accidents in India 2023, via DT Next/PTI, 28 Aug 2025: dtnext.in/news/national/172-lakh-people-died-in-480-lakh-road-accidents-in-2023-road-ministry-report-844831 · [2] Tom's Guide: tomsguide.com/how-to/how-to-share-your-live-location-in-whatsapp · [3] MoSPI CMS: Telecom 2025, via Eastern Mirror: easternmirrornagaland.com/855-pc-of-indian-households-now-own-at-least-1-smartphone-centre · [4] SIAM via Autocar Professional, 2025: autocarpro.in/analysis/fy25-a-year-of-revival-for-the-2-wheeler-industry-126152 · [5] Free Press Journal, 2025: freepressjournal.in/automobiles/royal-enfield-celebrates-historic-1-million-sales-milestone-for-fy-2025 · [6] royalenfield.com/OneRide · Competitor claims: CoRoute desk research of store listings and sites, 11 Nov 2026. &nbsp;<b>CoRoute · https://coroute.devmonks.space · Pre-launch: no traction figures are claimed.</b></div>
</body></html>"""

# ------------------------------------------------------------------ memo
MEMO_CSS = BASE_CSS + """
@page { size: A4; margin: 18mm 16mm 18mm 16mm; }
body { font-size: 9.4pt; line-height: 1.5; background: #fff; }
.cover { height: 255mm; page-break-after: always; display:flex; flex-direction:column; justify-content:space-between;
  background: var(--teal); color:#fff; border-radius: 5mm; padding: 14mm 14mm 11mm; overflow: hidden; }
.cover .brand { display:flex; align-items:center; gap:4mm; font-weight:800; font-size:15pt; }
.cover .brand img { width: 12mm; height:12mm; border-radius: 3mm; }
.cover h1 { font-size: 27pt; line-height:1.1; margin: 0 0 5mm; font-weight:800; color:#fff; border:0; }
.cover .lead { font-size: 12pt; color:#D7ECEF; max-width: 150mm; }
.cover .hero { width:100%; height: 72mm; object-fit: cover; border-radius: 4mm; margin: 6mm 0 0; }
.cover .meta { font-size: 8.4pt; color:#D7ECEF; border-top: 1px solid rgba(255,255,255,.3); padding-top: 4mm; }
.cover .pill { display:inline-block; background: var(--amber); color:#fff; font-weight:700; font-size:8.5pt; padding: 1.3mm 3.5mm; border-radius: 10mm; margin-bottom: 6mm; }
h1 { font-size: 18pt; color: var(--teal); margin: 0 0 3mm; font-weight: 800; }
h2 { font-size: 14pt; color: var(--teal); margin: 7mm 0 2.5mm; font-weight: 800; padding-bottom: 1.5mm; border-bottom: 2px solid var(--teal-soft); break-after: avoid; }
h2.newpage { break-before: page; margin-top: 0; }
h3 { font-size: 10.6pt; margin: 4.5mm 0 1.5mm; color: var(--text); font-weight: 800; break-after: avoid; }
p { margin: 1.5mm 0 2.2mm; }
ul, ol { margin: 1mm 0 2.5mm; padding-left: 5mm; } li { margin: .7mm 0; }
table { width: 100%; border-collapse: collapse; margin: 2mm 0 3.5mm; font-size: 8.3pt; line-height: 1.38; break-inside: auto; }
thead { display: table-header-group; }
tr { break-inside: avoid; }
th { background: var(--teal); color: #fff; text-align: left; font-weight: 700; padding: 1.6mm 2mm; }
td { border-bottom: 1px solid var(--border); padding: 1.5mm 2mm; vertical-align: top; }
tr:nth-child(even) td { background: #FBFAF8; }
hr { border: 0; border-top: 1px solid var(--border); margin: 4mm 0; }
strong { font-weight: 800; }
.phones { display:flex; gap: 4mm; justify-content: center; margin: 3mm 0 4mm; break-inside: avoid; }
.phones figure { margin: 0; text-align: center; width: 36mm; }
.phones img { width: 36mm; border-radius: 3mm; border: 1px solid var(--border); box-shadow: 0 1mm 3mm rgba(0,0,0,.08); }
.phones figcaption { font-size: 7.6pt; color: var(--muted); margin-top: 1.2mm; }
blockquote { margin: 3mm 0; padding: 2.5mm 4mm; background: var(--amber-soft); border-left: 1.2mm solid var(--amber); border-radius: 0 2mm 2mm 0; }
pre { background: var(--alt); padding: 3mm; border-radius: 2mm; font-size: 7.8pt; white-space: pre-wrap; }
.placeholder { background: var(--amber-soft); color: var(--amber-text); font-weight: 800; padding: 0 .3em; border-radius: 2px; }
.toc { columns: 2; column-gap: 10mm; font-size: 10pt; color:#fff; padding-left: 5mm; margin: 0; }
.toc li { margin: 1mm 0; }
"""

FOOTER = """<div style="font-family:Manrope,system-ui,sans-serif;font-size:7pt;color:#8A8F96;width:100%;padding:0 16mm;display:flex;justify-content:space-between">
<span>CoRoute investor memo · November 2026 · Pre-launch: no traction figures are claimed</span><span><span class=pageNumber></span> / <span class=totalPages></span></span></div>"""


def memo_html():
    md = open(os.path.join(ROOT, 'investor_memo.md'), encoding='utf-8').read()
    # Drop the Markdown title block (the cover replaces it): everything before the first "## ".
    body_md = md[md.index('\n## ') + 1:]
    html = markdown.markdown(body_md, extensions=['tables', 'sane_lists', 'md_in_html'])
    html = html.replace('[OWNER TO FILL]', '<span class=placeholder>[OWNER TO FILL]</span>')
    # Start major sections on a new page where it reads well.
    for sec in ('3. The product', '5. Market', '7. Business model', '9. Roadmap', 'Appendix A'):
        html = re.sub(r'<h2>(' + re.escape(sec) + r'[^<]*)</h2>', r'<h2 class=newpage>\1</h2>', html, count=1)
    toc = ''.join(f'<li>{t}</li>' for t in [
        'Executive summary', 'Problem and evidence', 'Product', 'Technology and moat', 'Market', 'Competition', 'Business model',
        'Go-to-market', 'Roadmap', 'Metrics we will track', 'Risks and mitigations', 'Team', 'The ask and use of funds', 'Appendices and sources'])
    cover = f"""<div class=cover><div><div class=brand><img src="assets/icon_256.png" alt="">CoRoute</div></div>
<div><div class=pill>Investor memo · November 2026 · Pre-launch</div>
<h1>The safety and coordination layer for India's motorcycle riders</h1>
<p class=lead>Crash detection with a 30-second check, SOS that works without signal, siren alerts for riders in noise-cancelling earbuds, and a live hands-free group intercom, on the phone riders already carry.</p>
<img class=hero src="assets/feature_graphic.jpg" alt=""></div>
<div><ol class=toc>{toc}</ol>
<p class=meta>Prepared from CoRoute's product documentation and code. Every market figure cites a public source; anything not sourced is marked [OWNER TO FILL]. CoRoute has no users, revenue or ratings yet, and this memo claims none. https://coroute.devmonks.space</p></div></div>"""
    return f"<!doctype html><html><head><meta charset=utf-8><title>CoRoute investor memo</title><style>{MEMO_CSS}</style></head><body>{cover}{html}</body></html>"


def render():
    one = os.path.join(ROOT, '_one_pager.html')
    memo = os.path.join(ROOT, '_investor_memo.html')
    # Temporary HTML next to the Markdown so relative asset paths resolve; removed after rendering.
    open(one, 'w', encoding='utf-8').write(ONE_PAGER)
    open(memo, 'w', encoding='utf-8').write(memo_html())
    try:
        with sync_playwright() as p:
            b = p.chromium.launch()
            pg = b.new_page()
            pg.goto('file://' + one); pg.wait_for_timeout(600)
            pg.pdf(path=os.path.join(ROOT, 'one_pager.pdf'), format='A4', print_background=True, prefer_css_page_size=True)
            pg.goto('file://' + memo); pg.wait_for_timeout(800)
            pg.pdf(path=os.path.join(ROOT, 'investor_memo.pdf'), format='A4', print_background=True, prefer_css_page_size=True,
                   display_header_footer=True, header_template='<div></div>', footer_template=FOOTER,
                   margin={'top': '18mm', 'bottom': '18mm', 'left': '16mm', 'right': '16mm'})
            b.close()
    finally:
        for f in (one, memo):
            os.remove(f)
    print('rendered one_pager.pdf and investor_memo.pdf')


if __name__ == '__main__':
    render()
