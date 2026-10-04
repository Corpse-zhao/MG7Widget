# -*- coding: utf-8 -*-
"""Swift 括号平衡严格自检：字符级状态机，正确处理字符串/插值/单行注释/块注释"""
import glob, sys

def strip(s):
    out = []
    i, n = 0, len(s)
    NORMAL, LINE_C, BLOCK_C, STR = 0, 1, 2, 3
    st = NORMAL
    while i < n:
        c = s[i]
        nxt = s[i+1] if i+1 < n else ''
        if st == NORMAL:
            if c == '/' and nxt == '/':
                st = LINE_C; i += 2; continue
            if c == '/' and nxt == '*':
                st = BLOCK_C; i += 2; continue
            if c == '"':
                st = STR; i += 1; continue
            out.append(c); i += 1
        elif st == LINE_C:
            if c == '\n':
                st = NORMAL; out.append(c)
            i += 1
        elif st == BLOCK_C:
            if c == '*' and nxt == '/':
                st = NORMAL; i += 2
            else:
                i += 1
        else:  # STR
            if c == '\\':
                # 转义：\" \\ \n 等；插值 \( 进入"代码模式"但插值内括号自配对，直接跳过
                i += 2; continue
            if c == '"':
                st = NORMAL; i += 1; continue
            i += 1
    return ''.join(out)

ok = True
for f in glob.glob('ios/MG7Widget/Sources/**/*.swift', recursive=True):
    s = strip(open(f, encoding='utf-8').read())
    for a, b in [('{', '}'), ('(', ')'), ('[', ']')]:
        ca, cb = s.count(a), s.count(b)
        if ca != cb:
            print('UNBALANCED %s: %s=%d %s=%d' % (f, a, ca, b, cb)); ok = False
print('ALL BALANCED' if ok else 'FAIL')
sys.exit(0 if ok else 1)
