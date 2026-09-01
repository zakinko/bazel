#!/bin/sh
#
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

# Setup script for DragonFly BSD.
set -eux

## The base compiler is gcc 8, whose libstdc++ does not carry enough of C++17
## for Bazel: <cwchar> does not declare std::vswscanf and <cctype> does not
## declare ::isblank.  clang from dports does.
pkg install -y \
  bash \
  curl \
  git \
  gmake \
  llvm \
  openjdk21 \
  python3 \
  unzip \
  zip

## The JDK's package message asks for this, and the JVM can abort partway
## through startup without it.
mount -t procfs proc /proc || true
cat >> /etc/fstab <<'EOF'
proc	/proc	procfs	rw	0	0
EOF

## The JDK does not put itself on the path, and the bootstrap reads
## JAVA_HOME rather than searching for one.  CC and CXX point at clang for
## the reason above.
cat >> /etc/profile <<'EOF'
JAVA_HOME=/usr/local/openjdk21
export JAVA_HOME
PATH=$JAVA_HOME/bin:$PATH
export PATH
CC=$(ls /usr/local/bin/clang[0-9]* /usr/local/bin/clang 2>/dev/null | head -1)
CXX=$(ls /usr/local/bin/clang++[0-9]* /usr/local/bin/clang++ 2>/dev/null | head -1)
export CC CXX
EOF
