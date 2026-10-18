#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""跨语言字段契约审计：Rust serde 结构体 vs Dart fromJson

# 为什么需要它
    model.rs:477-479 原文警告过（tags 那次）：
      serde 默认忽略未知字段 => 字段在桥接出口静默消失，不报错、不警告，查起来极难。
    一个 Rust 结构体加了字段、Dart 侧忘了同步，编译不报错、运行不报错，
    只是那个字段永远到不了 UI。人肉 review 抓不住。

# 判据（两张表，都要求两边都查）
    A. Rust 发 / Dart 不读  —— fromJson 里没有 j['<field>']
    B. Dart 读 / Rust 不发  —— fromJson 读了 j['<key>']，但结构体没这个字段

# 教训（写进代码防止重犯）
    第一版只查 Dart 侧 => 99 个字段误报 15 个。
    cover_headers / badges / hint 等在 Rust 侧有真实消费。
    => 单边为零不等于死字段；必须两边都查，且输出 文件:行号 供人工复核。
"""

import os
import re
import sys

import sys as _sys
_sys.stdout.reconfigure(encoding='utf-8', errors='replace')

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUST_MODEL = os.path.join(ROOT, "rust", "sourin_core", "src", "model.rs")
DART_MODEL = os.path.join(ROOT, "lib", "core", "models.dart")

Q = chr(39) + chr(34)
JKEY_HELPER = re.compile(r'\w+[(]j\s*,\s*[' + Q + r'](\w+)[' + Q + r']')


def parse_rust_structs(src):
    out = {}
    lines = src.split("\n")
    cur = None
    depth = 0
    for i, line in enumerate(lines, 1):
        m = re.match(r"^pub struct (\w+)", line)
        if m:
            cur = m.group(1)
            out[cur] = []
            depth = 0
            continue
        if cur is None:
            continue
        if re.match(r"^}", line):
            cur = None
            continue
        stripped = line.strip()
        # ★ 剔掉注释行：注释里写的 j['note'] 是文档，不是真读取
        #   实测：MediaItem.fromJson 的注释里有 "这里原来读 j['note']"，
        #   不剔掉会把它当成真读取 => 假阴性
        if stripped.startswith("//") or stripped.startswith("*") or stripped.startswith("/*"):
            continue
        depth += line.count("{") - line.count("}")
        fm = re.match(r"^\s+pub (\w+)\s*:", line)
        if fm:
            out[cur].append((fm.group(1), i))
    return out


def parse_dart_fromjson(src):
    out = {}
    lines = src.split(chr(10))
    cur = None
    depth = 0
    body = []
    for i, line in enumerate(lines, 1):
        m = re.search(r'factory (\w+)\.fromJson', line)
        if m:
            cur = m.group(1)
            out[cur] = {'keys': {}, 'primary': set(), 'fallback': set()}
            depth = 0
            body = []
            continue
        if cur is None:
            continue
        st = line.strip()
        is_c = st.startswith('//') or st.startswith('*') or st.startswith('/*')
        if not is_c:
            depth += line.count('{') - line.count('}')
            for km in re.finditer(r'j\[.(\w+).\]', line):
                out[cur]['keys'].setdefault(km.group(1), i)
            for km in re.finditer(JKEY_HELPER, line):
                out[cur]['keys'].setdefault(km.group(1), i)
            body.append(line)
        if re.match(r'^\s*\}\)?;\s*$', line) or re.match(r'^\s*\)\s*;\s*$', line):
            analyze_fallbacks(' '.join(body), out[cur])
            cur = None
            body = []
    return out


def analyze_fallbacks(joined, rec):
    # 按出现顺序拿到所有 j[key]，并记下它们之间的文本
    hits = [(m.start(), m.group(1)) for m in re.finditer(r"j\[.(\w+).\]", joined)]
    if not hits:
        return
    first = True
    prev_end = None
    for pos, key in hits:
        if first:
            rec["primary"].add(key)
            first = False
        else:
            gap = joined[prev_end:pos]
            # 两键之间只允许出现少量非字键字符（) ( ?? 空格）⇒ 视为兜底链
            clean = gap.strip()
            PAREN = chr(41)
            is_chain = len(clean) <= 40 and (chr(63)*2 in clean or clean.replace(PAREN, chr(32)).replace(chr(44), chr(32)).strip() == chr(32).strip() or set(clean) <= set(chr(41)+chr(40)+chr(63)+chr(32)+chr(44)))
            (rec["fallback"] if is_chain else rec["primary"]).add(key)
        prev_end = pos


def audit(rust_structs, dart_json):
    A, B = [], []
    for sname in sorted(rust_structs):
        if sname not in dart_json:
            continue
        rec = dart_json[sname]
        dart_keys = rec['keys']
        rust_names = set(f for f, _ in rust_structs[sname])
        for fname, rline in rust_structs[sname]:
            if fname not in dart_keys:
                A.append((sname, fname, rline, RUST_MODEL, ''))
        for dkey, dline in dart_keys.items():
            if dkey not in rust_names:
                role = 'fallback' if dkey in rec['fallback'] and dkey not in rec['primary'] else 'primary'
                B.append((sname, dkey, dline, DART_MODEL, role))
    return A, B


def selftest():
    """阳性对照：喂已知不匹配的假输入，断言工具能抓到。"""
    fake_rust = chr(10).join([
        "pub struct Fake {",
        "    pub alpha: String,",
        "    pub beta_order: u32,",
        "}",
    ])
    fake_dart = chr(10).join([
        "  factory Fake.fromJson(Map<String, dynamic> j) => Fake(",
        "        alpha: j['alpha'] as String?,",
        "        note: j['subtitle'] as String? ??",
        "            j['note'] as String?,",
        "        url: j['url'] as String?,",
        "      );",
    ])
    rs = parse_rust_structs(fake_rust)
    dj = parse_dart_fromjson(fake_dart)
    A, B = audit(rs, dj)
    ok = True
    if not any(f == "beta_order" for _, f, _, _, _ in A):
        print("  x selftest FAIL: missed Rust-only field beta_order")
        ok = False
    if not any(k == "url" for _, k, _, _, _ in B):
        print("  x selftest FAIL: missed Dart-only key url")
        ok = False
    rec = dj["Fake"]
    if "note" not in rec["fallback"]:
        print("  x selftest FAIL: note 应被识别为兜底键（?? 之后）")
        print("    primary=%s fallback=%s" % (rec["primary"], rec["fallback"]))
        ok = False
    if "subtitle" not in rec["primary"]:
        print("  x selftest FAIL: subtitle 应被识别为主来源")
        ok = False
    if ok:
        print("  v selftest PASS: A=%d, B=%d, fallback=%s" % (len(A), len(B), sorted(rec["fallback"])))
    return ok


def main():
    if "--selftest" in sys.argv:
        sys.exit(0 if selftest() else 1)

    rust_src = open(RUST_MODEL, encoding="utf-8").read()
    dart_src = open(DART_MODEL, encoding="utf-8").read()
    rs = parse_rust_structs(rust_src)
    dj = parse_dart_fromjson(dart_src)

    matched = sorted(set(rs) & set(dj))
    print("Rust structs: %d   Dart fromJson: %d   pairable: %d" % (len(rs), len(dj), len(matched)))
    print("pairable: %s" % ", ".join(matched))
    print()

    A, B = audit(rs, dj)

    print("=" * 78)
    print("A. Rust sends / Dart does not read")
    print("=" * 78)
    if not A:
        print("  (none)")
    for sname, fname, line, path, _role in A:
        rel = os.path.relpath(path, ROOT).replace("\\", "/")
        print("  %-22s %-24s %s:%d" % (sname, fname, rel, line))
    print()

    print("=" * 78)
    print("B. Dart reads / Rust does not send")
    print("=" * 78)
    prim = [r for r in B if r[4] != "fallback"]
    fb = [r for r in B if r[4] == "fallback"]
    if not prim:
        print("  (none)")
    for sname, kname, line, path, role in prim:
        rel = os.path.relpath(path, ROOT).replace(chr(92) * 2, "/")
        print("  %-22s %-24s %s:%d" % (sname, kname, rel, line))
    print()
    print("=" * 78)
    print("B2. 兜底键（?? 之后的备胎，主来源已对上 -> 应当不算发现）")
    print("=" * 78)
    if not fb:
        print("  (none)")
    for sname, kname, line, path, role in fb:
        rel = os.path.relpath(path, ROOT).replace(chr(92) * 2, "/")
        print("  %-22s %-24s %s:%d" % (sname, kname, rel, line))
    print()
    print()
    print("total: A=%d  B=%d" % (len(A), len(B)))
    print()
    print("WARNING: these are CANDIDATES, not conclusions. Review each by hand:")
    print("  some are intentional (Dart guards, renamed keys, nested access)")


if __name__ == "__main__":
    main()
