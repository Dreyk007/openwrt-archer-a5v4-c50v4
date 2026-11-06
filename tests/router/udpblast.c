/* UDP load for Wi-Fi tests on the router: datagrams of one size to ip:port for a given time, as
 * fast as the stack takes them or at a rate. An unconnected socket, so that the ICMP port
 * unreachable answers of the client do not fail the sends. What reaches the air is in the
 * counters of the interface and the station, not in this program's output. */
#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

int main(int argc, char **argv)
{
	static char buf[65507];
	struct sockaddr_in a = { .sin_family = AF_INET };
	unsigned long sent = 0, err = 0;
	double t0, t, dur, rate, gap, next;
	int s, size, sndbuf = 1 << 20;

	if (argc < 5) {
		fprintf(stderr, "usage: %s ip port size seconds [Mbit/s, 0 or none: as fast as possible]\n", argv[0]);
		return 1;
	}
	a.sin_port = htons(atoi(argv[2]));
	if (inet_pton(AF_INET, argv[1], &a.sin_addr) != 1) {
		fprintf(stderr, "bad address %s\n", argv[1]);
		return 1;
	}
	size = atoi(argv[3]);
	dur = atof(argv[4]);
	rate = argc > 5 ? atof(argv[5]) : 0;
	if (size < 1 || size > (int)sizeof(buf) || dur <= 0) {
		fprintf(stderr, "bad size or time\n");
		return 1;
	}
	s = socket(AF_INET, SOCK_DGRAM, 0);
	if (s < 0) {
		perror("socket");
		return 1;
	}
	setsockopt(s, SOL_SOCKET, SO_SNDBUF, &sndbuf, sizeof(sndbuf));

	gap = rate > 0 ? size * 8 / (rate * 1e6) : 0;
	t0 = next = now();
	while ((t = now()) - t0 < dur) {
		if (gap > 0) {
			if (t < next) {
				usleep((next - t) * 1e6 + 1);
				continue;
			}
			next += gap;
		}
		if (sendto(s, buf, size, 0, (struct sockaddr *)&a, sizeof(a)) == size) {
			sent++;
		} else {
			err++;
			if (errno == ENOBUFS || errno == EAGAIN)
				usleep(200);
		}
	}
	t = now() - t0;
	printf("sent %lu datagrams of %d bytes in %.2f s: %.1f Mbit/s, %.0f per s, %lu errors\n",
	       sent, size, t, sent * size * 8 / t / 1e6, sent / t, err);
	return 0;
}
