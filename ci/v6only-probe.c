/* grpc は setsockopt(IPV6_V6ONLY, 0) が成功すれば dualstack と見なし、
 * IPv4 の相手のアドレスを ::ffff: の形へ変換して繋ぎにいく。その判定が
 * 各 BSD で正しいかを見る。
 *
 * listen 側の family を二通り試す。二つは別の問いで、答えが割れる。
 *
 *   A  AF_INET で listen           bazel の server が実際に取る形
 *   B  AF_INET6 v6only=0 で listen  mapped を受ける側も dualstack の形
 *
 * connect に使う socket そのものに setsockopt する。別の socket に立てても
 * 既定の v6only は下りないので、通る platform を誤って「壊れている」と読む。
 *
 * connect は非閉塞にして 3 秒で切る。時間切れと即座の失敗を区別するため。
 */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

static const char *try_connect(int fd, const struct sockaddr *sa, socklen_t sl)
{
	static char buf[128];
	struct pollfd p;
	int err = 0;
	socklen_t el = sizeof err;

	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
	if (connect(fd, sa, sl) == 0)
		return "ok";
	if (errno != EINPROGRESS) {
		snprintf(buf, sizeof buf, "%s", strerror(errno));
		return buf;
	}
	p.fd = fd;
	p.events = POLLOUT;
	if (poll(&p, 1, 3000) == 0)
		return "no answer in 3s";
	getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
	if (err == 0)
		return "ok";
	snprintf(buf, sizeof buf, "%s", strerror(err));
	return buf;
}

static int listen4(int *port)
{
	struct sockaddr_in a;
	socklen_t l = sizeof a;
	int s = socket(AF_INET, SOCK_STREAM, 0);

	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (bind(s, (struct sockaddr *)&a, sizeof a) < 0)
		return -1;
	getsockname(s, (struct sockaddr *)&a, &l);
	listen(s, 16);
	*port = ntohs(a.sin_port);
	return s;
}

static int listen6(int *port)
{
	struct sockaddr_in6 a;
	socklen_t l = sizeof a;
	int off = 0, s = socket(AF_INET6, SOCK_STREAM, 0);

	if (s < 0)
		return -1;
	if (setsockopt(s, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof off) < 0)
		return -2;
	memset(&a, 0, sizeof a);
	a.sin6_family = AF_INET6;
	a.sin6_addr = in6addr_any;
	if (bind(s, (struct sockaddr *)&a, sizeof a) < 0)
		return -1;
	getsockname(s, (struct sockaddr *)&a, &l);
	listen(s, 16);
	*port = ntohs(a.sin6_port);
	return s;
}

static void mapped_to(int port, const char *label)
{
	struct sockaddr_in6 b;
	int off = 0, c = socket(AF_INET6, SOCK_STREAM, 0);

	if (c < 0) {
		printf("  %-28s AF_INET6 socket: %s\n", label, strerror(errno));
		return;
	}
	printf("  %-28s IPV6_V6ONLY=0: %s\n", label,
	    setsockopt(c, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof off) < 0
	    ? strerror(errno) : "ok");
	memset(&b, 0, sizeof b);
	b.sin6_family = AF_INET6;
	b.sin6_port = htons(port);
	inet_pton(AF_INET6, "::ffff:127.0.0.1", &b.sin6_addr);
	printf("  %-28s v4-mapped connect: %s\n", label,
	    try_connect(c, (struct sockaddr *)&b, sizeof b));
	close(c);
}

int main(void)
{
	struct sockaddr_in a;
	int p4 = 0, p6 = 0, s4, s6, c;

	s4 = listen4(&p4);
	if (s4 < 0) {
		printf("listen4: %s\n", strerror(errno));
		return 1;
	}
	printf("A: AF_INET listener on 127.0.0.1:%d\n", p4);

	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	a.sin_port = htons(p4);
	c = socket(AF_INET, SOCK_STREAM, 0);
	printf("  %-28s AF_INET connect: %s\n", "A (control)",
	    try_connect(c, (struct sockaddr *)&a, sizeof a));
	close(c);
	mapped_to(p4, "A (AF_INET listener)");

	s6 = listen6(&p6);
	if (s6 == -2) {
		printf("B: IPV6_V6ONLY=0 on the listener: %s\n", strerror(errno));
		return 0;
	}
	if (s6 < 0) {
		printf("B: listen6: %s\n", strerror(errno));
		return 0;
	}
	printf("B: AF_INET6 v6only=0 listener on [::]:%d\n", p6);
	mapped_to(p6, "B (AF_INET6 listener)");
	return 0;
}
