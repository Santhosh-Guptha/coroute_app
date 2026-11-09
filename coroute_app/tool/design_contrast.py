#!/usr/bin/env python3
"""WCAG contrast check for the v3.55 design tokens (docs/DESIGN_SYSTEM_v3.55.md).

Run: python3 tool/design_contrast.py   (exits 1 if a body-text pair is below 4.5:1)
"""
import sys

LIGHT = dict(bg='#F6F4F0', surface='#FFFFFF', alt='#EFECE6', text='#1F2328', muted='#5B616B', faint='#8A8F96',
             primary='#2B7A8C', onPrimary='#FFFFFF', fill='#2B7A8C', accentStrong='#94600F', danger='#C8463D', sos='#D93A2F')
DARK = dict(bg='#15181C', surface='#1C2026', alt='#242932', text='#E7E3DC', muted='#A7A39B', faint='#7C7A75',
            primary='#5FB3C4', onPrimary='#0E1A1D', fill='#29707E', accentStrong='#E9A55B', danger='#E5675C', sos='#FF5A4E')


def lum(h):
    h = h.lstrip('#')
    r, g, b = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    f = lambda c: c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)


def ratio(a, b):
    hi, lo = sorted([lum(a), lum(b)], reverse=True)
    return (hi + 0.05) / (lo + 0.05)


# (foreground, background, minimum) -- body text needs 4.5.
CHECKS = [('text', 'bg', 4.5), ('text', 'surface', 4.5), ('text', 'alt', 4.5),
          ('muted', 'bg', 4.5), ('muted', 'surface', 4.5), ('muted', 'alt', 4.5),
          ('onPrimary', 'primary', 4.5), ('accentStrong', 'surface', 4.5), ('danger', 'surface', 4.5),
          ('primary', 'surface', 4.5)]

ok = True
for name, pal in (('light', LIGHT), ('dark', DARK)):
    for fg, bg, need in CHECKS:
        r = ratio(pal[fg], pal[bg])
        flag = 'ok' if r >= need else 'LOW'
        ok &= r >= need
        print(f'{name:5} {fg:>12} on {bg:<8} {r:5.2f}  {flag}')
    print(f'{name:5} white on primaryFill {ratio("#FFFFFF", pal["fill"]):5.2f}   white on sos {ratio("#FFFFFF", pal["sos"]):5.2f} (large bold text, >= 3)')
sys.exit(0 if ok else 1)
