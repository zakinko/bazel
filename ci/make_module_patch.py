#!/usr/bin/env python3
"""BCR から module の書庫を落とし、その場で diff を起こす。

    python3 make_module_patch.py <木の根> <module> <出す当て物> <指定>...

fork の toolchain_local/ に置いてある当て物は、作った当時の版に対する
文脈で書かれている。upstream の master が別の版を引くと、bazel は

    Error applying patch .../rules_java_dragonfly.patch:
      in patch applied to /tmp/...

で module の取得ごと落ちる。手で当て直すと、版が上がるたびに同じことが
起きる。BCR の archive を見て diff を起こせば、版に追従する。

<指定> は "<repo 内の path>:<元の文字列>:<置き換え後>" を base64 で包んだ
もの……ではなく、この script が module ごとに知っている。今は rules_java
だけ。
"""
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

BCR = "https://bcr.bazel.build/modules/%s/%s/source.json"


def version_of(root, module):
    p = os.path.join(root, "MODULE.bazel")
    s = io.open(p, encoding="utf-8").read()
    m = re.search(r'bazel_dep\(\s*name = "%s",\s*version = "([^"]+)"' % re.escape(module), s)
    if not m:
        m = re.search(r'name = "%s",\s*\n\s*version = "([^"]+)"' % re.escape(module), s)
    if not m:
        return None
    return m.group(1)


def fetch(module, version, dest):
    url = BCR % (module, version)
    with urllib.request.urlopen(url, timeout=60) as f:
        src = json.load(f)
    with urllib.request.urlopen(src["url"], timeout=300) as f:
        blob = f.read()
    tf = os.path.join(dest, "m.tar.gz")
    io.open(tf, "wb").write(blob)
    with tarfile.open(tf) as t:
        t.extractall(os.path.join(dest, "a"))
    return src.get("strip_prefix", "")


# module ごとの書き換え。値は (repo 内の path, 書き換え関数) の並び。
# 関数は文字列を受け、書き換えた文字列か、既に当たっていれば None を返す。


def _rules_java(osname):
    def f(s):
        if 'jni_md_header-%s"' % osname in s:
            return None
        o = ('java_runtime_files(\n    name = "jni_md_header-openbsd",\n'
             '    srcs = ["include/openbsd/jni_md.h"],\n)\n')
        if o not in s:
            raise SystemExit("  openbsd の塊が見つからない")
        s = s.replace(o, o + '\njava_runtime_files(\n'
                      '    name = "jni_md_header-%s",\n'
                      '    srcs = ["include/%s/jni_md.h"],\n)\n' % (osname, osname), 1)
        a = '        "@bazel_tools//src/conditions:openbsd": [":jni_md_header-openbsd"],\n'
        b = '        "@bazel_tools//src/conditions:openbsd": ["include/openbsd"],\n'
        if a not in s or b not in s:
            raise SystemExit("  select の openbsd の行が見つからない")
        s = s.replace(a, '        "@bazel_tools//src/conditions:%s": [":jni_md_header-%s"],\n'
                      % (osname, osname) + a, 1)
        s = s.replace(b, '        "@bazel_tools//src/conditions:%s": ["include/%s"],\n'
                      % (osname, osname) + b, 1)
        return s
    return f


def _platforms_translate(osname):
    def f(s):
        if 'return "%s"' % osname in s:
            return None
        o = '    if os.startswith("freebsd"):\n'
        if o not in s:
            raise SystemExit("  _translate_os の freebsd が見つからない")
        return s.replace(o, '    if os.startswith("%s"):\n        return "%s"\n'
                         % (osname, osname) + o, 1)
    return f


def _platforms_constraint(osname):
    def f(s):
        if 'name = "%s"' % osname in s:
            return None
        o = 'constraint_value(\n    name = "freebsd",\n    constraint_setting = ":os",\n)\n'
        if o not in s:
            raise SystemExit("  os/BUILD の freebsd が見つからない")
        return s.replace(o, 'constraint_value(\n    name = "%s",\n'
                         '    constraint_setting = ":os",\n)\n\n' % osname + o, 1)
    return f


EDITS = {
    "rules_java": {
        "netbsd": [("toolchains/BUILD", _rules_java("netbsd"))],
        "dragonfly": [("toolchains/BUILD", _rules_java("dragonfly"))],
    },
    "platforms": {
        "netbsd": [("host/extension.bzl", _platforms_translate("netbsd"))],
        "dragonfly": [("host/extension.bzl", _platforms_translate("dragonfly")),
                      ("os/BUILD", _platforms_constraint("dragonfly"))],
    },
}


def main():
    root, module, out, osname = sys.argv[1:5]
    version = version_of(root, module)
    if version is None:
        print("  %s の版が読めない" % module)
        return 1
    print("  %s %s を BCR から取る" % (module, version))

    d = tempfile.mkdtemp(prefix="mp-")
    strip = fetch(module, version, d)
    base = os.path.join(d, "a", strip) if strip else os.path.join(d, "a")

    def locate(rel):
        p = os.path.join(base, rel)
        if os.path.exists(p):
            return p
        for x in sorted(os.listdir(base)):
            q = os.path.join(base, x, rel)
            if os.path.exists(q):
                return q
        return None

    chunks = []
    for rel, fn in EDITS[module][osname]:
        src = locate(rel)
        if src is None:
            print("  %s が書庫に無い" % rel)
            return 1
        cur = io.open(src, encoding="utf-8").read()
        new = fn(cur)
        if new is None:
            print("  %s は既に %s を知っている" % (rel, osname))
            continue
        for side, text in (("old", cur), ("new", new)):
            q = os.path.join(d, side, rel)
            os.makedirs(os.path.dirname(q), exist_ok=True)
            io.open(q, "w", encoding="utf-8").write(text)
        p = subprocess.run(["diff", "-u", "old/" + rel, "new/" + rel],
                           cwd=d, capture_output=True, text=True)
        lines = p.stdout.split("\n")
        if len(lines) < 3:
            print("  差が出ない: %s" % rel)
            return 1
        lines[0] = "--- a/" + rel
        lines[1] = "+++ b/" + rel
        chunks.append("\n".join(lines))

    if not chunks:
        print("  当てるものが無い (既に入っている)")
        return 2
    io.open(out, "w", encoding="utf-8").write("".join(chunks))
    print("  当て物を起こした: %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
