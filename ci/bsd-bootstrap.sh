#!/bin/sh
# 各 BSD の VM の中で走る。dist archive にこの枝の変更を被せて bootstrap する。
#
# git のチェックアウトからは compile.sh が動かない (bazel が dist archive を
# 落とせと言って止まる) ので、公式の dist を落として上書きする形にしている。
set -e

: "${SRCDIR:?SRCDIR is not set}"
: "${JAVA_HOME:?JAVA_HOME is not set}"
DIST_URL=https://github.com/bazelbuild/bazel/releases/download/9.2.0/bazel-9.2.0-dist.zip
WORK=${WORK:-/tmp/bazel-dist}

export JAVA_HOME
export JAVA_VERSION=21
export EMBED_LABEL=9.2.0
export BAZEL_DEV_VERSION_OVERRIDE=9.2.0
export SOURCE_DATE_EPOCH=1784438615
export BAZEL_JAVAC_OPTS="-J-Xmx2g -J-Xms256m"

# どの BSD でも libm は別ライブラリなので明示的に繋ぐ。FreeBSD の
# devel/bazel9 も同じことをしている。
EXTRA_BAZEL_ARGS="${EXTRA_BAZEL_ARGS:-} --host_linkopt=-lm --linkopt=-lm"

# OpenBSD は C++ のオブジェクトを C のドライバでリンクするので、C++ の
# ランタイムを明示的に繋ぐ必要がある (undefined symbol: operator new)。
if [ "$(uname -s)" = OpenBSD ]; then
	for l in -lc++ -lc++abi -lpthread; do
		EXTRA_BAZEL_ARGS="$EXTRA_BAZEL_ARGS --host_linkopt=$l --linkopt=$l"
	done
fi

# DragonFly の gcc14 は libstdc++ を使う。cc_configure は BAZEL_CXXOPTS が
# 無ければ -std=c++17 を既定にするが、それだと __STRICT_ANSI__ が立ち、
# DragonFly の header が C99 と POSIX の名前を隠す。libstdc++ はそれを
# using で引き上げるので、cwchar と cctype がそのまま落ちる。
#
#	cwchar:286: error: 'vfwscanf' has not been declared
#	cctype:87:  error: 'isblank' has not been declared
#	basic_string.h:4459: error: 'wcstof' was not declared
#
# gnu++17 なら __STRICT_ANSI__ が立たないので header がそれらを出す。
# 他の BSD は clang と libc++ で、既定のまま通っているので触らない。
if [ "$(uname -s)" = DragonFly ]; then
	BAZEL_CXXOPTS="-std=gnu++17"
	export BAZEL_CXXOPTS
	# cc_configure は repository rule なので、action の env ではなく
	# repo の env を見る。両方に渡さないと host 側の toolchain に効かない。
	EXTRA_BAZEL_ARGS="$EXTRA_BAZEL_ARGS --repo_env=BAZEL_CXXOPTS=$BAZEL_CXXOPTS"
	EXTRA_BAZEL_ARGS="$EXTRA_BAZEL_ARGS --host_action_env=BAZEL_CXXOPTS=$BAZEL_CXXOPTS"
	EXTRA_BAZEL_ARGS="$EXTRA_BAZEL_ARGS --cxxopt=$BAZEL_CXXOPTS --host_cxxopt=$BAZEL_CXXOPTS"

	# 落ちていたのは方言ではなく C++ modules だった。bazel は layering_check の
	# ために module map を渡すが、DragonFly の base gcc 8.3 の libstdc++ を
	# module 経由で読むと <cwchar> が壊れる。
	#
	#   /usr/include/c++/8.0/cwchar:164: error: no member named 'vfwscanf'
	#   in the global namespace
	#
	# 同じ command から -fmodule-map-file と -fmodules-strict-decluse を
	# 落とすと通る (rc=0)。-std=gnu++17 は最初から効いていて、log が flag を
	# 引用符付きで出すのを読み違えていただけだった。
	EXTRA_BAZEL_ARGS="$EXTRA_BAZEL_ARGS --features=-layering_check --host_features=-layering_check"
	EXTRA_BAZEL_ARGS="$EXTRA_BAZEL_ARGS --features=-module_maps --host_features=-module_maps"

	# base の cc は gcc 8.3 なので clang を使う。包みは要らない。
	CC=$(ls /usr/local/bin/clang[0-9]* /usr/local/bin/clang 2>/dev/null | head -1)
	CXX=$(ls /usr/local/bin/clang++[0-9]* /usr/local/bin/clang++ 2>/dev/null | head -1)
	[ -n "$CC" ] && export CC CXX && echo "DragonFly: CC=$CC CXX=$CXX"
fi

# rules_go は go.mod に合わせて Go SDK を落としに行くが、NetBSD 向けの Go は
# 配布されていない。//toolchain_local の当て物で host の Go を使わせているので、
# その在処を渡す。
# pkgsrc は go を PATH に置かず /usr/pkg/go1NN/bin に入れる。DragonFly も
# /usr/local/go1NN の形になることがある。見つけて PATH に足す。
#
# 版の大きい方から見る。DragonFly の pkg は go120 から go124 までを別々の
# package として置いていて、複数が同時に入っていることがある。glob は昇順に
# 展開するので、素直に先頭を採ると一番古いものを掴む。
if ! command -v go >/dev/null 2>&1; then
	for d in $(ls -d /usr/pkg/go1* /usr/local/go1* /usr/local/go 2>/dev/null | sort -r); do
		if [ -x "$d/bin/go" ]; then
			PATH="$d/bin:$PATH"
			export PATH
			break
		fi
	done
fi

# OpenBSD の既定の記述子上限 (staff クラスで 512) では bazel が
# Too many open files で落ちる。上げられるだけ上げる。
ulimit -n unlimited 2>/dev/null || ulimit -n 4096 2>/dev/null || true

# データ領域の上限も上げる。DragonFly では 8GB の箱で JVM が
#
#	Native memory allocation (mmap) failed to map 65536 bytes.
#	Error detail: Failed to commit metaspace.
#
# と言って 4 秒で死ぬ。物理も swap も余っていて、効いているのは ulimit の方
# である。
ulimit -d unlimited 2>/dev/null || true
ulimit -m unlimited 2>/dev/null || true

echo "=== ulimit"
printf '  記述子 %s / データ %s / メモリ %s / stack %s\n' \
	"$(ulimit -n)" "$(ulimit -d)" "$(ulimit -m 2>/dev/null || echo -)" "$(ulimit -s)"
echo "=== 物理メモリ"
sysctl hw.physmem hw.usermem 2>/dev/null | sed 's/^/  /' || true

echo "=== 容量"
df -h 2>/dev/null | head -6

# bazel の bootstrap は数 GB 使う。一番空いている場所を選ぶ。
if [ -z "${WORK_FORCED:-}" ]; then
	best=""
	bestfree=0
	for d in /tmp /var/tmp "$HOME" /usr/obj; do
		[ -d "$d" ] || continue
		free=$(df -k "$d" 2>/dev/null | awk 'NR==2 {print $4}')
		case "$free" in ''|*[!0-9]*) continue ;; esac
		if [ "$free" -gt "$bestfree" ]; then
			bestfree=$free
			best=$d
		fi
	done
	if [ -n "$best" ]; then
		WORK="$best/bazel-dist"
		echo "作業場: $WORK ($((bestfree / 1024)) MB 空き)"
	fi
fi

# compile.sh の run() は既定で各段の出力を一時ファイルに溜め、失敗したときに
# だけ吐く。その一時ファイルは atexit で消えるので、段の途中で SIGABRT を
# 食らうと何が落ちたのか一行も残らない。VM の中は覗けないので、常に流す。
export VERBOSE=yes

echo "=== 道具の在処"
uname -a
for t in bash unzip zip curl python3 go; do
	printf "%-8s %s\n" "$t" "$(command -v $t 2>/dev/null || echo '(無い)')"
done
command -v go >/dev/null 2>&1 && go version && go env GOROOT
"$JAVA_HOME/bin/java" -version 2>&1 || echo "(java が動かない)"

if command -v go >/dev/null 2>&1; then
	GOROOT_PATH=$(go env GOROOT 2>/dev/null || true)
	if [ -n "$GOROOT_PATH" ]; then
		EXTRA_BAZEL_ARGS="$EXTRA_BAZEL_ARGS --repo_env=GOROOT=$GOROOT_PATH"
	fi
fi
# action は env - で起動されるので、PATH を明示的に渡さないと pkgsrc や
# ports が入れた zip/unzip が見つからない。exec 側 (genrule の [for tool])
# には --host_action_env でないと届かない。
EXTRA_BAZEL_ARGS="$EXTRA_BAZEL_ARGS --action_env=PATH=$PATH --host_action_env=PATH=$PATH"

export EXTRA_BAZEL_ARGS
echo "EXTRA_BAZEL_ARGS=$EXTRA_BAZEL_ARGS"

# LD_LIBRARY_PATH は立てない。立てると OpenJDK のランチャが自分を再 exec
# しようとして、NetBSD では自分の path を引けずに死ぬ。
unset LD_LIBRARY_PATH

# NetBSD の /tmp は 2GB の tmpfs で、そこに置くと二つ困る。bazel の
# output base と package-bazel.sh の mktemp が両方 ${TMPDIR:-/tmp} に落ちて
# 容量が尽きる (zip が ZE_DISK=50 で返る) し、tmpfs は VM のメモリを食う。
# 選んだ場所を TMPDIR にもする。
TMPDIR="$WORK/tmp"
export TMPDIR

echo "=== dist を取る"
# 前回の残骸があると unzip が上書き確認を出し、CI では stdin が無いので
# "[N]one" と解釈されて何も展開されない。作業場は毎回作り直す。
# TMPDIR はこの下なので、消してから作る。
rm -rf "$WORK"
mkdir -p "$WORK" "$TMPDIR" && cd "$WORK"
curl -sL -o dist.zip "$DIST_URL"
unzip -q -o dist.zip
rm -f dist.zip

echo "=== この枝の変更を被せる"
# PLAIN=1 のときは被せない。素の upstream がその BSD で建つかを測るため。
if [ -n "$PLAIN" ]; then
	echo "PLAIN=1 なので被せない。素の $DIST_URL を建てる"
	cd "$WORK"
	# rules_cc の当て物だけを当てる。PR 859 の形をそのまま使う。
	if [ -n "$PATCH859" ]; then
		mkdir -p toolchain_local
		cp "$PATCH859" toolchain_local/rules_cc_859.patch
		: > toolchain_local/BUILD
		cat >> MODULE.bazel <<'PATCHEOF'

single_version_override(
    module_name = "rules_cc",
    patch_strip = 1,
    patches = ["//toolchain_local:rules_cc_859.patch"],
)
PATCHEOF
		echo "859 の当て物を入れた"
	fi
	"${BAZEL_SH:-bash}" ./compile.sh
	./output/bazel --version
	exit $?
fi
cd "$SRCDIR"
# ファイル単位の cp だと VM の中で十数分かかる。tar で流し込む。
for d in src scripts tools third_party toolchain_local; do
	[ -d "$d" ] || continue
	tar cf - "$d" | (cd "$WORK" && tar xf -)
done
cp MODULE.bazel "$WORK/MODULE.bazel"

echo "=== 建てる"
cd "$WORK"
"${BAZEL_SH:-bash}" ./compile.sh
./output/bazel --version

# --version は client だけで答えられるので、建ったこと以上を意味しない。
# DragonFly はここまで通ったうえで server に繋げず、どの build も 120 秒で
# 諦めていた (grpc が IPv4-mapped アドレスを使うため)。server が上がって
# action が一つ走るところまで見る。
echo "=== 動かす"
smoke="$WORK/smoke"
rm -rf "$smoke"
mkdir -p "$smoke"
cd "$smoke"
: > MODULE.bazel
cat > BUILD <<'SMOKE'
genrule(
    name = "hi",
    outs = ["hi.txt"],
    cmd = "uname -sr > $@",
)
SMOKE
"$WORK/output/bazel" build //:hi
cat bazel-bin/hi.txt
