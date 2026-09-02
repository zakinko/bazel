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
	git clone -q --depth 1 https://github.com/grpc/grpc-java.git "$W/tools/grpc-java"
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

# 落ちているのは C++ の方言ではなく modules である。bazel は layering_check の
# ために module map を渡すが、その経由で libc++ の __locale が <ctype.h> を
# 読むと、BSD 拡張の isascii が見えなくなる。
#
#	/usr/include/c++/v1/__locale:530:12:
#	  error: use of undeclared identifier 'isascii'
#
# bazel と同じ flag を手で並べて clang に食わせると通るので、-std=c++17 は
# 無実だった。DragonFly でも同じ順で誤診し、同じ対処で直っている。
A="$A --features=-layering_check --host_features=-layering_check"
A="$A --features=-module_maps --host_features=-module_maps"

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
