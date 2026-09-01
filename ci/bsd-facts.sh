#!/bin/sh
# NetBSD 向けの当て物が前提にしている事実を、四つの BSD で確かめる。
# 「NetBSD には statfs が無い」といった主張を、送る前に測るためのもの。

T=${TMPDIR:-/tmp}/bsdfacts
mkdir -p "$T"
say() { printf '%-32s %s\n' "$1" "$2"; }
try() { # try <名前> <本体>
	printf '#include <sys/types.h>\n#include <sys/param.h>\n%s\n' "$2" > "$T/t.c"
	if cc -c -o "$T/t.o" "$T/t.c" 2>"$T/t.err"; then say "$1" "通る"
	else say "$1" "通らない"; fi
}

echo "===== $(uname -sr) $(uname -m) ====="

try "statfs(2)" '#include <sys/mount.h>
int f(void){ struct statfs s; return statfs("/", &s); }'

try "statvfs の f_fstypename" '#include <sys/statvfs.h>
int f(void){ struct statvfs s; statvfs("/", &s); return s.f_fstypename[0]; }'

try "userland の struct kinfo_proc" '#include <sys/sysctl.h>
struct kinfo_proc k; int f(void){ return sizeof k; }'

try "struct kinfo_proc2" '#include <sys/sysctl.h>
struct kinfo_proc2 k; int f(void){ return sizeof k; }'

try "KERN_PROC2" '#include <sys/sysctl.h>
int f(void){ return KERN_PROC2; }'

for p in /usr/bin/md5 /sbin/md5 /bin/md5 /usr/bin/md5sum; do
	[ -x "$p" ] && say "md5 の在処" "$p"
done
say "command -v md5" "$(command -v md5 2>/dev/null || echo なし)"
