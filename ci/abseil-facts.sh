#!/bin/sh
# abseil の当て物が前提にしている事実を、その platform で実際に確かめる。
# 「BSD だから在るはず」で一覧に足さないための道具。
#
# 出力を head で切らない。長い出力を切ると VM の session ごと落ちることが
# あった (netbsd-vm で二度再現)。

T=${TMPDIR:-/tmp}/absfacts
mkdir -p "$T"
say() { printf '%-34s %s\n' "$1" "$2"; }

echo "===== $(uname -sr) $(uname -m) ====="

# 1. mmap(MAP_ANON) と pthread_getschedparam。ABSL_HAVE_MMAP と
#    ABSL_HAVE_PTHREAD_GETSCHEDPARAM の一覧に足す根拠。
cat > "$T/a.c" <<'C'
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <sys/mman.h>
int main(void) {
	void *p = mmap(0, 4096, PROT_READ|PROT_WRITE, MAP_ANON|MAP_PRIVATE, -1, 0);
	if (p == MAP_FAILED) printf("mmap(MAP_ANON)                     %s\n", strerror(errno));
	else { memset(p, 1, 4096); munmap(p, 4096); printf("mmap(MAP_ANON)                     ok\n"); }
	int policy; struct sched_param sp;
	int r = pthread_getschedparam(pthread_self(), &policy, &sp);
	if (r) printf("pthread_getschedparam              %s\n", strerror(r));
	else printf("pthread_getschedparam              ok (rc=0)\n");
	printf("sizeof(pthread_t) / sizeof(void*)  %zu / %zu\n", sizeof(pthread_t), sizeof(void *));
	return 0;
}
C
if cc -o "$T/a" "$T/a.c" -lpthread 2>"$T/a.err"; then
	"$T/a"
else
	say "1 の compile" "失敗"; cat "$T/a.err"
fi

# 2. pthread_t を pid_t へ cast できるか。abseil の既定の GetTID がこれを
#    やる。DragonFly では pointer なので通らないはず。
cat > "$T/b.c" <<'C'
#include <pthread.h>
#include <sys/types.h>
pid_t f(void) { return (pid_t)pthread_self(); }
C
if cc -c -o "$T/b.o" "$T/b.c" 2>"$T/b.err"; then
	say "(pid_t)pthread_self()" "通る"
else
	say "(pid_t)pthread_self()" "通らない"
fi

# 2b. abseil が実際に書いている形は C++ の static_cast である。C の cast は
#     pointer から整数へも通ってしまうので、C で測ると答えを間違える。
cat > "$T/b2.cc" <<'C'
#include <pthread.h>
#include <sys/types.h>
pid_t f() { return static_cast<pid_t>(pthread_self()); }
C
if c++ -std=gnu++17 -c -o "$T/b2.o" "$T/b2.cc" 2>"$T/b2.err"; then
	say "static_cast<pid_t>(pthread_self())" "通る"
else
	say "static_cast<pid_t>(pthread_self())" "通らない"
fi

# 3. その platform が持つ thread id の取り方。
for fn in pthread_getthreadid_np _lwp_self pthread_threadid_np; do
	cat > "$T/c.c" <<C
#include <pthread.h>
#include <unistd.h>
#ifdef __NetBSD__
#include <lwp.h>
#endif
#if defined(__FreeBSD__) || defined(__DragonFly__)
#include <pthread_np.h>
#endif
int main(void) { (void)$fn; return 0; }
C
	if cc -o "$T/c" "$T/c.c" -lpthread 2>/dev/null; then
		say "$fn" "在る"
	else
		say "$fn" "無い"
	fi
done

# 4. auxv の構造体の名前。vdso_support.cc が別名を要る理由。
for ty in Elf64_Auxinfo Elf64_auxv_t Elf32_Auxinfo Elf32_auxv_t; do
	cat > "$T/d.c" <<C
#include <sys/types.h>
#include <elf.h>
$ty v;
int main(void) { (void)v; return 0; }
C
	if cc -c -o "$T/d.o" "$T/d.c" 2>/dev/null; then
		say "$ty" "在る"
	else
		say "$ty" "無い"
	fi
done

# 5. _XOPEN_SOURCE 500 を定義すると __ISO_C_VISIBLE がどうなるか。
#    time_zone_format.cc を除外する理由。
cat > "$T/e.c" <<'C'
#include <stdio.h>
#include <sys/cdefs.h>
int main(void) {
#ifdef __ISO_C_VISIBLE
	printf("%d\n", __ISO_C_VISIBLE);
#else
	printf("(定義されていない)\n");
#endif
	return 0;
}
C
if cc -o "$T/e" "$T/e.c" 2>/dev/null; then
	say "__ISO_C_VISIBLE 既定" "$("$T/e")"
else
	say "__ISO_C_VISIBLE 既定" "compile 失敗"
fi
if cc -D_XOPEN_SOURCE=500 -o "$T/e2" "$T/e.c" 2>/dev/null; then
	say "同 _XOPEN_SOURCE=500 で" "$("$T/e2")"
else
	say "同 _XOPEN_SOURCE=500 で" "compile 失敗"
fi

# 6. _XOPEN_SOURCE=500 の下で C++ の header が通るか。実際の症状。
cat > "$T/f.cc" <<'C'
#include <cwchar>
#include <cctype>
int main(void) { return 0; }
C
if c++ -std=gnu++17 -o "$T/f" "$T/f.cc" 2>/dev/null; then
	say "c++ <cwchar> <cctype>" "通る"
else
	say "c++ <cwchar> <cctype>" "通らない"
fi
if c++ -std=gnu++17 -D_XOPEN_SOURCE=500 -o "$T/f2" "$T/f.cc" 2>/dev/null; then
	say "同 _XOPEN_SOURCE=500 で" "通る"
else
	say "同 _XOPEN_SOURCE=500 で" "通らない"
fi
