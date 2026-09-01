/* netbsd-ci-images (peer) の測定に使われた C を、そのまま持ち込んだもの。
 * 実機二台では A も B も「connect ok / accept ok / 1 バイト届いた」だった。
 * こちらの vmactions の VM で走らせて、割れているのがコードの差か箱の差かを
 * 切り分ける。中身は変えていない。
 */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int run(const char *tag, int v6listen)
{
	int srv, c, a, off = 0, port;
	struct sockaddr_storage ss;
	socklen_t sl;
	fd_set rf;
	struct timeval tv;
	char b = 'x', got = 0;

	if (v6listen) {
		struct sockaddr_in6 s6;
		srv = socket(AF_INET6, SOCK_STREAM, 0);
		if (setsockopt(srv, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof off) < 0) {
			printf("%s: listener setsockopt: %s\n", tag, strerror(errno));
			close(srv); return 1;
		}
		memset(&s6, 0, sizeof s6);
		s6.sin6_family = AF_INET6; s6.sin6_addr = in6addr_any;
		if (bind(srv, (struct sockaddr *)&s6, sizeof s6) < 0) {
			printf("%s: bind: %s\n", tag, strerror(errno)); close(srv); return 1; }
	} else {
		struct sockaddr_in s4;
		srv = socket(AF_INET, SOCK_STREAM, 0);
		memset(&s4, 0, sizeof s4);
		s4.sin_family = AF_INET; s4.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
		if (bind(srv, (struct sockaddr *)&s4, sizeof s4) < 0) {
			printf("%s: bind: %s\n", tag, strerror(errno)); close(srv); return 1; }
	}
	listen(srv, 1);
	sl = sizeof ss;
	getsockname(srv, (struct sockaddr *)&ss, &sl);
	port = (ss.ss_family == AF_INET6)
	    ? ntohs(((struct sockaddr_in6 *)&ss)->sin6_port)
	    : ntohs(((struct sockaddr_in *)&ss)->sin_port);

	c = socket(AF_INET6, SOCK_STREAM, 0);
	if (setsockopt(c, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof off) < 0)
		printf("%s: client setsockopt: %s\n", tag, strerror(errno));
	{
		struct sockaddr_in6 d;
		memset(&d, 0, sizeof d);
		d.sin6_family = AF_INET6; d.sin6_port = htons(port);
		inet_pton(AF_INET6, "::ffff:127.0.0.1", &d.sin6_addr);
		if (connect(c, (struct sockaddr *)&d, sizeof d) < 0) {
			printf("%s: connect: %s\n", tag, strerror(errno));
			close(c); close(srv); return 1;
		}
	}
	printf("%s: connect ok", tag);
	write(c, &b, 1);
	FD_ZERO(&rf); FD_SET(srv, &rf);
	tv.tv_sec = 3; tv.tv_usec = 0;
	if (select(srv + 1, &rf, NULL, NULL, &tv) <= 0) {
		printf(" / accept: 3 秒待って来ない\n"); close(c); close(srv); return 1;
	}
	sl = sizeof ss;
	a = accept(srv, (struct sockaddr *)&ss, &sl);
	if (a < 0) { printf(" / accept: %s\n", strerror(errno)); close(c); close(srv); return 1; }
	if (read(a, &got, 1) == 1 && got == 'x') printf(" / accept ok / 1 バイト届いた\n");
	else printf(" / accept ok / バイトが来ない\n");
	close(a); close(c); close(srv);
	return 0;
}

int main(void)
{
	run("A (AF_INET listen)   ", 0);
	run("B (AF_INET6 v6only=0)", 1);
	return 0;
}
