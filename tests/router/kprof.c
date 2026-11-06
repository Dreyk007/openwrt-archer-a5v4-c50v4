/* Small system-wide profiler for the router: perf (6 MB) does not fit in its RAM next to a test.
 * Samples the CPU through perf_event_open (CPU cycles, so idle time takes no samples; cpu-clock if
 * the counter is missing) for a given time and prints the share of each kernel function, with the
 * kernel callers of the top ones, and of each user-space process. Over the same window it reports
 * the CPU time by kind, the traffic of every interface, and the longest gap between the wakeups of
 * its own 100 ms timer, which shows how long a process at normal priority had to wait for the CPU.
 *
 * The sampling starts at once and the names are looked up afterwards, so that a busy CPU delays
 * nothing but the report. Kernel names come from /proc/kallsyms. OpenWrt strips the static
 * functions of modules, so the samples of a module can also be written as module+offset of its
 * text, to be named with the unstripped .ko of the build tree.
 *
 * Usage: kprof <seconds> [samples per second, default 1000] [top, default 40] [file for all module
 *        samples, one "module offset count" per line] */
#include <linux/perf_event.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <time.h>
#include <unistd.h>

#define RING_PAGES 256
#define CHAIN 4
#define MAX_IFACES 32

struct sym { uint32_t addr; char *name; };
struct hit { uint64_t key; unsigned long n; };	/* key: function, function<<32 | caller, pid or ip */
struct sample { uint32_t ip, pid, chain[CHAIN]; };
struct mod { char name[64]; uint32_t base, size; };
struct iface { char name[32]; unsigned long long rx, tx; };

static struct sym *syms;
static size_t nsyms;
static struct hit *leaf, *pair, *proc, *modip;
static size_t nleaf, npair, nproc, nmodip, cap_leaf, cap_pair, cap_proc, cap_modip;
static struct sample *samples;
static size_t nsamples, cap_samples;
static struct mod mods[128];
static int nmods;

static void add(struct hit **t, size_t *n, size_t *cap, uint64_t key)
{
	size_t i;

	for (i = 0; i < *n; i++)
		if ((*t)[i].key == key) {
			(*t)[i].n++;
			return;
		}
	if (*n == *cap) {
		*cap = *cap ? *cap * 2 : 1024;
		*t = realloc(*t, *cap * sizeof(**t));
		if (!*t)
			exit(1);
	}
	(*t)[*n].key = key;
	(*t)[(*n)++].n = 1;
}

static int by_addr(const void *a, const void *b)
{
	const struct sym *x = a, *y = b;

	return x->addr < y->addr ? -1 : x->addr > y->addr;
}

static int by_count(const void *a, const void *b)
{
	const struct hit *x = a, *y = b;

	return x->n < y->n ? 1 : x->n > y->n ? -1 : 0;
}

static void load_kallsyms(void)
{
	FILE *f = fopen("/proc/kallsyms", "r");
	char line[256], type, name[200];
	unsigned long addr;
	size_t cap = 0;

	if (!f)
		return;
	while (fgets(line, sizeof(line), f)) {
		if (sscanf(line, "%lx %c %199s", &addr, &type, name) != 3)
			continue;
		if (type != 't' && type != 'T')
			continue;
		if (nsyms == cap) {
			cap = cap ? cap * 2 : 16384;
			syms = realloc(syms, cap * sizeof(*syms));
			if (!syms)
				exit(1);
		}
		syms[nsyms].addr = addr;
		syms[nsyms++].name = strdup(name);
	}
	fclose(f);
	qsort(syms, nsyms, sizeof(*syms), by_addr);
}

/* The index of the symbol an address belongs to, or nsyms */
static size_t sym_of(uint32_t ip)
{
	size_t lo = 0, hi = nsyms;

	while (lo < hi) {
		size_t mid = (lo + hi) / 2;

		if (syms[mid].addr <= ip)
			lo = mid + 1;
		else
			hi = mid;
	}
	return lo ? lo - 1 : nsyms;
}

static uint32_t func_of(uint32_t ip)
{
	size_t i = sym_of(ip);

	return i < nsyms ? syms[i].addr : ip;
}

static const char *ksym(uint32_t ip)
{
	size_t i = sym_of(ip);

	return i < nsyms ? syms[i].name : "?";
}

/* The text of each module: /proc/modules gives its size and the address of its text */
static void load_modules(void)
{
	FILE *f = fopen("/proc/modules", "r");
	char line[512];

	if (!f)
		return;
	while (nmods < 128 && fgets(line, sizeof(line), f)) {
		struct mod *m = &mods[nmods];
		char *base = strstr(line, " 0x");
		unsigned long size;

		if (!base || sscanf(line, "%63s %lu", m->name, &size) != 2)
			continue;
		m->size = size;
		m->base = strtoul(base + 1, NULL, 16);
		nmods++;
	}
	fclose(f);
}

static int mod_of(uint32_t ip)
{
	int k;

	for (k = 0; k < nmods; k++)
		if (ip >= mods[k].base && ip < mods[k].base + mods[k].size)
			return k;
	return -1;
}

/* user, nice, system, idle, iowait, irq, softirq of /proc/stat */
static void read_cpu(unsigned long long *v)
{
	FILE *f = fopen("/proc/stat", "r");

	memset(v, 0, 7 * sizeof(*v));
	if (!f)
		return;
	if (fscanf(f, "cpu %llu %llu %llu %llu %llu %llu %llu", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5],
		   &v[6]) != 7)
		memset(v, 0, 7 * sizeof(*v));
	fclose(f);
}

static int read_ifaces(struct iface *t)
{
	FILE *f = fopen("/proc/net/dev", "r");
	char line[512];
	int n = 0;

	if (!f)
		return 0;
	while (n < MAX_IFACES && fgets(line, sizeof(line), f)) {
		char *colon = strchr(line, ':'), *name = line;
		unsigned long long v[9];

		if (!colon)
			continue;
		*colon = 0;
		while (*name == ' ')
			name++;
		if (sscanf(colon + 1, "%llu %llu %llu %llu %llu %llu %llu %llu %llu", &v[0], &v[1], &v[2], &v[3],
			   &v[4], &v[5], &v[6], &v[7], &v[8]) != 9)
			continue;
		snprintf(t[n].name, sizeof(t[n].name), "%.31s", name);
		t[n].rx = v[0];
		t[n++].tx = v[8];
	}
	fclose(f);
	return n;
}

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

static int open_event(int type, int config, int freq)
{
	struct perf_event_attr a;

	memset(&a, 0, sizeof(a));
	a.size = sizeof(a);
	a.type = type;
	a.config = config;
	a.freq = 1;
	a.sample_freq = freq;
	a.sample_type = PERF_SAMPLE_IP | PERF_SAMPLE_TID | PERF_SAMPLE_CALLCHAIN;
	a.exclude_callchain_user = 1;
	a.wakeup_events = 64;
	return syscall(__NR_perf_event_open, &a, -1, 0, -1, 0);
}

static void keep(uint64_t *v)
{
	struct sample *s;
	uint64_t nr = v[2], j;
	int k = 0;

	if (nsamples == cap_samples) {
		cap_samples = cap_samples ? cap_samples * 2 : 16384;
		samples = realloc(samples, cap_samples * sizeof(*samples));
		if (!samples)
			exit(1);
	}
	s = &samples[nsamples++];
	/* A 32-bit kernel: user space below 0x80000000, the kernel and its modules above */
	s->ip = (uint32_t)v[0];
	s->pid = (uint32_t)v[1];
	memset(s->chain, 0, sizeof(s->chain));
	/* The callchain starts with a context marker and the sampled IP; markers are the top
	 * 4095 values */
	for (j = 0; j < nr && k < CHAIN; j++) {
		uint64_t c = v[3 + j];

		if (c >= (uint64_t)-4095 || (uint32_t)c < 0x80000000U || (uint32_t)c == s->ip)
			continue;
		s->chain[k++] = (uint32_t)c;
	}
}

int main(int argc, char **argv)
{
	double secs = argc > 1 ? atof(argv[1]) : 10;
	int freq = argc > 2 ? atoi(argv[2]) : 1000, top = argc > 3 ? atoi(argv[3]) : 40;
	long page = sysconf(_SC_PAGESIZE);
	unsigned long kernel = 0, lost = 0;
	unsigned long long c0[7], c1[7], tot = 0;
	struct iface i0[MAX_IFACES], i1[MAX_IFACES];
	int n0, n1, k;
	const char *event = "cycles";
	struct perf_event_mmap_page *meta;
	double t0, last, gap = 0, t;
	uint64_t tail = 0;
	char *data;
	size_t i, j;
	int fd;

	load_modules();
	fd = open_event(PERF_TYPE_HARDWARE, PERF_COUNT_HW_CPU_CYCLES, freq);
	if (fd < 0) {
		event = "cpu-clock";
		fd = open_event(PERF_TYPE_SOFTWARE, PERF_COUNT_SW_CPU_CLOCK, freq);
	}
	if (fd < 0) {
		perror("perf_event_open");
		return 1;
	}
	meta = mmap(NULL, (RING_PAGES + 1) * page, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (meta == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	data = (char *)meta + page;
	read_cpu(c0);
	n0 = read_ifaces(i0);

	t0 = last = now();
	for (;;) {
		struct pollfd p = { .fd = fd, .events = POLLIN };
		uint64_t head;

		poll(&p, 1, 100);
		t = now();
		if (t - last > gap)
			gap = t - last;
		last = t;
		head = meta->data_head;
		__sync_synchronize();
		while (tail < head) {
			char rec[4096];
			struct perf_event_header *h;
			size_t off = tail % (RING_PAGES * page), len, first;

			h = (void *)(data + off);
			len = h->size;
			first = RING_PAGES * page - off;
			if (len > sizeof(rec))
				len = sizeof(rec);
			if (first >= len) {
				memcpy(rec, data + off, len);
			} else {
				memcpy(rec, data + off, first);
				memcpy(rec + first, data, len - first);
			}
			h = (void *)rec;
			if (h->type == PERF_RECORD_SAMPLE)
				keep((uint64_t *)(h + 1));
			else if (h->type == PERF_RECORD_LOST)
				lost += ((uint64_t *)(h + 1))[1];
			tail += h->size;
		}
		meta->data_tail = tail;
		if (t - t0 >= secs)
			break;
	}
	read_cpu(c1);
	n1 = read_ifaces(i1);
	t = now() - t0;
	close(fd);

	for (k = 0; k < 7; k++)
		tot += c1[k] - c0[k];
	if (!tot)
		tot = 1;
	printf("CPU over %.1f s: idle %llu%%, system %llu%%, softirq %llu%%, user %llu%%, irq %llu%%; a 100 ms timer late by up to %.0f ms\n",
	       t, 100 * (c1[3] - c0[3]) / tot, 100 * (c1[2] - c0[2]) / tot, 100 * (c1[6] - c0[6]) / tot,
	       100 * (c1[0] - c0[0] + c1[1] - c0[1]) / tot, 100 * (c1[5] - c0[5]) / tot,
	       gap > 0.1 ? (gap - 0.1) * 1000 : 0);
	printf("traffic (Mbit/s):");
	for (k = 0; k < n1; k++) {
		int m;

		for (m = 0; m < n0; m++)
			if (!strcmp(i0[m].name, i1[k].name))
				break;
		if (m == n0 || !strcmp(i1[k].name, "lo"))
			continue;
		if ((i1[k].rx - i0[m].rx) + (i1[k].tx - i0[m].tx) < t * 12500)
			continue;
		printf(" %s rx %.1f tx %.1f;", i1[k].name, (i1[k].rx - i0[m].rx) * 8 / t / 1e6,
		       (i1[k].tx - i0[m].tx) * 8 / t / 1e6);
	}
	printf("\n");

	load_kallsyms();
	for (i = 0; i < nsamples; i++) {
		struct sample *s = &samples[i];
		uint32_t f, caller = 0;

		if (s->ip < 0x80000000U) {
			add(&proc, &nproc, &cap_proc, s->pid);
			continue;
		}
		kernel++;
		if (mod_of(s->ip) >= 0)
			add(&modip, &nmodip, &cap_modip, s->ip);
		f = func_of(s->ip);
		add(&leaf, &nleaf, &cap_leaf, f);
		for (j = 0; j < CHAIN && s->chain[j]; j++) {
			caller = func_of(s->chain[j]);
			if (caller != f)
				break;
			caller = 0;
		}
		add(&pair, &npair, &cap_pair, (uint64_t)f << 32 | caller);
	}

	printf("%zu samples (%s, %d/s) in %.1f s: kernel %.1f%%, user %.1f%%, lost %lu\n", nsamples, event, freq,
	       t, nsamples ? 100.0 * kernel / nsamples : 0, nsamples ? 100.0 * (nsamples - kernel) / nsamples : 0,
	       lost);
	if (!nsamples)
		return 0;
	qsort(leaf, nleaf, sizeof(*leaf), by_count);
	qsort(pair, npair, sizeof(*pair), by_count);
	qsort(proc, nproc, sizeof(*proc), by_count);
	printf("== kernel functions (%% of all samples), with their main callers\n");
	for (i = 0; i < nleaf && (int)i < top; i++) {
		int shown = 0;

		printf("%6.2f%%  %s\n", 100.0 * leaf[i].n / nsamples, ksym(leaf[i].key));
		for (j = 0; j < npair && shown < 3; j++) {
			if ((uint32_t)(pair[j].key >> 32) != (uint32_t)leaf[i].key || !(uint32_t)pair[j].key)
				continue;
			if (100.0 * pair[j].n / nsamples < 0.3)
				break;
			printf("          %5.2f%% <- %s\n", 100.0 * pair[j].n / nsamples, ksym((uint32_t)pair[j].key));
			shown++;
		}
	}
	if (argc > 4) {
		FILE *f = fopen(argv[4], "w");

		for (i = 0; f && i < nmodip; i++) {
			uint32_t ip = (uint32_t)modip[i].key;

			k = mod_of(ip);
			if (k >= 0)
				fprintf(f, "%s 0x%x %lu\n", mods[k].name, ip - mods[k].base, modip[i].n);
		}
		if (f)
			fclose(f);
	}
	printf("== user space by process\n");
	for (i = 0; i < nproc && i < 10; i++) {
		char path[64], comm[64] = "?";
		FILE *f;

		snprintf(path, sizeof(path), "/proc/%u/comm", (unsigned)proc[i].key);
		f = fopen(path, "r");
		if (f) {
			if (fgets(comm, sizeof(comm), f))
				comm[strcspn(comm, "\n")] = 0;
			fclose(f);
		}
		printf("%6.2f%%  %s (%u)\n", 100.0 * proc[i].n / nsamples, comm, (unsigned)proc[i].key);
	}
	return 0;
}
