/* grpc は setsockopt(IPV6_V6ONLY, 0) が成功すれば dualstack と見なす。
 * その判定が各 BSD で正しいかを見る。
 *
 *   AF_INET connect     対照。これが落ちるなら測定自体が無効
 *   IPV6_V6ONLY=0       判定が見ている戻り値
 *   v4-mapped connect   判定が正しければ ok、誤っていれば失敗
 *
 * connect に使う socket そのものに setsockopt する。別の socket に立てても
 * 既定の v6only は下りないので、通る platform を誤って「壊れている」と読む。
 */
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

int main(void) {
	struct sockaddr_in a;
	socklen_t l = sizeof a;
	int srv, c4, c6, off = 0, port;
	struct sockaddr_in6 b;

	srv = socket(AF_INET, SOCK_STREAM, 0);
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (bind(srv, (struct sockaddr *)&a, sizeof a) < 0) {
		printf("bind: %s\n", strerror(errno));
		return 1;
	}
	getsockname(srv, (struct sockaddr *)&a, &l);
	listen(srv, 5);
	port = ntohs(a.sin_port);
	printf("listening on 127.0.0.1:%d\n", port);

	c4 = socket(AF_INET, SOCK_STREAM, 0);
	printf("AF_INET connect:    %s\n",
	    connect(c4, (struct sockaddr *)&a, sizeof a) < 0
	    ? strerror(errno) : "ok");
	close(c4);

	c6 = socket(AF_INET6, SOCK_STREAM, 0);
	if (c6 < 0) {
		printf("AF_INET6 socket:    %s\n", strerror(errno));
		return 0;
	}
	printf("IPV6_V6ONLY=0:      %s\n",
	    setsockopt(c6, IPPROTO_IPV6, IPV6_V6ONLY, &off, sizeof off) < 0
	    ? strerror(errno) : "ok");

	memset(&b, 0, sizeof b);
	b.sin6_family = AF_INET6;
	b.sin6_port = htons(port);
	inet_pton(AF_INET6, "::ffff:127.0.0.1", &b.sin6_addr);
	printf("v4-mapped connect:  %s\n",
	    connect(c6, (struct sockaddr *)&b, sizeof b) < 0
	    ? strerror(errno) : "ok");
	close(c6);
	return 0;
}
