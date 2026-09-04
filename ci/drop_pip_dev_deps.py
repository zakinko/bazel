#!/usr/bin/env python3
"""MODULE.bazel から bazel_pip_dev_deps の pip.parse を落とす。

rules_python の pip extension は hub を組む時点で python_version に合う
interpreter を要る。配られている CPython に BSD 向けが無いので、

    Error: Unable to find interpreter for pip hub 'bazel_pip_dev_deps'
      for python_version=3.11

で extension ごと落ちる。この hub を引くのは scripts/docs, src/test/py/bazel,
src/test/tools/test_repos の三つだけで、//src:bazel_nojdk の graph には
入っていない。踏み台を建てる間は要らない。
"""
import io
import sys

HEAD = 'pip = use_extension("@rules_python//python/extensions:pip.bzl"'
TAIL = 'use_repo(pip, "bazel_pip_dev_deps")'


def main():
    p = sys.argv[1] if len(sys.argv) > 1 else "MODULE.bazel"
    s = io.open(p, encoding="utf-8").read()
    i = s.find(HEAD)
    if i < 0:
        print("  pip.parse は元から無い")
        return 0
    j = s.find(TAIL, i)
    if j < i:
        print("  pip の塊の終わりが見つからない")
        return 1
    j = s.find("\n", j) + 1
    io.open(p, "w", encoding="utf-8").write(s[:i] + s[j:])
    print("  pip.parse を落とした")
    return 0


if __name__ == "__main__":
    sys.exit(main())
