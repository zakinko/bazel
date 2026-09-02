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


# rules_python の runtime_env の launcher は sh -c の中の $@ を引用符で
# 括っていないので、空白を含む引数が割れる。bazel 自身の proguard_jar が
#
#	args.add("--timestamp", "1980-01-01 00:00:00")
#
# を渡すので、wrapper.py が
#
#	wrapper.py: error: unrecognized arguments: 00:00:00
#
# で落ちる。出来合いの CPython が在る platform では runtime_env の launcher を
# 通らないので、BSD でだけ出る。
if [ -n "${PATCH_RULES_PYTHON:-}" ]; then
	cp "$PATCH_RULES_PYTHON" toolchain_local/rules_python_quote_args.patch
	cat >> MODULE.bazel <<'M'

single_version_override(
    module_name = "rules_python",
    patch_strip = 1,
    patches = ["//toolchain_local:rules_python_quote_args.patch"],
)
M
fi
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

# cc_configure は BAZEL_CXXOPTS が無ければ -std=c++17 を既定にする。それだと
# __STRICT_ANSI__ が立ち、BSD の header が C99 と POSIX の名前を隠す。FreeBSD
# では libc++ の __locale がその一つを使っていて、protobuf がそこで落ちる。
#
#	/usr/include/c++/v1/__locale:530:12:
#	  error: use of undeclared identifier 'isascii'
#
# gnu++17 なら __STRICT_ANSI__ が立たないので header がそれらを出す。最初は
# DragonFly だけの話だと思っていたが、同じ根が FreeBSD にもあった。
# cc_configure は repository rule なので、client の環境変数を見る。flag だけ
# だと target 構成には届くが exec 構成には届かず、落ちたのは [for tool] の
# 側だった。DragonFly で効いていた形は export のほうである。
BAZEL_CXXOPTS=-std=gnu++17
export BAZEL_CXXOPTS
FLAGS="$FLAGS --repo_env=BAZEL_CXXOPTS=-std=gnu++17"
FLAGS="$FLAGS --host_action_env=BAZEL_CXXOPTS=-std=gnu++17"
FLAGS="$FLAGS --cxxopt=-std=gnu++17 --host_cxxopt=-std=gnu++17"

# pkgsrc も dports も go を PATH に置かず /usr/pkg/go1NN や /usr/local/go1NN に
# 入れる。版の大きい方から見る。glob は昇順なので素直に先頭を採ると一番古い
# ものを掴む。
if ! command -v go >/dev/null 2>&1; then
	for d in $(ls -d /usr/pkg/go1* /usr/local/go1* /usr/local/go 2>/dev/null | sort -r); do
		if [ -x "$d/bin/go" ]; then
			PATH="$d/bin:$PATH"
			export PATH
			break
		fi
	done
fi
if command -v go >/dev/null 2>&1; then
	FLAGS="$FLAGS --repo_env=GOROOT=$(go env GOROOT)"
fi

# isascii が見えなくなるのは protobuf 自身の仕業である。
#
#	protobuf/src/google/protobuf/io/zero_copy_stream_impl.cc:13
#	#define _POSIX_C_SOURCE 202405L
#
# これが立つと FreeBSD の sys/cdefs.h が __BSD_VISIBLE を 0 にし、ctype.h が
# isascii を出さなくなる。同じ file が後から <istream> を読み、libc++ の
# <locale> が isascii を使うので、そこで落ちる。
#
#	/usr/include/c++/v1/__locale:530:12:
#	  error: use of undeclared identifier 'isascii'
#
# Linux では出ない。libstdc++ は isascii を使わないためで、FreeBSD 系と
# libc++ の組でだけ現れる。
#
# 命令行の -U_POSIX_C_SOURCE では消せない。#define が source の側に在って、
# 命令行より後に効くからである。sys/cdefs.h には include guard が在るので、
# 先に読ませておくと __BSD_VISIBLE が 1 のまま固定され、後の #define が
# 何も変えられなくなる。
#
# 三度読み違えた。-std=c++17 のせいだと思い、次に module map のせいだと思い、
# 実際は source の #define だった。手で clang に食わせて切り分けた結果が
# これで、8 件 → 0 件になる。
FLAGS="$FLAGS --copt=-include --copt=sys/cdefs.h"
FLAGS="$FLAGS --host_copt=-include --host_copt=sys/cdefs.h"
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
	# 使う。module map 経由でその libstdc++ を読むと <cwchar> が壊れる
	# ので、そちらも落とす。これは isascii とは別の話である。
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

# //src:bazel は JDK を binary に埋め込む。埋め込む JDK は remote JDK の
# 書庫から来るので BSD 向けが無く、Linux の jlink を走らせようとして
#
#	src/BUILD:244:8: Executing genrule //src:embedded_jdk_minimal failed
#	minimize_jdk: line 167: ../tool_jdk.4338/bin/jlink:
#	  cannot execute binary file: Exec format error
#
# になる。compile.sh がどの platform でも建てるのは bazel_nojdk の方で、
# FreeBSD の devel/bazel9 が配っているのもそれである。
TARGET=${TARGET:-//src:bazel_nojdk}

echo "=== 建てる"
echo "target: $TARGET"
echo "flags: $FLAGS"
# shellcheck disable=SC2086
"$B" build $TARGET $FLAGS --jobs=${JOBS:-2}

echo "=== 動かす"
OUT=$("$B" cquery --output=files $TARGET $FLAGS 2>/dev/null | head -1)
echo "できたもの: $OUT"
"$OUT" --version
