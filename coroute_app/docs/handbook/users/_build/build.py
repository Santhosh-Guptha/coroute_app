#!/usr/bin/env python3
"""Builds print HTML for the rider-facing handbook docs (users/*.md) and renders them to PDF.

Usage (from anywhere):  python3 docs/handbook/users/_build/build.py [name ...]
Needs: python-markdown, Node with Playwright + Chromium (pre-installed; never reinstall).
Output: users/<name>.pdf next to each Markdown file. Intermediate HTML in _build/html/.
"""
import os, re, sys, json, subprocess, html as H
import markdown

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                      # docs/handbook/users
OUT_HTML = os.path.join(HERE, 'html')

# name -> options. cover: full cover page; breaks: each h2 starts a new page.
DOCS = {
    'quick_start':                 dict(cover=False, breaks=False, compact=True),
    'user_guide':                  dict(cover=True,  breaks=True),
    'safety_guide':                dict(cover=True,  breaks=False),
    'faq':                         dict(cover=False, breaks=False),
    'troubleshooting':             dict(cover=False, breaks=False),
    'privacy_summary_for_riders':  dict(cover=False, breaks=False),
    'community_guidelines':        dict(cover=False, breaks=False),
    'release_notes_v3.55_users':   dict(cover=False, breaks=False),
}

TEAL, TEAL_D, TEAL_L = '#2B7A8C', '#1E5A68', '#E6F2F4'
AMBER, AMBER_L = '#D9822B', '#FBF0E4'
INK, MUTED, LINE = '#1C2B33', '#5A6B75', '#DCE6EA'

CSS = f"""
@font-face {{ font-family: Manrope; font-weight: 400; src: url('../fonts/manrope-latin-400-normal.woff2'); }}
@font-face {{ font-family: Manrope; font-weight: 500; src: url('../fonts/manrope-latin-500-normal.woff2'); }}
@font-face {{ font-family: Manrope; font-weight: 600; src: url('../fonts/manrope-latin-600-normal.woff2'); }}
@font-face {{ font-family: Manrope; font-weight: 700; src: url('../fonts/manrope-latin-700-normal.woff2'); }}
@page {{ size: A4; margin: 18mm 17mm 18mm 17mm; }}
@page :first {{ margin-top: 12mm; }}
* {{ box-sizing: border-box; }}
html {{ -webkit-print-color-adjust: exact; print-color-adjust: exact; }}
body {{ margin: 0; font-family: Manrope, 'Noto Sans', system-ui, sans-serif; color: {INK}; font-size: 10pt; line-height: 1.55; }}
a {{ color: {TEAL_D}; text-decoration: none; }}
h1 {{ font-size: 23pt; line-height: 1.15; margin: 0 0 3mm; font-weight: 700; letter-spacing: -.01em; color: {INK}; }}
h2 {{ font-size: 14.5pt; margin: 8mm 0 2.5mm; font-weight: 700; color: {TEAL_D}; padding-bottom: 1.5mm; border-bottom: 1.5px solid {LINE}; break-after: avoid; }}
h3 {{ font-size: 11.5pt; margin: 5mm 0 1.5mm; font-weight: 700; color: {INK}; break-after: avoid; }}
h4 {{ font-size: 10.5pt; margin: 4mm 0 1mm; font-weight: 700; break-after: avoid; }}
p {{ margin: 0 0 2.6mm; }}
ul, ol {{ margin: 0 0 3mm; padding-left: 6mm; }}
li {{ margin: 0 0 1.1mm; }}
li > p {{ margin: 0 0 1mm; }}
strong {{ font-weight: 700; }}
code {{ font-family: 'DejaVu Sans Mono', monospace; font-size: 8.6pt; background: #F1F5F7; padding: .2mm 1.2mm; border-radius: 1mm; }}
pre {{ background: #F1F5F7; padding: 3mm; border-radius: 2mm; font-size: 8.5pt; white-space: pre-wrap; break-inside: avoid; }}
pre code {{ background: none; padding: 0; }}
hr {{ border: 0; border-top: 1px solid {LINE}; margin: 5mm 0; }}
table {{ width: 100%; border-collapse: collapse; font-size: 8.9pt; margin: 2mm 0 4mm; break-inside: auto; }}
thead {{ display: table-header-group; }}
tr {{ break-inside: avoid; }}
th {{ text-align: left; font-size: 7.6pt; letter-spacing: .06em; text-transform: uppercase; color: #fff; background: {TEAL}; padding: 1.8mm 2.2mm; font-weight: 700; }}
th:first-child {{ border-top-left-radius: 1.5mm; }} th:last-child {{ border-top-right-radius: 1.5mm; }}
td {{ border-bottom: 1px solid {LINE}; padding: 1.8mm 2.2mm; vertical-align: top; }}
tbody tr:nth-child(even) td {{ background: #F7FAFB; }}
blockquote {{ margin: 3mm 0 4mm; padding: 3mm 4.5mm; background: {TEAL_L}; border-left: 1.6mm solid {TEAL}; border-radius: 0 2mm 2mm 0; break-inside: avoid; }}
blockquote p:last-child {{ margin-bottom: 0; }}
blockquote.important, blockquote.warning {{ background: {AMBER_L}; border-left-color: {AMBER}; }}
blockquote .alert-label {{ display: block; font-size: 7.6pt; letter-spacing: .12em; text-transform: uppercase; font-weight: 700; color: {TEAL_D}; margin-bottom: 1mm; }}
blockquote.important .alert-label, blockquote.warning .alert-label {{ color: #9A5513; }}
p.shots {{ display: flex; gap: 8mm; justify-content: center; margin: 4mm 0 1mm; break-inside: avoid; break-after: avoid; }}
p.shots img {{ height: 66mm; border-radius: 4mm; border: 1px solid {LINE}; box-shadow: 0 1.5mm 4mm rgba(28,43,51,.14); }}
p.caption {{ text-align: center; font-size: 8.2pt; color: {MUTED}; margin: 1mm 0 4mm; break-before: avoid; }}
.box-check {{ display: inline-block; width: 3.4mm; height: 3.4mm; border: 1.3px solid {TEAL}; border-radius: .8mm; margin-right: 1.8mm; vertical-align: -0.4mm; }}
li.task {{ list-style: none; margin-left: -5mm; }}
.doc-head {{ display: flex; align-items: center; gap: 4mm; background: {TEAL}; color: #fff; border-radius: 3mm; padding: 4.5mm 6mm; margin: 0 0 6mm; }}
.doc-head img {{ width: 13mm; height: 13mm; border-radius: 3mm; background: #fff; }}
.doc-head .t {{ font-size: 18pt; font-weight: 700; line-height: 1.15; }}
.doc-head .s {{ font-size: 9.5pt; opacity: .92; }}
.doc-head .v {{ margin-left: auto; font-size: 8pt; font-weight: 600; background: rgba(255,255,255,.16); padding: 1mm 3mm; border-radius: 10mm; white-space: nowrap; }}
.has-head h1:first-of-type {{ display: none; }}
.cover {{ height: 258mm; display: flex; flex-direction: column; break-after: page; }}
.cover .band {{ background: {TEAL}; color: #fff; border-radius: 4mm; padding: 16mm 14mm 12mm; position: relative; overflow: hidden; }}
.cover .band:after {{ content: ''; position: absolute; right: -30mm; top: -30mm; width: 110mm; height: 110mm; border-radius: 50%; background: rgba(255,255,255,.07); }}
.cover .band img.icon {{ width: 20mm; height: 20mm; border-radius: 5mm; background: #fff; margin-bottom: 8mm; }}
.cover .band .t {{ font-size: 32pt; font-weight: 700; line-height: 1.1; margin-bottom: 4mm; }}
.cover .band .s {{ font-size: 13pt; font-weight: 500; opacity: .95; max-width: 140mm; }}
.cover .band .v {{ display: inline-block; margin-top: 8mm; font-size: 9pt; font-weight: 700; border: 1px solid rgba(255,255,255,.5); border-radius: 10mm; padding: 1.2mm 4mm; }}
.cover .shots {{ display: flex; gap: 7mm; justify-content: center; margin: 12mm 0 8mm; }}
.cover .shots img {{ height: 92mm; border-radius: 4mm; border: 1px solid {LINE}; box-shadow: 0 2mm 5mm rgba(28,43,51,.16); }}
.cover .sos {{ margin-top: auto; background: {AMBER_L}; border-left: 1.6mm solid {AMBER}; border-radius: 0 3mm 3mm 0; padding: 4mm 6mm; font-size: 10.5pt; }}
.cover .sos b {{ color: #9A5513; }}
.breaks h2 {{ break-before: page; margin-top: 0; }}
.breaks h2#1-getting-around-the-app {{ break-before: avoid; }}
.compact {{ font-size: 9.1pt; line-height: 1.45; }}
.compact h2 {{ font-size: 12pt; margin: 4.5mm 0 1.8mm; padding-bottom: 1mm; }}
.compact h3 {{ margin: 2.5mm 0 1mm; font-size: 10pt; }}
.compact p {{ margin: 0 0 1.8mm; }}
.compact li {{ margin: 0 0 .6mm; }}
.compact table {{ font-size: 8.2pt; margin: 1.5mm 0 2.5mm; }}
.compact td, .compact th {{ padding: 1.2mm 2mm; }}
.compact blockquote {{ padding: 2.2mm 4mm; margin: 2mm 0 3mm; }}
.compact .doc-head {{ margin-bottom: 4mm; padding: 3.5mm 5mm; }}
"""

COVER_SHOTS = {
    'user_guide': ['ride_map.jpg', 'sos_hold.jpg', 'people_crews.jpg'],
    'safety_guide': ['sos_hold.jpg', 'crash_countdown.jpg', 'siren_alert.jpg'],
}


def front_matter(text):
    meta = {}
    if text.startswith('---\n'):
        end = text.index('\n---', 4)
        for line in text[4:end].splitlines():
            if ':' in line:
                k, v = line.split(':', 1)
                meta[k.strip()] = v.strip()
        text = text[end + 4:].lstrip('\n')
    return meta, text


def post(html_body):
    # GitHub-style alerts: > [!IMPORTANT] / [!TIP] / [!NOTE] / [!WARNING]
    def alert(m):
        kind = m.group(1).lower()
        label = {'important': 'Important', 'warning': 'Warning', 'tip': 'Tip', 'note': 'Note'}[kind]
        return f'<blockquote class="{kind}">\n<p><span class="alert-label">{label}</span>'
    html_body = re.sub(r'<blockquote>\s*<p>\[!(IMPORTANT|WARNING|TIP|NOTE)\]\s*', alert, html_body)
    # Paragraphs holding only images -> a centred row
    html_body = re.sub(r'<p>((?:\s*<img [^>]+>\s*)+)</p>', lambda m: f'<p class="shots">{m.group(1)}</p>', html_body)
    # A paragraph that is only an <em> right after an image row -> caption
    html_body = re.sub(r'(<p class="shots">.*?</p>\s*)<p><em>(.*?)</em></p>', r'\1<p class="caption">\2</p>', html_body, flags=re.S)
    # Task lists
    html_body = re.sub(r'<li>\[ \]\s*', '<li class="task"><span class="box-check"></span>', html_body)
    return html_body


def build(name, opt):
    src = os.path.join(ROOT, name + '.md')
    meta, text = front_matter(open(src, encoding='utf-8').read())
    md = markdown.Markdown(extensions=['tables', 'toc', 'sane_lists', 'attr_list', 'fenced_code'])
    body = post(md.convert(text))
    body = body.replace('src="assets/', 'src="../../assets/')
    title = meta.get('title', name)
    sub = meta.get('subtitle', '')
    ver = meta.get('version', '')
    icon = '../../assets/icon.png'
    parts = []
    cls = []
    if opt['cover']:
        shots = ''.join(f'<img src="../../assets/{s}">' for s in COVER_SHOTS.get(name, []))
        parts.append(f"""<section class="cover"><div class="band"><img class="icon" src="{icon}">
<div class="t">{H.escape(title)}</div><div class="s">{H.escape(sub)}</div><div class="v">{H.escape(ver)}</div></div>
<div class="shots">{shots}</div>
<div class="sos"><b>In an emergency, call 112 first.</b> Then hold SOS for 3 seconds so your group and emergency contact know where you are.</div></section>""")
        cls.append('has-head')
    else:
        parts.append(f"""<div class="doc-head"><img src="{icon}"><div><div class="t">{H.escape(title)}</div><div class="s">{H.escape(sub)}</div></div><div class="v">{H.escape(ver)}</div></div>""")
        cls.append('has-head')
    if opt['breaks']:
        cls.append('breaks')
    if opt.get('compact'):
        cls.append('compact')
    doc = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><title>{H.escape(title)}</title>
<style>{CSS}</style></head><body class="{' '.join(cls)}">{''.join(parts)}<main>{body}</main></body></html>"""
    os.makedirs(OUT_HTML, exist_ok=True)
    out = os.path.join(OUT_HTML, name + '.html')
    open(out, 'w', encoding='utf-8').write(doc)
    return dict(name=name, html=out, pdf=os.path.join(ROOT, name + '.pdf'), title=title)


def main():
    names = sys.argv[1:] or list(DOCS)
    jobs = [build(n, DOCS[n]) for n in names if os.path.exists(os.path.join(ROOT, n + '.md'))]
    jf = os.path.join(HERE, 'jobs.json')
    json.dump(jobs, open(jf, 'w'))
    subprocess.run(['node', os.path.join(HERE, 'render.js'), jf], check=True)
    for j in jobs:
        print('PDF', j['pdf'])


if __name__ == '__main__':
    main()
