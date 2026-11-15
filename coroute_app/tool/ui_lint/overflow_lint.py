#!/usr/bin/env python3
"""Static overflow lint for Flutter screens (no Flutter SDK needed).

Flags the patterns that cause "text hovering"/overflow on small phones and large system text:
  R1  Row with 2+ children where a Text child is not inside Expanded/Flexible and has no overflow/maxLines.
  R2  Text inside a fixed-height SizedBox/Container (height: N) without maxLines (clips or overflows at large text).
  R3  Text in a Row next to a Spacer() without Flexible (Spacer + long text = overflow).
  R4  Stack/Positioned text without maxLines (text can run over other widgets).
Usage: python3 tool/ui_lint/overflow_lint.py lib/presentation [--json]
"""
import os, re, sys, json

def match_paren(s, i):  # s[i] == '('
    depth = 0; j = i; n = len(s); in_str = None
    while j < n:
        c = s[j]
        if in_str:
            if c == '\\': j += 2; continue
            if s.startswith(in_str, j): j += len(in_str); in_str = None; continue
            j += 1; continue
        if s.startswith("'''", j) or s.startswith('"""', j): in_str = s[j:j+3]; j += 3; continue
        if c in "'\"": in_str = c; j += 1; continue
        if s.startswith('//', j): j = s.find('\n', j); j = n if j < 0 else j; continue
        if c in '([{': depth += 1
        elif c in ')]}':
            depth -= 1
            if depth == 0: return j
        j += 1
    return n - 1

def split_top(s):  # split by top-level commas
    out, depth, cur, in_str, i = [], 0, '', None, 0
    while i < len(s):
        c = s[i]
        if in_str:
            cur += c
            if c == '\\' and i + 1 < len(s): cur += s[i+1]; i += 2; continue
            if c == in_str: in_str = None
            i += 1; continue
        if c in "'\"": in_str = c; cur += c; i += 1; continue
        if c in '([{': depth += 1
        if c in ')]}': depth -= 1
        if c == ',' and depth == 0: out.append(cur.strip()); cur = ''
        else: cur += c
        i += 1
    if cur.strip(): out.append(cur.strip())
    return out

def named(args, name):
    for a in args:
        if re.match(rf'{name}\s*:', a): return a.split(':', 1)[1].strip()
    return None

def children_of(call_body):
    args = split_top(call_body)
    ch = named(args, 'children')
    if not ch: return []
    ch = ch.strip()
    if ch.startswith('const '): ch = ch[6:].strip()
    if ch.startswith('<'): ch = ch[ch.index('['):]
    if not ch.startswith('['): return []
    return [c for c in split_top(ch[1:ch.rfind(']')]) if c and not c.startswith('if ') and not c.startswith('...')]

TEXT_SAFE = re.compile(r'overflow\s*:|maxLines\s*:|softWrap\s*:\s*true')
def is_bare_text(w):
    w = w.strip()
    if w.startswith('const '): w = w[6:]
    return bool(re.match(r'(Text|Text\.rich|SelectableText)\s*\(', w)) and not TEXT_SAFE.search(w)
def short_literal(w):
    m = re.search(r"Text\(\s*'([^'$]{0,6})'", w)
    return bool(m)

def scan(path):
    s = open(path, encoding='utf-8').read()
    issues = []
    line = lambda i: s.count('\n', 0, i) + 1
    for m in re.finditer(r'\bRow\s*\(', s):
        i = m.end() - 1; j = match_paren(s, i)
        kids = children_of(s[i+1:j])
        if len(kids) < 2: continue
        has_spacer = any(re.match(r'(const\s+)?Spacer\(', k) for k in kids)
        flex = sum(1 for k in kids if re.match(r'(const\s+)?(Expanded|Flexible)\(', k))
        for k in kids:
            if is_bare_text(k) and not short_literal(k):
                code = 'R3' if has_spacer else 'R1'
                if flex and not has_spacer:
                    continue  # another child takes the slack; a short label next to Expanded is fine
                issues.append((code, line(i), k.split('\n')[0][:90]))
    for m in re.finditer(r'\b(SizedBox|Container)\s*\(', s):
        i = m.end() - 1; j = match_paren(s, i); body = s[i+1:j]
        args = split_top(body)
        h = named(args, 'height'); child = named(args, 'child')
        if h and re.match(r'^\d+(\.\d+)?$', h) and child and is_bare_text(child) and float(h) < 64:
            issues.append(('R2', line(i), child.split('\n')[0][:90]))
    for m in re.finditer(r'\bPositioned(\.fill)?\s*\(', s):
        i = m.end() - 1; j = match_paren(s, i); body = s[i+1:j]
        child = named(split_top(body), 'child')
        if child and is_bare_text(child) and not short_literal(child):
            issues.append(('R4', line(i), child.split('\n')[0][:90]))
    return issues

def main():
    roots = [a for a in sys.argv[1:] if not a.startswith('--')] or ['lib/presentation']
    total = []
    for r in roots:
        for dp, _, fs in os.walk(r):
            for f in fs:
                if f.endswith('.dart'):
                    p = os.path.join(dp, f)
                    for code, ln, snip in scan(p): total.append({'file': p, 'line': ln, 'rule': code, 'code': snip})
    if '--json' in sys.argv: print(json.dumps(total, indent=1))
    else:
        for t in total: print(f"{t['rule']} {t['file']}:{t['line']}  {t['code']}")
        print(f'{len(total)} findings')
    sys.exit(1 if total and '--strict' in sys.argv else 0)

if __name__ == '__main__': main()
