#!/bin/sh

# Copyright 2026 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eu

JAVA_HOME="$1"
PLATFORM="$2"
OUT="$3"

RUST_TMPDIR="$(mktemp -d)"
trap 'rm -rf "${RUST_TMPDIR}"' EXIT
RUST_LIB="${RUST_TMPDIR}/librust_ffi.a"
RUST_LINK_FLAGS="${RUST_TMPDIR}/rust_link_flags.txt"

scripts/bootstrap/build_rust_ffi.sh "${PLATFORM}" "${RUST_LIB}" "${RUST_LINK_FLAGS}"

# POSIX sh has no arrays.  The compiler flags go into the positional
# parameters, and the sources into a string that is split on purpose at the
# end, which is also where the darwin glob expands.

# Source files common to all platforms.
# Omit blake3, which would require an external dependency.
SOURCES="src/main/native/latin1_jni_path.cc \
  src/main/native/unix_jni.cc \
  src/main/cpp/util/logging.cc"

# Compiler flags common to all platforms.
set -- "-std=c++17" "-I." "-I${JAVA_HOME}/include" "-fPIC" "-shared"

# Platform-specific source files and compiler flags.
case "$PLATFORM" in
linux)
  SOURCES="$SOURCES src/main/native/unix_jni_linux.cc"
  set -- "$@" "-I${JAVA_HOME}/include/linux"
  ;;
darwin)
  SOURCES="$SOURCES src/main/native/darwin/*.cc"
  set -- "$@" \
    "-I${JAVA_HOME}/include/darwin" \
    "-Wl,-framework,CoreServices" \
    "-Wl,-framework,IOKit"
  ;;
openbsd)
  SOURCES="$SOURCES src/main/native/unix_jni_bsd.cc"
  set -- "$@" "-I${JAVA_HOME}/include/openbsd"
  ;;
freebsd)
  SOURCES="$SOURCES src/main/native/unix_jni_bsd.cc"
  set -- "$@" "-I${JAVA_HOME}/include/freebsd"
  ;;
esac

RUST_LIBS=""
if [ -f "${RUST_LIB}" ]; then
  while IFS= read -r flag || [ -n "${flag}" ]; do
    if [ -n "${flag}" ]; then
      set -- "$@" "${flag}"
    fi
  done < "${RUST_LINK_FLAGS}"
  case "$PLATFORM" in
    linux) RUST_LIBS="-ldl -lpthread" ;;
    freebsd|openbsd) RUST_LIBS="-lpthread" ;;
  esac
  # shellcheck disable=SC2086  # $SOURCES and $RUST_LIBS are lists
  c++ "$@" $SOURCES "${RUST_LIB}" $RUST_LIBS -o "$OUT"
else
  # shellcheck disable=SC2086  # $SOURCES is a list
  c++ "$@" $SOURCES -o "$OUT"
fi
