#!/usr/bin/env python3
"""bazel_pip_dev_deps を要らなくする。

rules_python の pip extension は hub を組む時点で python_version に合う
interpreter を要る。配られている CPython に BSD 向けが無いので、

    Error: Unable to find interpreter for pip hub 'bazel_pip_dev_deps'
      for python_version=3.11

で extension ごと落ちる。踏み台を建てる間は要らないので二箇所を外す。

MODULE.bazel の pip.parse を落とすだけでは足りない。

    third_party/py/frozendict/BUILD:1
    load("@bazel_pip_dev_deps//:requirements.bzl", "requirement")

が package の頭に在り、この package は third_party/BUILD の srcs から

    "//third_party/py/frozendict:srcs",

と引かれていて、//src:bazel_nojdk の graph に入っている。alias の中身
(requirement("frozendict")) を使うのは tools/ctexplain だけで graph の外
なのに、load が package を読む段階で走るので、誰も使わない repo の解決に
build 全体が引きずられる。

    ERROR: error loading package 'third_party/py/frozendict':
      Unable to find package for @@[unknown repo 'bazel_pip_dev_deps'
      requested from @@]//:requirements.bzl

srcs の filegroup だけ残して load と alias を落とす。

    python3 drop_pip_dev_deps.py <木の根>
"""
import io
import os
import sys

HEAD = 'pip = use_extension("@rules_python//python/extensions:pip.bzl"'
TAIL = 'use_repo(pip, "bazel_pip_dev_deps")'

FROZENDICT = '''licenses(["notice"])

# @bazel_pip_dev_deps から requirement() を load していたが、pip の hub は
# BSD では組めない。alias を引くのは tools/ctexplain だけで、踏み台を建てる
# graph の外に在る。srcs は third_party/BUILD から引かれるので残す。
filegroup(
    name = "srcs",
    srcs = glob(["**"]),
    visibility = ["//visibility:public"],
)
'''


def drop_pip(root):
    p = os.path.join(root, "MODULE.bazel")
    s = io.open(p, encoding="utf-8").read()
    i = s.find(HEAD)
    if i < 0:
        print("  MODULE.bazel: pip.parse は元から無い")
        return 0
    j = s.find(TAIL, i)
    if j < i:
        print("  MODULE.bazel: pip の塊の終わりが見つからない")
        return 1
    j = s.find("\n", j) + 1
    io.open(p, "w", encoding="utf-8").write(s[:i] + s[j:])
    print("  MODULE.bazel: pip.parse を落とした")
    return 0


def drop_frozendict(root):
    p = os.path.join(root, "third_party/py/frozendict/BUILD")
    if not os.path.exists(p):
        print("  frozendict: BUILD が無い")
        return 0
    s = io.open(p, encoding="utf-8").read()
    if "bazel_pip_dev_deps" not in s:
        print("  frozendict: 既に引いていない")
        return 0
    io.open(p, "w", encoding="utf-8").write(FROZENDICT)
    print("  frozendict: load と alias を落とした")
    return 0


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    rc = drop_pip(root) or drop_frozendict(root)
    return rc


if __name__ == "__main__":
    sys.exit(main())
