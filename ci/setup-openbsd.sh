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

# Setup script for OpenBSD.
set -eux

## bash and unzip are not in the base system and the bootstrap needs both;
## the JDK is needed to build Bazel at all, and python3 by several of the
## tools it builds.  The package names carry the flavour markers OpenBSD
## uses: unzip-- is the plain one, python%3 and jdk%21 pick a version.
pkg_add -I \
  bash \
  curl \
  git \
  gmake \
  jdk%21 \
  python%3 \
  unzip-- \
  zip

## The default openfiles limit for the daemon class is 128.  Bazel's workers
## run out well before the build finishes; the Java compile stops with
## "Too many open files" a few hundred actions from the end.
cat >> /etc/login.conf <<'EOF'

bazel:\
	:openfiles-cur=4096:\
	:openfiles-max=8192:\
	:tc=daemon:
EOF

## The JDK does not put itself on the path, and the bootstrap reads
## JAVA_HOME rather than searching for one.
cat >> /etc/profile <<'EOF'
JAVA_HOME=/usr/local/jdk-21
export JAVA_HOME
PATH=$JAVA_HOME/bin:$PATH
export PATH
EOF
