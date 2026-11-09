# Bike silhouettes for the manuals: same path data as lib/presentation/garage/bike_silhouette.dart
# (bike_shapes.json, from the bike agent's visual check). Used by gen_social.py and build.py.
import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
SH = json.load(open(os.path.join(HERE, 'bike_shapes.json')))


def _lum(h):
    n = int(h[1:], 16)
    return 0.299 * (n >> 16 & 255) + 0.587 * (n >> 8 & 255) + 0.114 * (n & 255)


def glyph(t, colour, people=0):
    s = SH[t]
    dark = '#6B7280' if _lum(colour) < 60 else '#1F2328'
    light = '#1F2328' if _lum(colour) > 170 else '#FFFFFF'
    o = ''
    for cx, cy, r in s['wheels']:
        o += f'<circle cx="{cx}" cy="{cy}" r="{r - r * 0.21}" fill="none" stroke="{dark}" stroke-width="{r * 0.42}"/><circle cx="{cx}" cy="{cy}" r="{r * 0.22}" fill="{dark}"/>'
    for x1, y1, x2, y2, w in s['lines']:
        o += f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{dark}" stroke-width="{w}" stroke-linecap="round"/>'
    for d in s['body']:
        o += f'<path d="{d}" fill="{colour}" stroke="{dark}" stroke-width="1.2" stroke-linejoin="round"/>'
    for d in s['dark']:
        o += f'<path d="{d}" fill="{dark}"/>'
    for d in s.get('light', []):
        o += f'<path d="{d}" fill="{light}"/>'
    for cx, cy, r in s.get('rings', []):
        o += f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="#FFF3C4" stroke="{dark}" stroke-width="1.4"/>'
    if people:
        P, H = '#263238', '#FFFFFF'

        def fig(hx, hy, sx, sy, ax, ay, kx, ky, fx, fy):
            return (f'<path d="M{hx} {hy} L{kx} {ky} L{fx} {fy}" fill="none" stroke="{P}" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>'
                    f'<line x1="{hx}" y1="{hy}" x2="{sx}" y2="{sy}" stroke="{P}" stroke-width="4.2" stroke-linecap="round"/>'
                    f'<line x1="{sx}" y1="{sy}" x2="{ax}" y2="{ay}" stroke="{P}" stroke-width="2.2" stroke-linecap="round"/>'
                    f'<circle cx="{sx + 1}" cy="{sy - 4.2}" r="3.3" fill="{H}" stroke="{P}" stroke-width="1.3"/>')
        rx, ry = s['rider']; gx, gy = s['grip']
        rsx = rx + (gx - rx) * 0.22; rsy = ry - 9 + (gy - (ry - 9)) * 0.25
        if people >= 2:
            px, py = s['pillion']
            o += fig(px, py, px + 2.5, py - 9, rx + 1, ry - 4, px + 5, py + 5, px + 3.5, py + 10.5)
        o += fig(rx, ry, rsx, rsy, gx, gy, rx + 6, ry + 5, rx + 5, ry + 11)
    return o


def bike_svg(t, colour, w=64, people=0, flip=False):
    h = w * 48 / 64
    g = glyph(t, colour, people)
    if flip:
        g = f'<g transform="translate(64,0) scale(-1,1)">{g}</g>'
    return f'<svg width="{w}" height="{h:.1f}" viewBox="0 -8 64 48">{g}</svg>'


