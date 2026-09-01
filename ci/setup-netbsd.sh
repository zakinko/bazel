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

# Setup script for NetBSD.
set -eux

## The openjdk21 package from the pkgsrc binary repository links against the
## X11 shared libraries, and the base install here has no X sets.  Unpacking
## xbase is enough; the whole X distribution is not needed.
SET=$(uname -m)
REL=$(uname -r | cut -d_ -f1)
ftp -o /tmp/xbase.tar.xz \
  "https://cdn.NetBSD.org/pub/NetBSD/NetBSD-${REL}/${SET}/binary/sets/xbase.tar.xz"
tar -C / -xf /tmp/xbase.tar.xz
rm -f /tmp/xbase.tar.xz

## bash and unzip are not in the base system and the bootstrap needs both.
/usr/sbin/pkg_add -U pkgin
pkgin -y install \
  bash \
  curl \
  git \
  gmake \
  openjdk21 \
  python313 \
  unzip \
  zip

## The JDK does not put itself on the path, and the bootstrap reads
## JAVA_HOME rather than searching for one.
cat >> /etc/profile <<'EOF'
JAVA_HOME=/usr/pkg/java/openjdk21
export JAVA_HOME
PATH=$JAVA_HOME/bin:/usr/pkg/bin:$PATH
export PATH
EOF
