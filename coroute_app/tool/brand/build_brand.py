#!/usr/bin/env python3
"""CoRoute brand builder (v3.58 helmet logo).

One source of truth for the logo: the helmet "o" (rider safety) inside the word CoRoute.
Writes the SVG masters to docs/brand/svg/ and every PNG the app, the Play listing and the website use.
Run from the repo root:  python3 tool/brand/build_brand.py   (needs fontTools + rsvg-convert)
"""
import os, subprocess, io
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.boundsPen import BoundsPen

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
P = lambda *a: os.path.join(ROOT, *a)

# Brand tokens (match lib/core/theme/app_palette.dart and gateway/public/assets/site.css)
TEAL, TEAL_L, AMBER, INK, PAPER = '#2B7A8C', '#5FB3C4', '#D9822B', '#15181C', '#F6F4F0'

# Helmet geometry in a 100 x 100 box. Shell, visor (the road ahead) and the amber light (the lead rider).
SHELL = 'M10 64C10 36 30 14 56 14c22 0 36 16 36 36v18c0 8-6 14-14 14H24c-8 0-14-6-14-14z'
VISOR = 'M28 58c18 0 30-12 64-16v16c-20 2-32 10-48 12z'
SUN = (76, 30, 7)
HB = (10, 14, 92, 82)  # helmet bounds x0 y0 x1 y1


def helmet(shell, visor, sun, mono=False):
    cx, cy, r = SUN
    if mono:  # one colour, visor and light cut out (notification / themed icon)
        sunp = f'M{cx - r} {cy}a{r} {r} 0 1 0 {2 * r} 0a{r} {r} 0 1 0 {-2 * r} 0z'
        return f'<path fill-rule="evenodd" d="{SHELL} {VISOR} {sunp}" fill="{shell}"/>'
    return (f'<path d="{SHELL}" fill="{shell}"/><path d="{VISOR}" fill="{visor}"/>'
            f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="{sun}"/>')


def place(size, frac):
    """transform that centres the helmet in a size x size box with its diagonal = frac of the box."""
    w, h = HB[2] - HB[0], HB[3] - HB[1]
    diag = (w * w + h * h) ** 0.5
    s = size * frac / diag
    tx = size / 2 - (HB[0] + w / 2) * s
    ty = size / 2 - (HB[1] + h / 2) * s + size * 0.01
    return f'translate({tx:.2f} {ty:.2f}) scale({s:.4f})'


def svg(w, h, body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}">{body}</svg>'


def icon_svg(size=512, rounded=True, bg=TEAL):
    rx = f' rx="{size * 0.225:.1f}"' if rounded else ''
    return svg(size, size, f'<rect width="{size}" height="{size}"{rx} fill="{bg}"/>'
               f'<g transform="{place(size, 0.78)}">{helmet(PAPER, INK, AMBER)}</g>')


def adaptive_fg(size=432):  # 108 dp canvas, helmet inside the 66 dp safe circle
    return svg(size, size, f'<g transform="{place(size, 0.56)}">{helmet(PAPER, INK, AMBER)}</g>')


def adaptive_mono(size=432):
    return svg(size, size, f'<g transform="{place(size, 0.56)}">{helmet("#FFFFFF", None, None, mono=True)}</g>')


# ---------- wordmark: C + helmet + Route, Manrope ExtraBold as outlines ----------
_font = None


def font():
    global _font
    if _font is None:
        f = TTFont(P('assets', 'fonts', 'Manrope-Variable.ttf'))
        _font = instantiateVariableFont(f, {'wght': 800})
    return _font


def glyph_path(ch, x):
    f = font(); gs = f.getGlyphSet(); cmap = f.getBestCmap(); name = cmap[ord(ch)]
    pen = SVGPathPen(gs); gs[name].draw(pen)
    return f'<path transform="translate({x:.1f} 0)" d="{pen.getCommands()}"/>', gs[name].width


def wordmark_svg(text_color, visor=TEAL_L, sun=AMBER, mono=False, pad=40):
    upm = 2000; track = -0.028 * upm; xh = 1080
    parts = []; x = 0
    p, w = glyph_path('C', x); parts.append(p); x += w + track
    # helmet glyph: height 1.04 x-height (an "o"), sits on the baseline
    hh = xh * 1.04; s = hh / (HB[3] - HB[1]); hw = (HB[2] - HB[0]) * s
    gx = x + 40 - HB[0] * s; gy = -HB[3] * s + 22  # font y-up -> flip later; baseline at 0
    x += hw + 80 + track
    route = []
    for ch in 'Route':
        p, w = glyph_path(ch, x); route.append(p); x += w + track
    x -= track
    asc = 1500; desc = 40
    W = x + 2 * pad; H = asc + desc + 2 * pad
    hel = helmet(text_color, visor, sun, mono=mono)
    body = (f'<g transform="translate({pad} {pad + asc}) scale(1 -1)" fill="{text_color}">{parts[0]}{"".join(route)}</g>'
            f'<g transform="translate({pad + gx:.1f} {pad + asc + gy:.1f}) scale({s:.3f})">{hel}</g>')
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W:.0f} {H:.0f}">{body}</svg>', W, H


def write(rel, text):
    path = P(*rel.split('/')); os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w', newline='\n') as fh:
        fh.write(text)
    return path


def png(svg_text, rel, w, h=None, flatten=None):
    path = P(*rel.split('/')); os.makedirs(os.path.dirname(path), exist_ok=True)
    args = ['rsvg-convert', '-w', str(w), '-h', str(h or w), '-o', path]
    if flatten:
        args[1:1] = ['-b', flatten]
    subprocess.run(args, input=svg_text.encode(), check=True)
    if flatten:  # Play wants 24-bit PNG without alpha
        subprocess.run(['convert', path, '-alpha', 'off', '-define', 'png:color-type=2', path], check=True)
    return path


def main():
    # ---- masters ----
    masters = {
        'coroute-icon.svg': icon_svg(512, True),
        'coroute-icon-square.svg': icon_svg(512, False),
        'coroute-icon-dark.svg': icon_svg(512, True, bg=INK),
        'coroute-adaptive-foreground.svg': adaptive_fg(),
        'coroute-adaptive-monochrome.svg': adaptive_mono(),
        'coroute-helmet.svg': svg(100, 100, helmet(INK, TEAL_L, AMBER)),
        'coroute-helmet-on-dark.svg': svg(100, 100, helmet(PAPER, TEAL_L, AMBER)),
        'coroute-helmet-mono.svg': svg(100, 100, helmet('#000000', None, None, mono=True)),
    }
    wl, W, H = wordmark_svg(INK); masters['coroute-wordmark.svg'] = wl
    wd, _, _ = wordmark_svg(PAPER); masters['coroute-wordmark-on-dark.svg'] = wd
    wt, _, _ = wordmark_svg(TEAL, visor=PAPER); masters['coroute-wordmark-teal.svg'] = wt
    wm, _, _ = wordmark_svg('#000000', mono=True); masters['coroute-wordmark-mono.svg'] = wm
    wc, _, _ = wordmark_svg('currentColor', pad=0); masters['coroute-wordmark-currentcolor.svg'] = wc
    for n, t in masters.items():
        write(f'docs/brand/svg/{n}', t)
    ratio = H / W

    # ---- Android ----
    res = 'android/app/src/main/res'
    for d, px in {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}.items():
        png(icon_svg(512, True), f'{res}/mipmap-{d}/ic_launcher.png', int(48 * px))
        png(adaptive_fg(), f'{res}/mipmap-{d}/ic_launcher_foreground.png', int(108 * px))
        png(adaptive_mono(), f'{res}/mipmap-{d}/ic_launcher_monochrome.png', int(108 * px))
        png(icon_svg(512, True), f'{res}/drawable-{d}/splash_icon.png', int(120 * px))
    # round legacy icon: circle mask
    for d, px in {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}.items():
        s = 512
        circ = svg(s, s, f'<circle cx="{s/2}" cy="{s/2}" r="{s/2}" fill="{TEAL}"/><g transform="{place(s, 0.72)}">{helmet(PAPER, INK, AMBER)}</g>')
        png(circ, f'{res}/mipmap-{d}/ic_launcher_round.png', int(48 * px))

    # ---- design mocks (tool/store_assets) ----
    png(icon_svg(512, True), 'tool/store_assets/mocks/logo152.png', 152)

    # ---- Flutter assets ----
    png(icon_svg(1024, False), 'assets/branding/coroute_icon.png', 1024)

    # ---- iOS (square, no alpha; iOS rounds the corners) and Flutter web ----
    from PIL import Image
    ios = P('ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    if os.path.isdir(ios):
        for n in sorted(os.listdir(ios)):
            if n.endswith('.png'):
                w = Image.open(os.path.join(ios, n)).size[0]
                png(icon_svg(512, False), f'ios/Runner/Assets.xcassets/AppIcon.appiconset/{n}', w, flatten=TEAL)
    if os.path.isdir(P('web')):
        png(icon_svg(512, True), 'web/favicon.png', 32)
        png(icon_svg(512, True), 'web/icons/Icon-192.png', 192)
        png(icon_svg(512, True), 'web/icons/Icon-512.png', 512)
        mask = adaptive_fg().replace('<g', f'<rect width="432" height="432" fill="{TEAL}"/><g', 1)
        png(mask, 'web/icons/Icon-maskable-192.png', 192)
        png(mask, 'web/icons/Icon-maskable-512.png', 512)

    # ---- Play Store ----
    png(icon_svg(512, False), 'store/icon_512.png', 512, flatten=TEAL)
    png(adaptive_fg(), 'store/ic_launcher_foreground_432.png', 432)
    write('store/coroute_mark.svg', icon_svg(512, True))

    # ---- website ----
    pub = 'gateway/public'
    write(f'{pub}/favicon.svg', icon_svg(100, True))
    png(icon_svg(512, True), f'{pub}/favicon-32.png', 32)
    png(icon_svg(512, False), f'{pub}/apple-touch-icon.png', 180, flatten=TEAL)
    png(icon_svg(512, True), f'{pub}/icon-512.png', 512)
    png(icon_svg(512, True), f'{pub}/icon-192.png', 192)
    png(adaptive_fg().replace('<g', f'<rect width="432" height="432" fill="{TEAL}"/><g', 1), f'{pub}/icon-maskable-512.png', 512)
    write(f'{pub}/brand/coroute-wordmark.svg', wl)
    write(f'{pub}/brand/coroute-wordmark-on-dark.svg', wd)
    write(f'{pub}/brand/coroute-icon.svg', icon_svg(512, True))
    # e-mail header images (PNG, mail apps do not show SVG): 2x of 150 px wide
    png(wl, f'{pub}/brand/email-wordmark.png', 300, int(300 * ratio))
    png(icon_svg(512, True), f'{pub}/brand/email-icon.png', 96)
    # docs previews
    png(wl, 'docs/brand/png/coroute-wordmark-1200.png', 1200, int(1200 * ratio))
    png(wd, 'docs/brand/png/coroute-wordmark-on-dark-1200.png', 1200, int(1200 * ratio))
    png(icon_svg(512, True), 'docs/brand/png/coroute-icon-1024.png', 1024)
    print('brand files written; wordmark ratio', round(ratio, 4))


if __name__ == '__main__':
    main()
