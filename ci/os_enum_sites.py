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
import io
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
    (
        "src/conditions/BUILD",
        'config_setting(\n    name = "openbsd",\n'
        '    constraint_values = ["@platforms//os:openbsd"],\n'
        '    visibility = ["//visibility:public"],\n)\n',
        'config_setting(\n    name = "openbsd",\n'
        '    constraint_values = ["@platforms//os:openbsd"],\n'
        '    visibility = ["//visibility:public"],\n)\n\n'
        'config_setting(\n    name = "netbsd",\n'
        '    constraint_values = ["@platforms//os:netbsd"],\n'
        '    visibility = ["//visibility:public"],\n)\n\n'
        'config_setting(\n    name = "dragonfly",\n'
        '    constraint_values = ["@platforms//os:dragonfly"],\n'
        '    visibility = ["//visibility:public"],\n)\n',
    ),
    (
        "src/main/cpp/BUILD",
        '        "//src/conditions:openbsd": [\n        ],\n'
        '        "//src/conditions:windows": WIN_LINK_OPTS,\n',
        '        "//src/conditions:openbsd": [\n        ],\n'
        '        "//src/conditions:netbsd": [\n        ],\n'
        '        "//src/conditions:dragonfly": [\n        ],\n'
        '        "//src/conditions:windows": WIN_LINK_OPTS,\n',
    ),
    (
        "src/main/cpp/BUILD",
        '        "//src/conditions:openbsd": [\n        ],\n'
        '        "//src/conditions:windows": [\n        ],\n',
        '        "//src/conditions:openbsd": [\n        ],\n'
        '        "//src/conditions:netbsd": [\n        ],\n'
        '        "//src/conditions:dragonfly": [\n'
        '            "-lm",\n'
        '        ],\n'
        '        "//src/conditions:windows": [\n        ],\n',
    ),
    (
        "src/main/tools/BUILD",
        '        "//src/conditions:openbsd": ["dummy-sandbox.c"],\n',
        '        "//src/conditions:openbsd": ["dummy-sandbox.c"],\n'
        '        "//src/conditions:netbsd": ["dummy-sandbox.c"],\n'
        '        "//src/conditions:dragonfly": ["dummy-sandbox.c"],\n',
    ),
    (
        "src/main/native/BUILD",
        '        "//src/conditions:openbsd": '
        '"@rules_java//toolchains:jni_md_header-openbsd",\n',
        '        "//src/conditions:openbsd": '
        '"@rules_java//toolchains:jni_md_header-openbsd",\n'
        '        "//src/conditions:netbsd": '
        '"@rules_java//toolchains:jni_md_header-netbsd",\n'
        '        "//src/conditions:dragonfly": '
        '"@rules_java//toolchains:jni_md_header-dragonfly",\n',
    ),
    (
        "src/conditions/BUILD.tools",
        'config_setting(\n    name = "openbsd",\n'
        '    constraint_values = ["@platforms//os:openbsd"],\n',
        'config_setting(\n    name = "netbsd",\n'
        '    constraint_values = ["@platforms//os:netbsd"],\n'
        '    visibility = ["//visibility:public"],\n)\n\n'
        'config_setting(\n    name = "dragonfly",\n'
        '    constraint_values = ["@platforms//os:dragonfly"],\n'
        '    visibility = ["//visibility:public"],\n)\n\n'
        'config_setting(\n    name = "openbsd",\n'
        '    constraint_values = ["@platforms//os:openbsd"],\n',
    ),
    (
        "tools/jdk/BUILD.tools",
        '    "jni_md_header-openbsd",\n',
        '    "jni_md_header-netbsd",\n'
        '    "jni_md_header-dragonfly",\n'
        '    "jni_md_header-openbsd",\n',
    ),
    (
        "third_party/BUILD",
        '    "//src/conditions:openbsd": "*.so *.jnilib *.dll *.pyd",\n',
        '    "//src/conditions:netbsd": "*.so *.jnilib *.dll *.pyd",\n'
        '    "//src/conditions:dragonfly": "*.so *.jnilib *.dll *.pyd",\n'
        '    "//src/conditions:openbsd": "*.so *.jnilib *.dll *.pyd",\n',
    ),
    (
        "src/main/cpp/util/md5.h",
        "#elif defined(__FreeBSD__) || defined(__OpenBSD__)\n"
        "#include <sys/endian.h>\n",
        "#elif defined(__FreeBSD__) || defined(__OpenBSD__) || "
        "defined(__NetBSD__) || \\\n    defined(__DragonFly__)\n"
        "#include <sys/endian.h>\n",
    ),
    (
        "src/tools/singlejar/diag.h",
        "defined(__OpenBSD__)",
        "defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__)",
    ),
    (
        "src/tools/singlejar/mapped_file_posix.inc",
        "defined(__OpenBSD__)) &&",
        "defined(__OpenBSD__) || defined(__NetBSD__) || "
        "defined(__DragonFly__)) &&",
    ),
    (
        "src/tools/singlejar/zip_headers.h",
        "#elif defined(__FreeBSD__) || defined(__OpenBSD__)",
        "#elif defined(__FreeBSD__) || defined(__OpenBSD__) || "
        "defined(__NetBSD__) || defined(__DragonFly__)",
    ),
    (
        "src/main/native/BUILD",
        '        "//src/conditions:openbsd": ["unix_jni_bsd.cc"],\n',
        '        "//src/conditions:openbsd": ["unix_jni_bsd.cc"],\n'
        '        "//src/conditions:netbsd": ["unix_jni_bsd.cc"],\n'
        '        "//src/conditions:dragonfly": ["unix_jni_bsd.cc"],\n',
    ),
    (
        "src/main/cpp/BUILD",
        '        "//src/conditions:openbsd": [\n'
        '            "blaze_util_bsd.cc",\n'
        '            "blaze_util_posix.cc",\n'
        '        ],\n',
        '        "//src/conditions:openbsd": [\n'
        '            "blaze_util_bsd.cc",\n'
        '            "blaze_util_posix.cc",\n'
        '        ],\n'
        '        "//src/conditions:netbsd": [\n'
        '            "blaze_util_bsd.cc",\n'
        '            "blaze_util_posix.cc",\n'
        '        ],\n'
        '        "//src/conditions:dragonfly": [\n'
        '            "blaze_util_bsd.cc",\n'
        '            "blaze_util_posix.cc",\n'
        '        ],\n',
    ),
    (
        "src/main/cpp/blaze_util_bsd.cc",
        '#elif defined(__OpenBSD__)\n'
        '#define STANDARD_JAVABASE "/usr/local/jdk-21"\n',
        '#elif defined(__OpenBSD__)\n'
        '#define STANDARD_JAVABASE "/usr/local/jdk-21"\n'
        '#elif defined(__NetBSD__)\n'
        '# define STANDARD_JAVABASE "/usr/pkg/java/openjdk21"\n'
        '#elif defined(__DragonFly__)\n'
        '# define STANDARD_JAVABASE "/usr/local/openjdk21"\n',
    ),
    (
        "src/main/cpp/blaze_util_bsd.cc",
        "  struct statfs buf = {};\n"
        "  if (statfs(output_base.AsNativePath().c_str(), &buf) < 0) {\n",
        "#if defined(__NetBSD__)\n"
        "  // NetBSD dropped statfs(2); statvfs(2) carries f_fstypename all\n"
        "  // the same.\n"
        "  struct statvfs buf = {};\n"
        "  if (statvfs(output_base.AsNativePath().c_str(), &buf) < 0) {\n"
        "#else\n"
        "  struct statfs buf = {};\n"
        "  if (statfs(output_base.AsNativePath().c_str(), &buf) < 0) {\n"
        "#endif\n",
    ),
    (
        "src/main/cpp/blaze_util_bsd.cc",
        "#elif defined(__OpenBSD__)\n"
        "  // OpenBSD does not provide a way for a running process to find a"
        " path to its\n",
        "#elif defined(__OpenBSD__) || defined(__NetBSD__) || "
        "defined(__DragonFly__)\n"
        "  // OpenBSD does not provide a way for a running process to find a"
        " path to its\n",
    ),
]


# 当てた後に結果の側を見る。site の並びから項目が落ちても count は減った数を
# 「全部当たった」と報告するだけなので、当てた数では守れない。実際に
# src/conditions/BUILD と src/main/native/BUILD の二つが並びから消えていて、
#
#	当てた 18 / 済み 0 / 見つからない 0
#
# と出たまま //src/conditions:dragonfly が宣言されず、select の解決で落ちた。
VERIFY = [
    ("src/conditions/BUILD", ['name = "netbsd"', 'name = "dragonfly"']),
    ("src/conditions/BUILD.tools", ['name = "netbsd"', 'name = "dragonfly"']),
    ("src/main/native/BUILD",
     ["jni_md_header-netbsd", "jni_md_header-dragonfly",
      '"//src/conditions:netbsd": ["unix_jni_bsd.cc"]']),
    ("tools/jdk/BUILD.tools", ["jni_md_header-netbsd", "jni_md_header-dragonfly"]),
    ("third_party/BUILD", ["//src/conditions:netbsd", "//src/conditions:dragonfly"]),
    ("src/main/cpp/BUILD", ["//src/conditions:netbsd", "//src/conditions:dragonfly"]),
    ("src/main/tools/BUILD",
     ["//src/conditions:netbsd", "//src/conditions:dragonfly"]),
    ("src/main/cpp/blaze_util_bsd.cc", ["__NetBSD__", "__DragonFly__"]),
    ("src/main/cpp/util/md5.h", ["__NetBSD__", "__DragonFly__"]),
    ("src/tools/singlejar/diag.h", ["__NetBSD__", "__DragonFly__"]),
    ("src/tools/singlejar/mapped_file_posix.inc",
     ["__NetBSD__", "__DragonFly__"]),
    ("src/tools/singlejar/zip_headers.h", ["__NetBSD__", "__DragonFly__"]),
    ("src/main/java/com/google/devtools/build/lib/util/OS.java",
     ["NETBSD", "DRAGONFLY"]),
    ("src/main/java/com/google/devtools/build/lib/jni/JniLoader.java",
     ["NETBSD", "DRAGONFLY"]),
]


def verify(root):
    bad = 0
    for rel, needles in VERIFY:
        p = os.path.join(root, rel)
        if not os.path.exists(p):
            print("  確かめられない (file が無い): %s" % rel)
            bad += 1
            continue
        s = io.open(p, encoding="utf-8", errors="surrogateescape").read()
        for n in needles:
            if n not in s:
                print("  当たっていない: %s に %s" % (rel, n))
                bad += 1
    return bad


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
            # 既に当たっている木をもう一度通したときに、当て物の形によっては
            # 上の見込みで拾えない。VERIFY の側で見て、入っていれば済み。
            need = dict(VERIFY).get(rel)
            if need and all(n in s for n in need):
                skipped += 1
                continue
            print("  当てる場所が見つからない: %s" % rel)
            missing += 1
            continue
        open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
        hit += 1
    print("  当てた %d / 済み %d / 見つからない %d" % (hit, skipped, missing))
    bad = verify(root)
    if bad:
        print("  結果の確認で %d 件が足りない" % bad)
        return 1
    if missing:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
