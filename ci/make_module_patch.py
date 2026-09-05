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
import zipfile
import tempfile
import urllib.request

BCR = "https://bcr.bazel.build/modules/%s/%s/source.json"
BCR_PATCH = "https://bcr.bazel.build/modules/%s/%s/patches/%s"
BCR_OVERLAY = "https://bcr.bazel.build/modules/%s/%s/overlay/%s"


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
    tf = os.path.join(dest, "m.bin")
    io.open(tf, "wb").write(blob)
    out = os.path.join(dest, "a")
    # BCR の書庫は tar.gz のことも zip のこともある。中身で見分ける。
    if blob[:2] == b"PK":
        with zipfile.ZipFile(tf) as z:
            z.extractall(out)
    else:
        with tarfile.open(tf) as t:
            t.extractall(out)

    strip = src.get("strip_prefix", "")
    base = os.path.join(out, strip) if strip else out

    # 新しい BCR は patches ではなく overlay で file を被せることがある。
    # c-ares の BUILD.bazel は上流の書庫に無く、overlay の側に在る。
    for rel in sorted(src.get("overlay", {})):
        url = BCR_OVERLAY % (module, version, rel)
        with urllib.request.urlopen(url, timeout=120) as f:
            body = f.read()
        q = os.path.join(base, rel)
        os.makedirs(os.path.dirname(q), exist_ok=True)
        io.open(q, "wb").write(body)
    if src.get("overlay"):
        print("    overlay: %d file" % len(src["overlay"]))

    # BCR 自身が当てている当て物を先に当てる。zstd-jni の BUILD.bazel は
    # 上流の書庫には無く、add_build_file.patch が作っている。素の書庫を
    # 見ているだけでは「BUILD.bazel が書庫に無い」で終わる。
    for name, _ in sorted(src.get("patches", {}).items()):
        url = BCR_PATCH % (module, version, name)
        with urllib.request.urlopen(url, timeout=60) as f:
            body = f.read()
        pf = os.path.join(dest, name)
        io.open(pf, "wb").write(body)
        r = subprocess.run(["patch", "-p%d" % src.get("patch_strip", 0),
                            "-s", "-i", pf], cwd=base,
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit("  BCR の %s が当たらない: %s"
                             % (name, (r.stdout + r.stderr)[:200]))
        print("    BCR の当て物: %s" % name)
    return strip


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


def _rules_go_goos():
    """ctx.os.name をそのまま GOOS に使う所に DragonFly を足す。"""
    def f(s):
        if 'goos = "dragonfly"' in s:
            return None
        o = '    if goos == "mac os x":\n        goos = "darwin"\n'
        if o not in s:
            raise SystemExit("  detect_host_platform の darwin が見つからない")
        return s.replace(o, o + '    elif goos == "dragonflybsd":\n'
                         '        goos = "dragonfly"\n', 1)
    return f


def _rules_go_no_sdk():
    """配られていない Go SDK を落としに行くのをやめ、手元のものを使う。"""
    def f(s):
        o = ('go_sdk.from_file(\n    name = "go_default_sdk",\n'
             '    go_mod = "//:go.mod",\n)\n')
        if o not in s:
            return None
        return s.replace(o, "", 1)
    return f


def _zstd_jni(osname):
    def f(s):
        if "src/conditions:%s" % osname in s:
            return None
        # copy_file の src は文字列。古い版は list だったので両方見る。
        for q, r in (
            ('        "@bazel_tools//src/conditions:openbsd": '
             '"@bazel_tools//tools/jdk:jni_md_header-openbsd",\n',
             '        "@bazel_tools//src/conditions:%s": '
             '"@bazel_tools//tools/jdk:jni_md_header-%s",\n'),
            ('        "@bazel_tools//src/conditions:openbsd": '
             '["@bazel_tools//tools/jdk:jni_md_header-openbsd"],\n',
             '        "@bazel_tools//src/conditions:%s": '
             '["@bazel_tools//tools/jdk:jni_md_header-%s"],\n'),
        ):
            if q in s:
                return s.replace(q, (r % (osname, osname)) + q, 1)
        raise SystemExit("  zstd-jni の openbsd の行が見つからない")
    return f


def _c_ares(osname, like):
    """ares_config.h を OS で選ぶ select に腕を足す。DragonFly は FreeBSD の
    設定でよい。腕が無いと linux のものを取り、HAVE_MALLOC_H が立って
    無い header (malloc.h) を読みに行く。"""
    def f(s):
        if '":%s"' % osname in s:
            return None
        o = ('config_setting(\n    name = "freebsd",\n'
             '    constraint_values = ["@platforms//os:freebsd"],\n)\n')
        if o not in s:
            raise SystemExit("  c-ares の freebsd の config_setting が無い")
        s = s.replace(o, 'config_setting(\n    name = "%s",\n'
                      '    constraint_values = ["@platforms//os:%s"],\n)\n\n'
                      % (osname, osname) + o, 1)
        a = '        ":freebsd": "include/config_freebsd/ares_config.h",\n'
        if a not in s:
            raise SystemExit("  c-ares の select の freebsd の腕が無い")
        return s.replace(a, '        ":%s": "include/config_%s/ares_config.h",\n'
                         % (osname, like) + a, 1)
    return f


EDITS = {
    "rules_java": {
        "netbsd": [("toolchains/BUILD", _rules_java("netbsd"))],
        "dragonfly": [("toolchains/BUILD", _rules_java("dragonfly"))],
    },
    "rules_go": {
        "netbsd": [("MODULE.bazel", _rules_go_no_sdk()),
                   ("go/private/sdk.bzl", _rules_go_goos())],
        "dragonfly": [("go/private/sdk.bzl", _rules_go_goos())],
    },
    "zstd-jni": {
        "netbsd": [("BUILD.bazel", _zstd_jni("netbsd"))],
        "dragonfly": [("BUILD.bazel", _zstd_jni("dragonfly"))],
    },
    "c-ares": {
        "dragonfly": [("BUILD.bazel", _c_ares("dragonfly", "freebsd"))],
    },
    "platforms": {
        "netbsd": [("host/extension.bzl", _platforms_translate("netbsd"))],
        "dragonfly": [("host/extension.bzl", _platforms_translate("dragonfly")),
                      ("os/BUILD", _platforms_constraint("dragonfly"))],
    },
}


def main():
    # <木の根> <module> <出す当て物> <os>...
    #
    # 一つの module に二つの OS 分を当てたいとき、別々の当て物を二枚渡す
    # のは誤りである。どちらも素の file を基準に起こしているので、一枚目を
    # 当てた後は二枚目の行番号がずれ、
    #
    #   Error applying patch .../rules_java_netbsd.patch
    #
    # で module の取得ごと落ちる。両方の書き換えを済ませてから一度だけ
    # diff を取る。
    root, module, out = sys.argv[1:4]
    osnames = sys.argv[4:]
    osname = osnames[0]
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

    # 同じ file を二つの OS が触ることがあるので、file ごとにまとめる
    order = []
    per_file = {}
    for o in osnames:
        for rel, fn in EDITS[module][o]:
            if rel not in per_file:
                per_file[rel] = []
                order.append(rel)
            per_file[rel].append((o, fn))

    chunks = []
    for rel in order:
        src = locate(rel)
        if src is None:
            print("  %s が書庫に無い" % rel)
            return 1
        cur = io.open(src, encoding="utf-8").read()
        new = cur
        touched = False
        for o, fn in per_file[rel]:
            r = fn(new)
            if r is None:
                print("  %s は既に %s を知っている" % (rel, o))
                continue
            new = r
            touched = True
        if not touched:
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
        # 一つの当て物に二つ以上の file を入れるときは、file の頭に
        #
        #   diff -u -r a/<path> b/<path>
        #
        # が要る。これが無いと bazel の patch は二つ目の file を新しい
        # file の始まりと見なさず、一つ目の hunk の行番号を持ち越して
        #
        #   could not apply patch due to CONTENT_DOES_NOT_MATCH_TARGET,
        #   error applying change near line 22
        #
        # で落ちる (22 は一つ目の file の hunk の位置だった)。
        chunks.append("diff -u -r a/%s b/%s\n" % (rel, rel) + "\n".join(lines))

    if not chunks:
        print("  当てるものが無い (既に入っている)")
        return 2
    io.open(out, "w", encoding="utf-8").write("".join(chunks))
    print("  当て物を起こした: %s" % out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
