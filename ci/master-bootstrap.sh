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
# この script が入っている木。fetch-maven.py を隣から呼ぶ。
BZ=${BZ:-$(cd "$(dirname "$0")/.." && pwd)}

echo "=== 道具"
uname -a
"$JAVA_HOME/bin/java" -version 2>&1 | head -1

PROTOC=${PROTOC:-$(command -v protoc || true)}
[ -x "$PROTOC" ] || { echo "protoc が無い。package を入れる"; exit 1; }
"$PROTOC" --version

# 建てる版は 31.1 にする。protobuf は MODULE.bazel で abseil の版を指していて
#
#	34.1 → abseil 20250512.1
#	31.1 → abseil 20250127.0   ← DragonFly の package はこれ
#
# 合わない版を組むと、link 行に 92 本の libabsl を全部並べても
#
#	undefined reference to
#	  absl::lts_20250127::log_internal::LogMessage::operator<<<int>
#
# が残る。記号が library に無いのだから、繋ぎ方の問題ではない。31.1 は 30 以上
# なので java::QualifiedClassName を持ち、EDITION_2024 も知っている。
#
# protobuf が 30 より古いと二つ足りない。grpc-java の HEAD が呼ぶ
# java::QualifiedClassName が無く、libprotoc が java::ClassName を export
# もしていない (header には在るのに .so に出ていない)。DragonFly の dports は
# 29.3 が最新なので、そこだけ source から組む。静的に組めば visibility に
# 関わらず記号が取れる。
PBMAJ=$("$PROTOC" --version | awk '{print $2}' | cut -d. -f1)
if [ "${PBMAJ:-0}" -lt 30 ]; then
	echo "=== protobuf $PBMAJ は古い。${PB_VER:-31.1} を source から組む"
	PB=$W/pbsrc
	if [ ! -f "$PB/protobuf/b/protoc" ]; then
		mkdir -p "$PB" && cd "$PB"
		rm -rf protobuf
		git clone -q --depth 1 -b "v${PB_VER:-31.1}" \
			https://github.com/protocolbuffers/protobuf.git protobuf
		mkdir -p protobuf/b && cd protobuf/b
		# protobuf の cmake は absl を find_package で引くが、protoc の
		# link 行に log_internal の実体が乗らず
		#
		#	undefined reference to
		#	  absl::lts_20250127::log_internal::LogMessage::operator<<
		#
		# になる。package の absl は 92 本の共有ライブラリに分かれて
		# いるので、まとめて繋いでしまう。
		# package の absl では駄目だった。31.1 が指す 20250127.0 と
		# 同じ版を入れても、libabsl_log_internal_message.so に
		#
		#	LogMessage::operator<<<int>  (enable_if つきの template)
		#
		# の実体が無い。dports がどう組んだかは分からないが、記号が
		# library に無いのだから繋ぎ方では解けない。abseil も source
		# から入れて、header と library の出所を一つに揃える。
		AP=$PB/absl-prefix
		if [ ! -f "$AP/lib/libabsl_log_internal_message.a" ]; then
			ABV=$(sed -n 's/.*name = "abseil-cpp", version = "\([0-9.]*\)".*/\1/p' \
				"$PB/protobuf/MODULE.bazel" 2>/dev/null | head -1)
			ABV=${ABV:-20250127.0}
			echo "  abseil $ABV を source から入れる"
			rm -rf "$PB/absl"
			git clone -q --depth 1 -b "$ABV" \
				https://github.com/abseil/abseil-cpp.git "$PB/absl"
			mkdir -p "$PB/absl/b" && cd "$PB/absl/b"
			cmake -G Ninja .. -DCMAKE_BUILD_TYPE=Release \
				-DCMAKE_CXX_STANDARD=17 \
				-DABSL_PROPAGATE_CXX_STD=ON \
				-DBUILD_TESTING=OFF \
				-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
				-DCMAKE_INSTALL_PREFIX="$AP" > cmake.log 2>&1 ||
				{ tail -20 cmake.log; exit 1; }
			ninja -j"${JOBS:-2}" > build.log 2>&1 ||
				{ tail -25 build.log; exit 1; }
			ninja install > install.log 2>&1 ||
				{ tail -20 install.log; exit 1; }
			cd "$PB/protobuf/b"
		fi
		ABSLALL=""
		cmake -G Ninja .. -DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_PREFIX_PATH="$AP" \
			-DCMAKE_CXX_STANDARD=17 \
			-Dprotobuf_BUILD_TESTS=OFF \
			-Dprotobuf_BUILD_SHARED_LIBS=OFF \
			-Dprotobuf_ABSL_PROVIDER=package \
			-DCMAKE_POSITION_INDEPENDENT_CODE=ON > cmake.log 2>&1 ||
			{ tail -25 cmake.log; exit 1; }
		ninja -j"${JOBS:-2}" protoc libprotoc.a libprotobuf.a > build.log 2>&1 ||
			{ tail -30 build.log; exit 1; }
	fi
	PROTOC=$PB/protobuf/b/protoc
	PB_INC="-I$PB/protobuf/src"
	PB_LIB="$PB/protobuf/b/libprotoc.a $PB/protobuf/b/libprotobuf.a"
	PB_ABSL=$AP
	"$PROTOC" --version
	cd "$W"
fi

echo "=== protoc-gen-grpc-java を組む"
PLUGIN=$W/tools/protoc-gen-grpc-java
if [ ! -x "$PLUGIN" ]; then
	mkdir -p "$W/tools"
	rm -rf "$W/tools/grpc-java"
	# HEAD を使う。release の tag (v1.76.0 まで) は edition 2024 を
	# 宣言しておらず、master の proto を渡すと
	#
	#	execution_graph_writer.proto: is a file using edition 2024,
	#	  which isn't supported by code generator protoc-gen-grpc
	#
	# で落ちる。HEAD は java::QualifiedClassName を呼ぶので protobuf 30
	# 以降が要るが、それは下で面倒を見る。
	git clone -q --depth 1 ${GRPC_JAVA_TAG:+-b $GRPC_JAVA_TAG} \
		https://github.com/grpc/grpc-java.git "$W/tools/grpc-java"
	cd "$W/tools/grpc-java/compiler/src/java_plugin/cpp"
	# pkg-config の cflags は protobuf 34 だと -DNOMINMAX を百回以上
	# 繰り返して返すが、害は無いのでそのまま渡す。
	if [ -n "${PB_LIB:-}" ]; then
		# source から組んだ静的な libprotoc へ繋ぐ。abseil も同じ木の
		# ものを使う (package の版と混ぜると記号が食い違う)。
		# abseil も protobuf と同じ木のものを使う。package のものと
		# 混ぜると記号が食い違う。静的なので並び順が要る。
		ABL=$(ls "$PB_ABSL"/lib/libabsl_*.a 2>/dev/null | tr '\n' ' ')
		${CXX:-clang++} -std=gnu++17 $PB_INC -I"$PB_ABSL/include" \
			java_generator.cpp java_plugin.cpp \
			-o "$PLUGIN" $PB_LIB $ABL $ABL -lpthread
	else
		CF=$(pkg-config --cflags protobuf 2>/dev/null || echo -I/usr/local/include)
		LF=$(pkg-config --libs protobuf 2>/dev/null || echo "-L/usr/local/lib -lprotobuf")
		${CXX:-clang++} -std=gnu++17 $CF java_generator.cpp java_plugin.cpp \
			-o "$PLUGIN" -lprotoc $LF
	fi
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
# buildenv.sh は JAVA_VERSION=${JAVA_VERSION:-25} なので、環境変数で下げられる。
# 下げないと compile.sh が
#
#	ERROR: JDK version (1.21) is lower than 25, please set $JAVA_HOME.
#
# で止まる。pkgsrc も DragonFly の dports も openjdk21 が最新なので、そこでは
# 下げるしかない。BUILD が java_toolchain を 8 と 21 と 25 について定義して
# いるので、21 は正規の値である。master の Java の source が 21 で足りるか
# どうかは、下げて建ててみれば javac が答える。
JAVA_VERSION=$JAVA_VER
export JAVA_VERSION
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
# googleapis は MODULE.bazel が commit で固定している。master から取ると
# 版が食い違う。BCR の source.json が指す commit を使う。
GAC=$(sed -n 's/.*name = "googleapis", version = "0\.0\.0-[0-9]*-\([0-9a-f]*\)".*/\1/p' \
	"$SRC/MODULE.bazel" | head -1)
GAC=${GAC:-de157ca34fa487ce248eb9130293d630b501e4ad}
echo "  googleapis の commit: $GAC"
B=https://raw.githubusercontent.com/googleapis/googleapis/$GAC/google
if [ ! -f "$GAPI/rpc/status.proto" ]; then
	mkdir -p "$GAPI/api" "$GAPI/rpc" "$GAPI/longrunning" "$GAPI/bytestream"
	for f in api/annotations.proto api/http.proto api/client.proto \
		 api/field_behavior.proto api/launch_stage.proto \
		 api/resource.proto rpc/status.proto rpc/code.proto \
		 longrunning/operations.proto bytestream/bytestream.proto; do
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

# compile.sh は classpath を derived/jars と derived/maven から組むが、その
# 二つは dist archive にしか無い。git の木には derived/ が一つも無く、
# derived/maven の中身は //:maven-srcs という pkg_tar が作るものなので、
# 作るには bazel が要る。**bazel を建てるのに要る jar を bazel でしか作れない。**
#
# derived/jars が無いときの代替は tools/distributions/debian の一覧、つまり
# /usr/share の下の distro package で、BSD には無い。何も無いまま進むと
#
#	OptionsClassProcessor.java:68: error: cannot find symbol
#	  private ImmutableMap<TypeMirror, Converter<?>> defaultConverters;
#	  symbol: class ImmutableMap
#
# のように Guava から順に落ちる。
#
# 代わりの経路が一つある。maven_install.json は artifact と版と sha256 を
# 全部持っているので、Maven Central から直に取れる。141 個 83MB で、bazel も
# dist archive も要らない。
echo "=== maven の jar を取る"
python3 "$BZ/ci/fetch-maven.py" "$SRC" "$SRC/derived/maven"

# maven_install.json に載っていない jar が二つ要る。どちらも本来は
# derived/jars に入っているもの、つまり bazel が module から建てたものである。
# Maven Central に同じものが在るので直に取る。版は木が指しているものに合わせる。
#
#	protobuf-java-util  maven_install.json の protobuf-java と同じ版
#	zstd-jni            MODULE.bazel の bazel_dep が指す版
echo "=== derived/jars の代わりを取る"
PBV=$(python3 -c "import json;print(json.load(open('$SRC/maven_install.json'))['artifacts']['com.google.protobuf:protobuf-java']['version'])")
ZSV=$(sed -n 's/.*name = "zstd-jni", version = "\([^"]*\)".*/\1/p' "$SRC/MODULE.bazel" | head -1 | sed 's/\.bcr\.[0-9]*$//')
mkdir -p "$SRC/derived/maven/extra"

# maven_install.json の io.grpc は 1.66.0 だが、plugin は HEAD しか使えない
# (edition 2024 を宣言しているのは HEAD だけ)。HEAD が生成する stub は
#
#	ContentAddressableStorageGrpc.java:1467: error: cannot find symbol
#	  io.grpc.stub.BlockingClientCall<?, ...>
#
# のように新しい API を呼ぶので、runtime も上げないと合わない。MODULE.bazel は
# grpc-java 1.71.0 を指していて maven_install.json とそこもずれている。
# release の最新に揃える。
GRPCV=${GRPCV:-1.76.0}
echo "  io.grpc を $GRPCV に揃える"
find "$SRC/derived/maven" -path '*/io/grpc/*' -name '*.jar' -delete 2>/dev/null
for a in grpc-api grpc-auth grpc-context grpc-core grpc-inprocess grpc-netty \
	 grpc-protobuf grpc-protobuf-lite grpc-stub grpc-util; do
	u="https://repo1.maven.org/maven2/io/grpc/$a/$GRPCV/$a-$GRPCV.jar"
	[ -s "$SRC/derived/maven/extra/$a-$GRPCV.jar" ] ||
		curl -sfL -o "$SRC/derived/maven/extra/$a-$GRPCV.jar" "$u" ||
		echo "取れない: $u"
done

# async-profiler は maven に無い。repositories.bzl が http_file で GitHub の
# release から取っている。同じものを取る。
APU=$(sed -n 's|.*"\(https://github.com/async-profiler/[^"]*async-profiler.jar\)".*|\1|p' \
	"$SRC/repositories.bzl" | head -1)
if [ -n "$APU" ]; then
	[ -s "$SRC/derived/maven/extra/async-profiler.jar" ] ||
		curl -sfL -o "$SRC/derived/maven/extra/async-profiler.jar" "$APU" ||
		echo "取れない: $APU"
fi

for u in \
  "https://repo1.maven.org/maven2/com/google/protobuf/protobuf-java-util/$PBV/protobuf-java-util-$PBV.jar" \
  "https://repo1.maven.org/maven2/com/github/luben/zstd-jni/$ZSV/zstd-jni-$ZSV.jar"; do
	f=$(basename "$u")
	[ -s "$SRC/derived/maven/extra/$f" ] ||
		curl -sfL -o "$SRC/derived/maven/extra/$f" "$u" ||
		echo "取れない: $u"
done
ls "$SRC/derived/maven/extra" | wc -l

# compile.sh の PROTO_FILES は木からずれている。serialization/analysis/proto の
# 下に proto が在るのに一覧へ入っていないので、そこから生成される Java が
# 出来ず、package ... does not exist で落ちる。find の対象を足す。
ADD="src/main/java/com/google/devtools/build/lib/skyframe/serialization/analysis/proto"
ADD="$ADD src/main/java/com/google/devtools/build/lib/sandbox/cgroups/proto"
# packages/metrics は package_load_metrics.proto だけが名指しされていて、
# 同じ場所の package_metrics.proto が漏れている。置き場ごと足す。
ADD="$ADD src/main/java/com/google/devtools/build/lib/packages/metrics"
sed -i.bak "s|^PROTO_FILES=\$(find third_party/remoteapis|PROTO_FILES=\$(find $ADD third_party/remoteapis|" \
	scripts/bootstrap/compile.sh
grep -q "cgroups/proto .*third_party" scripts/bootstrap/compile.sh ||
	{ echo "PROTO_FILES の書き換えが当たっていない"; exit 1; }

# com.google.devtools.build.v1 (Build Event Service) の proto も木に無い。
# third_party/google/devtools/build/v1 には BUILD しか置かれておらず、実体は
# googleapis から来る。-Ithird_party/remoteapis/ の下へ置く。
if [ ! -f "$GAPI/devtools/build/v1/build_events.proto" ]; then
	mkdir -p "$GAPI/devtools/build/v1"
	for f in build_events.proto build_status.proto publish_build_event.proto; do
		curl -sfL -o "$GAPI/devtools/build/v1/$f" \
			"$B/devtools/build/v1/$f" || { echo "$f を取れない"; exit 1; }
	done
	# bazel は取り込んだ googleapis に自前の patch を当てている。proto にも
	# 手を入れていて、stream_metadata がそれで足されている。当てないと
	#
	#	BuildEventServiceProtoUtil.java:183: error: cannot find symbol
	#	  method addAllStreamMetadata(ImmutableList<Any>)
	#
	# になる。BUILD.bazel の hunk はこちらの置き方に合わないので、proto の
	# 分だけ取り出して当てる。
	python3 - "$SRC/third_party/googleapis.patch" \
		"$GAPI/devtools/build/v1" <<'GAPATCH'
import re, subprocess, sys, os
patch, dest = sys.argv[1], sys.argv[2]
text = open(patch, encoding="utf-8").read()
# proto を触る diff だけ残す
keep, cur = [], None
for block in re.split(r"(?m)^(?=diff --git )", text):
    if block.startswith("diff --git") and ".proto b/" in block.split("\n")[0]:
        keep.append(block)
if not keep:
    print("  proto を触る hunk が無い")
    sys.exit(0)
sub = "".join(keep)
# a/google/devtools/... を置き場に合わせる
sub = sub.replace("a/google/devtools/build/v1/", "a/").replace(
      "b/google/devtools/build/v1/", "b/")
open("/tmp/gapi.patch", "w", encoding="utf-8").write(sub)
r = subprocess.run(["patch", "-p1", "-s", "-i", "/tmp/gapi.patch"], cwd=dest)
print("  googleapis の patch:", "当てた" if r.returncode == 0 else "当たらなかった")
GAPATCH
	grep -q stream_metadata "$GAPI/devtools/build/v1/publish_build_event.proto" ||
		{ echo "stream_metadata が入らなかった"; exit 1; }
fi

# master の Java の source は無名変数 (Java 22) を使っている箇所がある。
#
#	try (var _ = Profiler.instance().profile(...))
#	_ -> new AtomicInteger(0)
#
#	error: unnamed variables are a preview feature and are disabled by default
#
# JDK 21 で建てるときはここだけが引っ掛かる。ほかは 21 で全部通る。pkgsrc も
# DragonFly の dports も openjdk21 が最新なので、名前を付けて逃げる。
# master は動くので file 名は決め打ちにせず、木を掃いて置き換える。
if [ "$JAVA_VER" -lt 22 ]; then
	echo "=== 無名変数を JDK $JAVA_VER 向けに直す"
	n=0
	for f in $(grep -rlE 'var _ =|_ ->' src/main/java --include='*.java' 2>/dev/null); do
		# 行頭に来る形もあるので、区切りをまとめて見る。
		sed -i.bak -E -e 's/var _ =/var unused_ =/g' \
			      -e 's/(^|[(, \t])_ ->/\1unused_ ->/g' "$f"
		rm -f "$f.bak"
		n=$((n+1))
	done
	echo "  $n file を直した"
	if grep -rqE 'var _ =|(^|[(, \t])_ ->' src/main/java --include='*.java' 2>/dev/null; then
		echo "  まだ残っている:"
		grep -rnE 'var _ =|(^|[(, \t])_ ->' src/main/java --include='*.java' | head -5
	fi
fi

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
