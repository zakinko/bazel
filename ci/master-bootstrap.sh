#!/bin/sh
# bazel の master を、踏み台の bazel 無しで BSD の上に起こす。
#
# master は git の木なので、compile.sh は dist archive のときと違って
# PROTOC と GRPC_JAVA_PLUGIN を要求する。
#
#	Must specify PROTOC if not bootstrapping from the distribution artifact
#	Must specify GRPC_JAVA_PLUGIN if not bootstrapping from the ...
#
# protoc は BSD の package に在る。無いのは Java の gRPC plugin の方で、
# grpc の package が配るのは grpc_cpp_plugin だけ、grpc-java が Maven に
# 置く出来合いは linux/osx/windows しか無い。C++ の二 file なので手で組む。
#
# これで release の dist archive も、package の古い bazel も要らなくなる。
set -eu

: "${JAVA_HOME:?}"
: "${JAVA_VER:?}"
W=${W:-$(pwd)}
SRC=${SRC:-$W/mst}

echo "=== 道具"
uname -a
"$JAVA_HOME/bin/java" -version 2>&1 | head -1

PROTOC=${PROTOC:-$(command -v protoc || true)}
[ -x "$PROTOC" ] || { echo "protoc が無い。package を入れる"; exit 1; }
"$PROTOC" --version

echo "=== protoc-gen-grpc-java を組む"
PLUGIN=$W/tools/protoc-gen-grpc-java
if [ ! -x "$PLUGIN" ]; then
	mkdir -p "$W/tools"
	rm -rf "$W/tools/grpc-java"
	# tag を固定する。HEAD は java::QualifiedClassName を呼ぶが、それが
	# 在るのは protobuf 30 以降で、DragonFly の dports は 29.3 が最新
	# なので通らない (java/names.h には ClassName しか無い)。release の
	# tag はどれもその API を使っていない。
	git clone -q --depth 1 -b "${GRPC_JAVA_TAG:-v1.76.0}" \
		https://github.com/grpc/grpc-java.git "$W/tools/grpc-java"
	cd "$W/tools/grpc-java/compiler/src/java_plugin/cpp"
	# pkg-config の cflags は protobuf 34 だと -DNOMINMAX を百回以上
	# 繰り返して返すが、害は無いのでそのまま渡す。
	CF=$(pkg-config --cflags protobuf 2>/dev/null || echo -I/usr/local/include)
	LF=$(pkg-config --libs protobuf 2>/dev/null || echo "-L/usr/local/lib -lprotobuf")
	${CXX:-clang++} -std=gnu++17 $CF java_generator.cpp java_plugin.cpp \
		-o "$PLUGIN" -lprotoc $LF
fi
ls -l "$PLUGIN"

echo "=== master を取る"
rm -rf "$SRC"
git clone -q --depth 1 https://github.com/bazelbuild/bazel.git "$SRC"
cd "$SRC"
git log --oneline -1

# rules_cc の BSD toolchain は -lm を繋がない。libc++ の __hash_table が
# ceilf を呼ぶので BSD ではリンクが通らない。#859。
if [ -n "${PATCH859:-}" ]; then
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
fi

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

# BUILD:345 が java_runtime に remotejdk_25 を名指ししている。remotejdk は
# BSD 向けが配られていないので、ここで toolchain の解決が失敗する。
# current_java_runtime は登録済みの runtime toolchain を引く alias。
sed -i.bak 's|"@rules_java//toolchains:remotejdk_25"|"@rules_java//toolchains:current_java_runtime"|' BUILD
grep -q "toolchains:current_java_runtime" BUILD || { echo "BUILD の書き換えが当たっていない"; exit 1; }

# cc_configure は BAZEL_CXXOPTS が無ければ -std=c++17 を既定にする。それだと
# __STRICT_ANSI__ が立ち、BSD の header が C99 と POSIX の名前を隠す。
# FreeBSD は libc++ の __locale が isascii で、DragonFly は libstdc++ の
# cwchar が vfwscanf で落ちる。repository rule なので client の環境を見る。
BAZEL_CXXOPTS=-std=gnu++17
export BAZEL_CXXOPTS

A="--java_runtime_version=local_jdk --tool_java_runtime_version=local_jdk"
A="$A --java_language_version=$JAVA_VER --tool_java_language_version=$JAVA_VER"
# rules_python が落とす CPython にも BSD 向けが無い。system の python3 を
# 使う toolchain を足す。
A="$A --extra_toolchains=@rules_python//python/runtime_env_toolchains:all"
A="$A --host_linkopt=-lm --linkopt=-lm"
A="$A --cxxopt=-std=gnu++17 --host_cxxopt=-std=gnu++17"

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
A="$A --copt=-include --copt=sys/cdefs.h"
A="$A --host_copt=-include --host_copt=sys/cdefs.h"
case "$(uname -s)" in
OpenBSD)
	# C++ のオブジェクトを C のドライバでリンクするので、C++ の
	# ランタイムを明示的に繋ぐ (undefined symbol: operator new)。
	for l in -lc++ -lc++abi -lpthread; do
		A="$A --host_linkopt=$l --linkopt=$l"
	done
	;;
DragonFly)
	;;
esac

if command -v go >/dev/null 2>&1; then
	A="$A --repo_env=GOROOT=$(go env GOROOT)"
fi
A="$A --action_env=PATH=$PATH --host_action_env=PATH=$PATH --jobs=${JOBS:-2}"

ulimit -n unlimited 2>/dev/null || ulimit -n 8192 2>/dev/null || true
ulimit -d unlimited 2>/dev/null || true

# compile.sh の run() は既定で各段の出力を溜めて、失敗したときだけ吐く。
# その一時 file は atexit で消えるので、途中で SIGABRT を食らうと何も残らない。
export VERBOSE=yes
export EXTRA_BAZEL_ARGS="$A"
echo "EXTRA_BAZEL_ARGS=$EXTRA_BAZEL_ARGS"

# compile.sh の protoc は third_party/remoteapis を -I に入れているが、そこの
# proto が import する googleapis の proto は木の中に無い。
#
#	remote_execution.proto:20:1: Import "google/api/annotations.proto"
#	  was not found or had errors.
#	remote_asset.proto:23:1: Import "google/rpc/status.proto" ...
#
# dist archive では derived/src/java が生成済みなのでこの経路を通らない。
# git の木から起こす道だけが壊れている。-Ithird_party/remoteapis/ は既に
# 渡されているので、その下に置けば compile.sh を触らずに済む。
echo "=== googleapis の proto を置く"
GAPI=$SRC/third_party/remoteapis/google
if [ ! -f "$GAPI/rpc/status.proto" ]; then
	mkdir -p "$GAPI/api" "$GAPI/rpc" "$GAPI/longrunning"
	B=https://raw.githubusercontent.com/googleapis/googleapis/master/google
	for f in api/annotations.proto api/http.proto api/client.proto \
		 api/field_behavior.proto api/launch_stage.proto \
		 api/resource.proto rpc/status.proto rpc/code.proto \
		 longrunning/operations.proto; do
		curl -sfL -o "$GAPI/$f" "$B/$f" ||
			{ echo "$f を取れない"; exit 1; }
	done
	ls -R "$GAPI" | head -20
fi

# src/main/protobuf/project/*.proto が Google 内部の proto を import している。
#
#	import "devtools/starlark/protolark/proto/protolark.proto";
#	string name = 1 [(.protolark.used_in_blaze) = true];
#
# その file は木に無く、公開もされていない。compile.sh の PROTO_FILES は
# src/main/protobuf を find するので必ず当たり、protoc がそこで落ちる。
# 9.2.0 の木にも同じ形で入っているので、git から起こす道は前から通らない。
#
# 使われているのは field への注記一つだけなので、同じ名前の extension を
# 立てた stub を置けば protoc は通る。生成される Java は custom option を
# 一つ余分に持つが、bazel はそれを読まない。番号は内部のものと合わない
# はずだが、この木の中だけで閉じているので構わない。
echo "=== protolark の stub を置く"
PL=$SRC/third_party/remoteapis/devtools/starlark/protolark/proto
mkdir -p "$PL"
cat > "$PL/protolark.proto" <<'PROTOLARK'
syntax = "proto2";

package protolark;

import "google/protobuf/descriptor.proto";

// 上流の木には in-house の protolark.proto が無い。使われているのは
// この注記だけなので、bootstrap を通すためだけの替え玉である。
extend google.protobuf.FieldOptions {
  optional bool used_in_blaze = 525000;
}
PROTOLARK

echo "=== 起こす"
PROTOC="$PROTOC" GRPC_JAVA_PLUGIN="$PLUGIN" "${BAZEL_SH:-bash}" ./compile.sh
./output/bazel --version

# --version は client だけで答えられるので、建ったこと以上を意味しない。
# server が上がって action が一つ走るところまで見る。
echo "=== 動かす"
smoke=$W/smoke
rm -rf "$smoke"; mkdir -p "$smoke"; cd "$smoke"
: > MODULE.bazel
cat > BUILD <<'SMOKE'
genrule(
    name = "hi",
    outs = ["hi.txt"],
    cmd = "uname -sr > $@",
)
SMOKE
"$SRC/output/bazel" build //:hi
cat bazel-bin/hi.txt
