#!/usr/bin/env python3
"""OS の列挙に NetBSD と DragonFly を足す。

src/main/java/.../util/OS.java に値を足すだけでは足りない。値を列挙している
場所が木の中に散らばっていて、そこに入っていないと **足す前より悪くなる**。
JniLoader がその例で、

    switch (OS.getCurrent()) {
      case LINUX, FREEBSD, OPENBSD, UNKNOWN -> {
        loadLibrary("main/native/libunix_jni.so");

と書いてある。NetBSD は足す前は UNKNOWN として .so を読めていたのに、
OS.NETBSD を足した途端どの case にも当たらず、何も読まなくなって

    java.lang.UnsatisfiedLinkError:
      ...NativePosixFilesServiceImpl.readdir(java.lang.String)

で落ちた。.so には記号が在り、jar にも入っていて、ldd も通る。症状と実体が
食い違って見えるのはそのためである。

    python3 os_enum_sites.py <木の根>

当たった場所を数えて出す。一つも当たらなければ 1 で戻る。
"""
import os
import sys

# (相対 path, 元の文字列, 置き換え後) の並び。どれも「FreeBSD と OpenBSD は
# 書かれているのに NetBSD と DragonFly が無い」という同じ形をしている。
SITES = [
    (
        "src/main/java/com/google/devtools/build/lib/util/OS.java",
        '  OPENBSD("openbsd", "OpenBSD"),\n',
        '  OPENBSD("openbsd", "OpenBSD"),\n'
        '  NETBSD("netbsd", "NetBSD"),\n'
        '  DRAGONFLY("dragonfly", "DragonFly"),\n',
    ),
    (
        "src/main/java/com/google/devtools/build/lib/util/OS.java",
        "EnumSet.of(DARWIN, FREEBSD, OPENBSD, LINUX)",
        "EnumSet.of(DARWIN, FREEBSD, OPENBSD, NETBSD, DRAGONFLY, LINUX)",
    ),
    (
        "src/main/java/com/google/devtools/build/lib/jni/JniLoader.java",
        "case LINUX, FREEBSD, OPENBSD, UNKNOWN -> {",
        "case LINUX, FREEBSD, OPENBSD, NETBSD, DRAGONFLY, UNKNOWN -> {",
    ),
    (
        "src/main/java/com/google/devtools/build/lib/bazel/rules/BazelRuleClassProvider.java",
        '          .put(OS.OPENBSD, PathFragment.create("/usr/local/bin/bash"))\n',
        '          .put(OS.OPENBSD, PathFragment.create("/usr/local/bin/bash"))\n'
        '          .put(OS.NETBSD, PathFragment.create("/usr/pkg/bin/bash"))\n'
        '          .put(OS.DRAGONFLY, PathFragment.create("/usr/local/bin/bash"))\n',
    ),
    (
        "src/main/java/com/google/devtools/build/lib/bazel/rules/BazelRuleClassProvider.java",
        "if (os == OS.FREEBSD || os == OS.OPENBSD) {",
        "if (os == OS.FREEBSD || os == OS.OPENBSD || os == OS.NETBSD"
        " || os == OS.DRAGONFLY) {",
    ),
    (
        "src/main/java/com/google/devtools/build/lib/analysis/config/AutoCpuConverter.java",
        '        case OPENBSD -> "openbsd";\n',
        '        case OPENBSD -> "openbsd";\n'
        '        case NETBSD -> "netbsd";\n'
        '        case DRAGONFLY -> "dragonfly";\n',
    ),
    (
        "src/main/java/com/google/devtools/build/lib/runtime/ConfigExpander.java",
        '      case OPENBSD:\n        return "openbsd";\n',
        '      case OPENBSD:\n        return "openbsd";\n'
        '      case NETBSD:\n        return "netbsd";\n'
        '      case DRAGONFLY:\n        return "dragonfly";\n',
    ),
    (
        "src/main/java/com/google/devtools/build/lib/analysis/constraints/ConstraintConstants.java",
        "          OS.OPENBSD,\n",
        "          OS.OPENBSD,\n"
        "          ConstraintValueInfo.create(\n"
        "              OS_CONSTRAINT_SETTING,\n"
        '              Label.parseCanonicalUnchecked("@platforms//os:netbsd")),\n'
        "          OS.NETBSD,\n"
        "          ConstraintValueInfo.create(\n"
        "              OS_CONSTRAINT_SETTING,\n"
        '              Label.parseCanonicalUnchecked("@platforms//os:dragonfly")),\n'
        "          OS.DRAGONFLY,\n",
    ),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    hit = skipped = missing = 0
    for rel, old, new in SITES:
        p = os.path.join(root, rel)
        if not os.path.exists(p):
            print("  無い: %s" % rel)
            missing += 1
            continue
        s = open(p, encoding="utf-8").read()
        if new.split("\n")[0] in s and ("NETBSD" in s or "netbsd" in s):
            # 既に当たっている見込み。old がまだ在れば当て直す。
            if old not in s:
                skipped += 1
                continue
        if old not in s:
            print("  当てる場所が見つからない: %s" % rel)
            missing += 1
            continue
        open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
        hit += 1
    print("  当てた %d / 済み %d / 見つからない %d" % (hit, skipped, missing))
    if missing:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
