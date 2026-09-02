#!/bin/sh
# bazel の master を BSD で建てる。
#
# master は git の木なので compile.sh は使えない (dist archive を落とせと
# 言って止まる)。踏み台の bazel が要るので、その path を $B で渡す。
# package に bazel が無い BSD では ci/bsd-bootstrap.sh が 9.2.0 を建てて
# くれるので、その output/bazel を $B にする。
set -eu

: "${B:?B (踏み台の bazel) が要る}"
: "${JAVA_HOME:?}"
: "${JAVA_VER:?}"
: "${PATCH859:?rules_cc #859 の当て物の path}"

SRC=${SRC:-/root/mst}

echo "=== 踏み台"
"$B" --version

echo "=== master を取る"
rm -rf "$SRC"
git clone -q --depth 1 https://github.com/bazelbuild/bazel.git "$SRC"
cd "$SRC"
git log --oneline -1

# rules_cc の BSD toolchain は -lm を繋がない。libc++ の __hash_table が
# ceilf を呼ぶので、BSD では libm を明示しないとリンクが通らない。#859。
mkdir -p toolchain_local
cp "$PATCH859" toolchain_local/rules_cc_859.patch
: > toolchain_local/BUILD
cat >> MODULE.bazel <<'M'

single_version_override(
    module_name = "rules_cc",
    patch_strip = 1,
    patches = ["//toolchain_local:rules_cc_859.patch"],
)
M

# master の .bazelrc は --java_runtime_version=remotejdk_25 を指す。remotejdk
# は Linux/macOS/Windows 向けしか配布されていないので、BSD では
#
#	While resolving toolchains for target //src/main/java/...:BazelServer
#	No matching toolchains found for types:
#	  @@bazel_tools//tools/jdk:runtime_toolchain_type
#
# になる。--tool_ の方だけ書き換えても target 側が remotejdk のままなので
# 解決は失敗する。両方を local_jdk にする。
#
# python も同じ形。MODULE.bazel の python.toolchain() は rules_python が
# 落とす CPython を使うが、これにも BSD 向けが無い。rules_pkg の build_tar が
#
#	No matching toolchains found for types:
#	  @@bazel_tools//tools/python:toolchain_type
#
# で落ちる。system の python3 を使う runtime_env_toolchains を足す。
# bazel 自身の java_toolchain は BUILD で remotejdk_25 を名指ししている。
#
#	default_java_toolchain(
#	    name = "java_toolchain_%s" % language_version,
#	    java_runtime = "@rules_java//toolchains:remotejdk_25",
#
# remotejdk が配られているのは Linux/macOS/Windows だけなので、BSD では
#
#	While resolving toolchains for target @@rules_java+//toolchains:remotejdk_25
#	No matching toolchains found for types:
#	  @@bazel_tools//tools/jdk:runtime_toolchain_type
#
# になる。--java_runtime_version はこの名指しを上書きしないので flag では
# 避けられない。current_java_runtime は登録済みの runtime toolchain を引く
# alias なので、JDK 25 の在る箱でも 21 しか無い箱でも同じように通る。
# 言語版は BUILD が 8 / 21 / 25 を定義しているので、21 は正規の値である。
sed -i.bak 's|"@rules_java//toolchains:remotejdk_25"|"@rules_java//toolchains:current_java_runtime"|' BUILD
grep -q "toolchains:current_java_runtime" BUILD || { echo "BUILD の書き換えが当たっていない"; exit 1; }

FLAGS="--java_runtime_version=local_jdk --tool_java_runtime_version=local_jdk"
FLAGS="$FLAGS --java_language_version=$JAVA_VER"
FLAGS="$FLAGS --tool_java_language_version=$JAVA_VER"
FLAGS="$FLAGS --extra_toolchains=@rules_python//python/runtime_env_toolchains:all"
FLAGS="$FLAGS --host_linkopt=-lm --linkopt=-lm"

case "$(uname -s)" in
OpenBSD)
	# C++ のオブジェクトを C のドライバでリンクするので、C++ の
	# ランタイムを明示的に繋ぐ (undefined symbol: operator new)。
	for l in -lc++ -lc++abi -lpthread; do
		FLAGS="$FLAGS --host_linkopt=$l --linkopt=$l"
	done
	;;
DragonFly)
	# base の cc は gcc 8.3 で libstdc++ が C++17 に足りない。clang を
	# 使い、module map 経由で libstdc++ を読ませない。
	FLAGS="$FLAGS --repo_env=BAZEL_CXXOPTS=-std=gnu++17"
	FLAGS="$FLAGS --host_action_env=BAZEL_CXXOPTS=-std=gnu++17"
	FLAGS="$FLAGS --cxxopt=-std=gnu++17 --host_cxxopt=-std=gnu++17"
	FLAGS="$FLAGS --features=-layering_check --host_features=-layering_check"
	FLAGS="$FLAGS --features=-module_maps --host_features=-module_maps"
	;;
esac

# action は env - で起動されるので PATH を明示的に渡す。exec 側には
# --host_action_env でないと届かない。
FLAGS="$FLAGS --action_env=PATH=$PATH --host_action_env=PATH=$PATH"

# OpenBSD の既定の記述子上限では bazel が Too many open files で落ちる。
ulimit -n unlimited 2>/dev/null || ulimit -n 4096 2>/dev/null || true
ulimit -d unlimited 2>/dev/null || true

echo "=== 建てる"
echo "flags: $FLAGS"
# shellcheck disable=SC2086
"$B" build //src:bazel $FLAGS --jobs=2

echo "=== 動かす"
./bazel-bin/src/bazel --version
