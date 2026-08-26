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

# LD_LIBRARY_PATH は立てない。立てると OpenJDK のランチャが自分を再 exec
# しようとして、NetBSD では自分の path を引けずに死ぬ。
unset LD_LIBRARY_PATH

echo "=== dist を取る"
mkdir -p "$WORK" && cd "$WORK"
curl -sL -o dist.zip "$DIST_URL"
tar xf dist.zip

echo "=== この枝の変更を被せる"
cd "$SRCDIR"
for d in src scripts tools third_party toolchain_local; do
	[ -d "$d" ] || continue
	find "$d" -type f | while read -r f; do
		mkdir -p "$WORK/$(dirname "$f")"
		cp "$f" "$WORK/$f"
	done
done
cp MODULE.bazel "$WORK/MODULE.bazel"

echo "=== 建てる"
cd "$WORK"
"${BAZEL_SH:-bash}" ./compile.sh
./output/bazel --version
