#!/usr/bin/env python3
"""MODULE.bazel に当て物付きの single_version_override を足す。

    python3 add_overrides.py <木の根> <module>=<当て物の path> ...

単に append すると二つの問題が出る。

  一, 同じ module へ二回 single_version_override を書くと bazel が拒む。
      NetBSD では rules_go に二枚当てたい (goos の判定と Go SDK) ので、
      一枚ずつ append する書き方では通らない。

  二, upstream の MODULE.bazel が既に grpc と c-ares の override を持って
      いる。そこへ足すと重複になる。

なので、既に在れば patches の list へ差し込み、無ければ塊ごと書く。
当て物は toolchain_local/ へ複製し、label でそこを指す。
"""
import io
import os
import re
import shutil
import sys

DIR = "toolchain_local"


def label(name):
    return '"//%s:%s"' % (DIR, name)


def add(text, module, name):
    lab = label(name)
    if lab in text:
        print("  済み: %s <- %s" % (module, name))
        return text, True

    m = re.search(
        r'single_version_override\(\s*\n\s*module_name = "%s",\n' % re.escape(module),
        text)
    if not m:
        block = (
            '\nsingle_version_override(\n'
            '    module_name = "%s",\n'
            '    patch_strip = 1,\n'
            '    patches = [%s],\n'
            ')\n' % (module, lab))
        print("  足した: %s <- %s" % (module, name))
        return text + block, True

    # 既に在る塊の終わりを探し、その中の patches を見る
    start = m.start()
    end = text.index("\n)\n", start) + 3
    body = text[start:end]

    if "patches = [" in body:
        new = body.replace("patches = [", "patches = [\n        %s," % lab, 1)
    else:
        new = body.replace(
            'module_name = "%s",\n' % module,
            'module_name = "%s",\n    patch_strip = 1,\n    patches = [%s],\n'
            % (module, lab), 1)
        if "patch_strip" in body:
            new = new.replace("    patch_strip = 1,\n    patches", "    patches", 1)
    print("  既存の塊へ差した: %s <- %s" % (module, name))
    return text[:start] + new + text[end:], True


def main():
    root = sys.argv[1]
    pairs = sys.argv[2:]
    if not pairs:
        print("  当てるものが無い")
        return 0

    d = os.path.join(root, DIR)
    os.makedirs(d, exist_ok=True)
    b = os.path.join(d, "BUILD")
    if not os.path.exists(b):
        io.open(b, "w").write("")

    p = os.path.join(root, "MODULE.bazel")
    text = io.open(p, encoding="utf-8").read()
    for pair in pairs:
        module, src = pair.split("=", 1)
        if not os.path.exists(src):
            print("  当て物が無い: %s" % src)
            return 1
        name = os.path.basename(src)
        shutil.copyfile(src, os.path.join(d, name))
        text, ok = add(text, module, name)
        if not ok:
            return 1
    io.open(p, "w", encoding="utf-8").write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
