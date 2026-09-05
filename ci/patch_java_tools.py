#!/usr/bin/env python3
"""remote_java_tools を落として、singlejar の platform 判定を広げる。

    python3 patch_java_tools.py <置き場> [<版>]

rules_java が配る java_tools には singlejar の C++ が入っていて、そこの

    #if defined(__APPLE__) || defined(__linux__) || defined(__FreeBSD__) || \\
        defined(__OpenBSD__)
    ...
    #else
    #error Unknown platform

が NetBSD も DragonFly も知らない。出来合いの binary が配られているのは
linux/darwin/windows だけなので、それ以外では source から建てることになり、
そこで止まる。

    diag.h:56:2: error: Unknown platform

module ではないので single_version_override では当てられない。落として
広げて --override_repository で差し替える。置き場の path を最後に出す。
"""
import io
import os
import sys
import urllib.request
import zipfile

URL = ("https://mirror.bazel.build/bazel_java_tools/releases/java/%s/"
       "java_tools-%s.zip")

# (この文字列を含む file だけ, 元, 後)。fork で NetBSD 向けに測ったものと
# 同じ四箇所で、DragonFly も同じ arm に入れる。
WIDEN = [
    ("singlejar/diag.h",
     "defined(__OpenBSD__)",
     "defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__)"),
    ("singlejar/port.h",
     "#elif defined(__OpenBSD__)",
     "#elif defined(__OpenBSD__) || defined(__NetBSD__) || "
     "defined(__DragonFly__)"),
    ("singlejar/mapped_file_posix.inc",
     "defined(__OpenBSD__)) &&",
     "defined(__OpenBSD__) || defined(__NetBSD__) || "
     "defined(__DragonFly__)) &&"),
    ("singlejar/zip_headers.h",
     "#elif defined(__FreeBSD__) || defined(__OpenBSD__)",
     "#elif defined(__FreeBSD__) || defined(__OpenBSD__) || "
     "defined(__NetBSD__) || defined(__DragonFly__)"),
]


def main():
    dest = sys.argv[1]
    ver = sys.argv[2] if len(sys.argv) > 2 else "v19.0"
    root = os.path.join(dest, "java_tools_" + ver)

    if not os.path.isdir(root):
        os.makedirs(root, exist_ok=True)
        z = os.path.join(dest, "java_tools-%s.zip" % ver)
        if not os.path.exists(z):
            url = URL % (ver, ver)
            sys.stderr.write("  取る: %s\n" % url)
            with urllib.request.urlopen(url, timeout=600) as f:
                io.open(z, "wb").write(f.read())
        with zipfile.ZipFile(z) as f:
            f.extractall(root)

    hit = 0
    for dirpath, _, names in os.walk(root):
        for n in names:
            p = os.path.join(dirpath, n)
            for tail, old, new in WIDEN:
                if not p.endswith(tail):
                    continue
                s = io.open(p, encoding="utf-8", errors="surrogateescape").read()
                if new in s:
                    continue
                if old not in s:
                    sys.stderr.write("  当てる場所が無い: %s\n" % p)
                    return 1
                io.open(p, "w", encoding="utf-8",
                        errors="surrogateescape").write(s.replace(old, new))
                hit += 1
    sys.stderr.write("  singlejar の platform 判定を %d 箇所広げた\n" % hit)
    print(root)
    return 0


if __name__ == "__main__":
    sys.exit(main())
