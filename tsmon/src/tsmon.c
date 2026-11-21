/*
 * isp-tester-tsmon - continuous MPEG-TS quality counter for IPTV multicast
 * (part of luci-app-isp-tester)
 *
 *   isp-tester-tsmon -i DEV [-v VID] [-d in|out] -o STATE.json [-g GAP_MS]
 *   isp-tester-tsmon -r CAPTURE.pcap [-g GAP_MS]
 *
 * Live mode listens on DEV with a packet socket. The kernel filter (classic
 * BPF) passes only IPv4 UDP multicast (not 224.0.0.x), in VLAN VID when -v is
 * given, so nothing else ever reaches this process. Every datagram is
 * counted as it arrives, nothing is stored: per multicast group it counts
 *   - continuity counter (CC) errors per PID: a gap means lost TS packets
 *   - lost TS packets (estimated from the CC jump), transport error flags
 *   - RTP sequence gaps, when the stream is RTP-wrapped
 *   - pauses between datagrams of at least GAP_MS, and the longest one
 *   - the channel name, from the stream's PAT and SDT tables (sent in the
 *     clear also on scrambled channels)
 * Datagrams that do not carry MPEG-TS (EPG / service groups) are ignored.
 * Once a second the cumulative counters of all groups are written to
 * STATE.json (atomically, via a .tmp file and rename); the collector reads it
 * and works out what changed. Packets the socket had to drop because this
 * process was too slow are reported too, so they are not mistaken for
 * losses of the ISP.
 *
 * -r reads a pcap file instead (offline test) and prints the same JSON once.
 *
 * The process ends when its parent (the collector) ends.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <arpa/inet.h>
#include <net/if.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <linux/filter.h>
#include <linux/if_ether.h>
#include <linux/if_packet.h>

#include "dvbtext.h"

#define MAX_GROUPS   16      /* groups followed at a time */
#define NPID         8192
#define CC_NONE      0xff
#define GROUP_IDLE   30.0    /* s without data: the group is forgotten */
#define GAP_RESET    5.0     /* s: a longer pause is a new stream (zap back), not a pause */
#define PSI_REFRESH  600.0   /* s: read PAT/SDT again (names change rarely) */
#define PSI_MAX      4096
#define NAME_MAX_LEN 64

struct psibuf {
	uint8_t data[PSI_MAX + 188];
	int len;                 /* -1 = not collecting */
};

struct service {
	int sid, type;
	char name[NAME_MAX_LEN * 3 + 1];
	char provider[NAME_MAX_LEN * 3 + 1];
};

#define MAX_SVC 16

struct group {
	int used;
	uint32_t addr;           /* network byte order */
	unsigned id;             /* unique in this run, lets the reader see a new group */
	double t_first, t_last, t_psi;
	uint64_t pkts, bytes, ts_pkts;
	uint64_t cc_err, lost, tei, sync_err;
	uint64_t gaps, restarts;
	unsigned gap_last_ms, gap_max_ms;
	int rtp;
	int rtp_seq;
	uint64_t rtp_lost;
	/* bitrate since the last report */
	uint64_t rep_bytes, rep_pkts;
	double rep_t;
	unsigned kbps, pps;
	uint8_t last_cc[NPID];
	uint8_t dup[NPID];
	/* channel name */
	int psi_done, pat_seen, sdt_seen;
	int pat[MAX_SVC], npat;
	struct service svc[MAX_SVC];
	int nsvc;
	struct psibuf psi[2];    /* PID 0, PID 0x11 */
};

static struct group groups[MAX_GROUPS];

/* DHCP replies of the operator's server to the decoders (-D): the decoder's
 * lease lives at the ISP, so only these packets show it. A ring of the last
 * ones, numbered, read by the collector. */
#define DHCP_RING 16
struct dhcp_ev {
	unsigned seq;
	long wall;
	int type;                        /* 2 OFFER, 5 ACK, 6 NAK */
	uint8_t mac[6];
	uint32_t ip, server, mask, router, lease;
};
static struct dhcp_ev dhcp_ring[DHCP_RING];
static unsigned dhcp_seq;
static int want_dhcp;
static unsigned next_id = 1;
static unsigned gap_ms = 500;
static uint64_t other, sock_drops;
static volatile sig_atomic_t stop;

__attribute__((noreturn, format(printf, 2, 3)))
static void die(int code, const char *fmt, ...)
{
	va_list ap;
	fprintf(stderr, "isp-tester-tsmon: ");
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
	exit(code);
}

static double mono_now(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ------------------------------------------------------------ DVB text */

static void put_u8(char **o, char *end, unsigned cp)
{
	char *p = *o;
	if (cp < 0x80) { if (p + 1 > end) return; *p++ = cp; }
	else if (cp < 0x800) { if (p + 2 > end) return; *p++ = 0xc0 | (cp >> 6); *p++ = 0x80 | (cp & 63); }
	else { if (p + 3 > end) return; *p++ = 0xe0 | (cp >> 12); *p++ = 0x80 | ((cp >> 6) & 63); *p++ = 0x80 | (cp & 63); }
	*o = p;
}

/* text that is already UTF-8: keep only well-formed sequences */
static void utf8_clean(const uint8_t *s, int n, int p, char **o, char *end)
{
	while (p < n) {
		unsigned c = s[p];
		int k = 0, j, ok = 1;
		if (c < 0x80) { if (c >= 0x20 && c != 0x7f && *o < end) *(*o)++ = c; p++; continue; }
		if (c >= 0xc2 && c <= 0xdf) k = 1;
		else if (c >= 0xe0 && c <= 0xef) k = 2;
		else if (c >= 0xf0 && c <= 0xf4) k = 3;
		else { p++; continue; }
		for (j = 1; j <= k; j++)
			if (p + j >= n || (s[p + j] & 0xc0) != 0x80) { ok = 0; break; }
		if (!ok) { p++; continue; }
		/* DVB control codes in UTF-8 text are U+E080..U+E09F */
		unsigned cp = (k == 2) ? ((c & 15) << 12) | ((s[p + 1] & 63) << 6) | (s[p + 2] & 63) : 0;
		if (!(cp >= 0xe080 && cp <= 0xe09f) && *o + k + 1 <= end) {
			memcpy(*o, s + p, k + 1);
			*o += k + 1;
		}
		p += k + 1;
	}
}

/* DVB string (EN 300 468 annex A) -> UTF-8 */
static void dvb_text(const uint8_t *s, int n, char *out, size_t outsz)
{
	char *o = out, *end = out + outsz - 1;
	int p = 0, tbl;                  /* 0 = ISO 6937, 1..16 = ISO 8859-n, -1 = ASCII only */

	*out = 0;
	if (n <= 0) return;
	unsigned b = s[0];
	if (b >= 0x20) tbl = 0;
	else if (b >= 0x01 && b <= 0x0b) { tbl = b + 4; p = 1; }
	else if (b == 0x10 && n >= 3) { tbl = s[2]; p = 3; if (tbl < 1 || tbl > 16) tbl = -1; }
	else if (b == 0x15) { utf8_clean(s, n, 1, &o, end); *o = 0; return; }
	else if (b == 0x11) {
		/* UCS-2, big-endian */
		for (p = 1; p + 1 < n; p += 2) {
			unsigned cp = (s[p] << 8) | s[p + 1];
			if (cp >= 0x20 && !(cp >= 0x7f && cp <= 0x9f) && !(cp >= 0xd800 && cp <= 0xdfff) && !(cp >= 0xe080 && cp <= 0xe09f))
				put_u8(&o, end, cp);
		}
		*o = 0;
		return;
	}
	else { tbl = -1; p = 1; }        /* GB2312, Big5, KSC: only the ASCII part */

	while (p < n) {
		unsigned c = s[p++], cp = 0;
		if (c < 0x20 || c == 0x7f) continue;
		if (c < 0x80) { put_u8(&o, end, c); continue; }
		if (c < 0xa0) {
			/* control codes: 0x8a is a line break, the rest is emphasis on/off */
			if (c == 0x8a) put_u8(&o, end, ' ');
			continue;
		}
		if (tbl == 0) {
			if (c >= 0xc1 && c <= 0xcf) {
				size_t i;
				int is_acc = 0;
				for (i = 0; i < sizeof(acc6937) / sizeof(acc6937[0]); i++)
					if (acc6937[i].acc == c) { is_acc = 1; break; }
				if (is_acc) {
					if (p >= n) break;
					unsigned l = s[p++];
					/* accent with a letter it does not combine with: keep the letter */
					cp = l;
					for (i = 0; i < sizeof(acc6937) / sizeof(acc6937[0]); i++)
						if (acc6937[i].acc == c && (uint8_t)acc6937[i].base == l) { cp = acc6937[i].cp; break; }
				}
				else
					cp = iso6937[c - 0xa0];
			}
			else
				cp = iso6937[c - 0xa0];
		}
		else if (tbl > 0)
			cp = iso8859[tbl][c - 0xa0];
		if (cp) put_u8(&o, end, cp);
	}
	*o = 0;
}

/* collapse white space, trim, at most NAME_MAX_LEN characters */
static void clean_name(char *s)
{
	char *r = s, *w = s;
	int sp = 0, chars = 0;
	while (*r == ' ' || *r == '\t' || *r == '\n') r++;
	while (*r) {
		if (*r == ' ' || *r == '\t' || *r == '\n') { sp = 1; r++; continue; }
		if (sp) {
			if (chars >= NAME_MAX_LEN) break;
			*w++ = ' '; chars++; sp = 0;
		}
		if (((uint8_t)*r & 0xc0) != 0x80) {
			if (chars >= NAME_MAX_LEN) break;
			chars++;
		}
		*w++ = *r++;
	}
	*w = 0;
}

/* --------------------------------------------------------------- PSI */

static uint32_t crc_tab[256];

static void crc_init(void)
{
	for (uint32_t i = 0; i < 256; i++) {
		uint32_t c = i << 24;
		for (int j = 0; j < 8; j++)
			c = (c & 0x80000000) ? (c << 1) ^ 0x04c11db7 : (c << 1);
		crc_tab[i] = c;
	}
}

/* CRC-32/MPEG-2 over a whole section (including its CRC): 0 when intact */
static int crc32_ok(const uint8_t *s, int n)
{
	uint32_t crc = 0xffffffff;
	for (int i = 0; i < n; i++)
		crc = (crc << 8) ^ crc_tab[((crc >> 24) ^ s[i]) & 255];
	return crc == 0;
}

static void parse_section(struct group *g, const uint8_t *s, int n)
{
	int tid = s[0];
	if (n < 12 || !(s[1] & 0x80) || !crc32_ok(s, n)) return;
	/* current_next_indicator: ignore tables that are not in force yet */
	if (!(s[5] & 1)) return;

	if (tid == 0x00) {
		g->npat = 0;
		for (int p = 8; p + 4 <= n - 4; p += 4) {
			int pn = (s[p] << 8) | s[p + 1];
			if (pn && g->npat < MAX_SVC) g->pat[g->npat++] = pn;
		}
		g->pat_seen = 1;
	}
	else if (tid == 0x42) {
		/* SDT of this transport stream (0x46 = other streams: skip) */
		int p = 11;
		g->sdt_seen = 1;
		while (p + 5 <= n - 4) {
			int sid = (s[p] << 8) | s[p + 1];
			int dl = ((s[p + 3] & 0x0f) << 8) | s[p + 4];
			int d = p + 5, dend = d + dl;
			if (dend > n - 4) break;
			while (d + 2 <= dend) {
				int tag = s[d], len = s[d + 1];
				if (d + 2 + len > dend) break;
				if (tag == 0x48 && len >= 3) {
					int st = s[d + 2], pl = s[d + 3];
					int nl = (4 + pl < len + 2) ? s[d + 4 + pl] : 0;
					if (5 + pl + nl <= len + 2) {
						char name[sizeof(g->svc[0].name)];
						dvb_text(s + d + 5 + pl, nl, name, sizeof(name));
						clean_name(name);
						if (*name) {
							int i;
							for (i = 0; i < g->nsvc; i++)
								if (g->svc[i].sid == sid) break;
							if (i == g->nsvc && g->nsvc < MAX_SVC) g->nsvc++;
							if (i < g->nsvc) {
								struct service *sv = &g->svc[i];
								sv->sid = sid;
								sv->type = st;
								strcpy(sv->name, name);
								dvb_text(s + d + 4, pl, sv->provider, sizeof(sv->provider));
								clean_name(sv->provider);
							}
						}
					}
				}
				d += 2 + len;
			}
			p = dend;
		}
	}
	if (g->pat_seen && g->nsvc) {
		for (int i = 0; i < g->npat; i++)
			for (int j = 0; j < g->nsvc; j++)
				if (g->svc[j].sid == g->pat[i]) { g->psi_done = 1; return; }
	}
}

static void psi_drain(struct group *g, struct psibuf *st)
{
	while (st->len >= 3) {
		if (st->data[0] == 0xff) { st->len = -1; break; }
		int sl = (((st->data[1] & 0x0f) << 8) | st->data[2]) + 3;
		if (sl > PSI_MAX) { st->len = -1; break; }
		if (st->len < sl) break;
		parse_section(g, st->data, sl);
		if (st->len > sl) {
			memmove(st->data, st->data + sl, st->len - sl);
			st->len -= sl;
		}
		else
			st->len = -1;
	}
}

static void psi_add(struct psibuf *st, const uint8_t *p, int n)
{
	if (st->len < 0 || n <= 0) return;
	if (st->len + n > (int)sizeof(st->data)) { st->len = -1; return; }
	memcpy(st->data + st->len, p, n);
	st->len += n;
}

/* collect PSI sections of PID 0 / 0x11 from one TS packet */
static void psi_packet(struct group *g, int pid, const uint8_t *q, int x1, int afc)
{
	struct psibuf *st = &g->psi[pid ? 1 : 0];
	int off = 4, end = 188;
	if (afc & 2) off += 1 + q[4];
	if (off >= end) return;

	if (x1 & 0x40) {
		int ptr = q[off++];
		if (st->len >= 0 && off + ptr <= end)
			psi_add(st, q + off, ptr);
		psi_drain(g, st);
		off += ptr;
		if (off < end) {
			st->len = 0;
			psi_add(st, q + off, end - off);
		}
		else
			st->len = -1;
	}
	else if (st->len >= 0)
		psi_add(st, q + off, end - off);
	else
		return;
	psi_drain(g, st);
}

/* the service this stream carries: the one the PAT names, else the only one */
static const struct service *group_service(const struct group *g)
{
	for (int i = 0; i < g->npat; i++)
		for (int j = 0; j < g->nsvc; j++)
			if (g->svc[j].sid == g->pat[i]) return &g->svc[j];
	return (g->nsvc == 1) ? &g->svc[0] : NULL;
}

/* ------------------------------------------------------------ groups */

static void psi_reset(struct group *g)
{
	g->psi_done = 0;
	g->psi[0].len = g->psi[1].len = -1;
}

static void cc_reset(struct group *g)
{
	memset(g->last_cc, CC_NONE, sizeof(g->last_cc));
	memset(g->dup, 0, sizeof(g->dup));
	g->rtp_seq = -1;
}

static struct group *group_get(uint32_t addr, double t)
{
	struct group *free_g = NULL, *oldest = NULL;
	for (int i = 0; i < MAX_GROUPS; i++) {
		struct group *g = &groups[i];
		if (g->used && g->addr == addr) return g;
		if (!g->used && !free_g) free_g = g;
		if (g->used && (!oldest || g->t_last < oldest->t_last)) oldest = g;
	}
	struct group *g = free_g ? free_g : oldest;
	memset(g, 0, sizeof(*g));
	g->used = 1;
	g->addr = addr;
	g->id = next_id++;
	g->t_first = g->t_last = g->t_psi = g->rep_t = t;
	g->t_last = -1;
	cc_reset(g);
	psi_reset(g);
	return g;
}

static void groups_expire(double t)
{
	for (int i = 0; i < MAX_GROUPS; i++)
		if (groups[i].used && groups[i].t_last >= 0 && t - groups[i].t_last > GROUP_IDLE)
			groups[i].used = 0;
}

/* --------------------------------------------------- one datagram */

static inline unsigned be16(const uint8_t *p) { return (p[0] << 8) | p[1]; }

/* BOOTP/DHCP reply (server port 67 -> client port 68), b = UDP payload */
static void dhcp_frame(const uint8_t *b, int n)
{
	if (n < 240 || b[0] != 2 || b[1] != 1 || b[2] != 6) return;
	if (b[236] != 0x63 || b[237] != 0x82 || b[238] != 0x53 || b[239] != 0x63) return;
	struct dhcp_ev e;
	memset(&e, 0, sizeof(e));
	for (int p = 240; p < n; ) {
		int code = b[p];
		if (code == 0) { p++; continue; }
		if (code == 255 || p + 1 >= n) break;
		int len = b[p + 1];
		const uint8_t *v = b + p + 2;
		if (p + 2 + len > n) break;
		if (code == 53 && len >= 1) e.type = v[0];
		else if (code == 51 && len >= 4) e.lease = ((uint32_t)v[0] << 24) | (v[1] << 16) | (v[2] << 8) | v[3];
		else if (code == 54 && len >= 4) memcpy(&e.server, v, 4);
		else if (code == 1 && len >= 4) memcpy(&e.mask, v, 4);
		else if (code == 3 && len >= 4) memcpy(&e.router, v, 4);
		p += 2 + len;
	}
	if (e.type != 2 && e.type != 5 && e.type != 6) return;
	memcpy(e.mac, b + 28, 6);
	memcpy(&e.ip, b + 16, 4);
	e.seq = ++dhcp_seq;
	e.wall = (long)time(NULL);
	dhcp_ring[e.seq % DHCP_RING] = e;
}

/* frame: Ethernet frame as received (VLAN tag inline or already removed by
 * the kernel), caplen bytes of it present, wirelen its real length */
static void handle_frame(const uint8_t *f, int caplen, int wirelen, double t)
{
	if (caplen < 14 + 20 + 8) return;
	unsigned et = be16(f + 12);
	int ip = 14;
	if (et == 0x8100 || et == 0x88a8) {
		if (caplen < 18 + 20 + 8) return;
		et = be16(f + 16);
		ip = 18;
	}
	if (et != 0x0800) return;

	const uint8_t *h = f + ip;
	if ((h[0] >> 4) != 4 || h[9] != 17) return;
	int ihl = (h[0] & 15) * 4;
	if (ihl < 20) return;
	/* fragments cannot be parsed without reassembly */
	if ((h[6] & 0x3f) || h[7] || (h[6] & 0x20)) { other++; return; }
	if ((h[16] & 0xf0) != 0xe0) {
		int u = ip + ihl;
		if (want_dhcp && caplen >= u + 8 && be16(f + u) == 67 && be16(f + u + 2) == 68)
			dhcp_frame(f + u + 8, caplen - u - 8);
		return;
	}

	uint32_t addr;
	memcpy(&addr, h + 16, 4);

	int plen = (int)be16(h + 2) - ihl - 8;
	int pl = ip + ihl + 8;
	if (pl + plen > caplen) plen = caplen - pl;
	if (plen < 188) { other++; return; }

	/* raw TS, or RTP (version 2) carrying TS */
	const uint8_t *ts = f + pl;
	int tlen = plen, rtp = 0, seq = 0;
	if (ts[0] != 0x47) {
		const uint8_t *r = ts;
		if ((r[0] >> 6) != 2) { other++; return; }
		int hdr = 12 + 4 * (r[0] & 15);
		if ((r[0] & 0x10) && plen >= hdr + 4)
			hdr += 4 + 4 * be16(r + hdr + 2);
		if (plen <= hdr || r[hdr] != 0x47) { other++; return; }
		ts = r + hdr;
		tlen = plen - hdr;
		rtp = 1;
		seq = be16(r + 2);
	}

	struct group *g = group_get(addr, t);

	/* datagram timing; a long silence is a new stream (channel changed
	 * back, decoder restarted), where the counters start over */
	if (g->t_last >= 0) {
		double gap = t - g->t_last;
		if (gap >= GAP_RESET) {
			g->restarts++;
			cc_reset(g);
		}
		else if (gap > 0) {
			unsigned ms = (unsigned)(gap * 1000 + 0.5);
			if (ms > g->gap_max_ms) g->gap_max_ms = ms;
			if (gap_ms && ms >= gap_ms) { g->gaps++; g->gap_last_ms = ms; }
		}
	}

	if (rtp) {
		g->rtp = 1;
		if (g->rtp_seq >= 0) {
			unsigned d = (seq - g->rtp_seq) & 0xffff;
			/* repeated or reordered packet: not a loss */
			if (d == 0 || d > 0x8000) { g->t_last = t; return; }
			g->rtp_lost += d - 1;
		}
		g->rtp_seq = seq;
	}

	g->t_last = t;
	g->pkts++;
	g->bytes += wirelen;

	if (g->psi_done && t - g->t_psi > PSI_REFRESH) {
		g->t_psi = t;
		psi_reset(g);
	}

	for (const uint8_t *q = ts; q + 188 <= ts + tlen; q += 188) {
		if (q[0] != 0x47) { g->sync_err++; break; }
		int x1 = q[1], x2 = q[2], x3 = q[3];
		g->ts_pkts++;
		int pid = ((x1 & 0x1f) << 8) | x2;
		if (pid == 0x1fff) continue;
		if (x1 & 0x80) g->tei++;
		int afc = (x3 >> 4) & 3;
		if (afc == 0) continue;
		/* PAT / SDT for the channel name, until the service is known */
		if (!g->psi_done && (pid == 0 || pid == 0x11) && (afc & 1) && !(x1 & 0x80))
			psi_packet(g, pid, q, x1, afc);
		int cc = x3 & 15;
		if (afc & 2) {
			/* discontinuity indicator: the counter may jump here */
			if (q[4] > 0 && (q[5] & 0x80)) {
				g->last_cc[pid] = (afc & 1) ? cc : CC_NONE;
				g->dup[pid] = 0;
				continue;
			}
		}
		/* packets without payload do not advance the counter */
		if (!(afc & 1)) continue;

		int lc = g->last_cc[pid];
		if (lc != CC_NONE) {
			int exp = (lc + 1) & 15;
			if (cc == exp)
				g->dup[pid] = 0;
			else if (cc == lc && !g->dup[pid]) {
				/* one duplicate packet in a row is allowed by the standard */
				g->dup[pid] = 1;
				continue;
			}
			else {
				g->cc_err++;
				g->lost += (cc - exp) & 15;
				g->dup[pid] = 0;
			}
		}
		g->last_cc[pid] = cc;
	}
}

/* ---------------------------------------------------------- output */

static void json_str(FILE *o, const char *s)
{
	fputc('"', o);
	for (; *s; s++) {
		unsigned char c = *s;
		if (c == '"' || c == '\\') fprintf(o, "\\%c", c);
		else if (c < 0x20) fprintf(o, "\\u%04x", c);
		else fputc(c, o);
	}
	fputc('"', o);
}

static void write_json(FILE *o, double t, double up, const char *dev, int vid, int wall)
{
	char ip[INET_ADDRSTRLEN];
	int first = 1;

	fprintf(o, "{\"v\":1,\"pid\":%d,\"ts\":%ld,\"up\":%.1f,", (int)getpid(), (long)wall, up);
	fputs("\"dev\":", o);
	json_str(o, dev ? dev : "");
	fprintf(o, ",\"vid\":%d,\"gap_ms\":%u,\"drops\":%llu,\"other\":%llu,\"groups\":[",
		vid, gap_ms, (unsigned long long)sock_drops, (unsigned long long)other);

	for (int i = 0; i < MAX_GROUPS; i++) {
		struct group *g = &groups[i];
		if (!g->used || !g->ts_pkts) continue;
		inet_ntop(AF_INET, &g->addr, ip, sizeof(ip));
		fprintf(o, "%s{\"grp\":\"%s\",\"id\":%u,\"age\":%.1f,\"idle\":%.1f,\"kbps\":%u,\"pps\":%u,"
			"\"pkts\":%llu,\"ts_pkts\":%llu,\"cc\":%llu,\"lost\":%llu,\"tei\":%llu,\"sync\":%llu,"
			"\"gaps\":%llu,\"gap_last_ms\":%u,\"gap_max_ms\":%u,\"restarts\":%llu,"
			"\"rtp\":%s,\"rtp_lost\":%llu,\"psi\":{\"pat\":%s,\"sdt\":%s}",
			first ? "" : ",", ip, g->id, t - g->t_first, g->t_last >= 0 ? t - g->t_last : 0.0,
			g->kbps, g->pps,
			(unsigned long long)g->pkts, (unsigned long long)g->ts_pkts,
			(unsigned long long)g->cc_err, (unsigned long long)g->lost,
			(unsigned long long)g->tei, (unsigned long long)g->sync_err,
			(unsigned long long)g->gaps, g->gap_last_ms, g->gap_max_ms,
			(unsigned long long)g->restarts,
			g->rtp ? "true" : "false", (unsigned long long)g->rtp_lost,
			g->pat_seen ? "true" : "false", g->sdt_seen ? "true" : "false");
		const struct service *sv = group_service(g);
		if (sv) {
			fprintf(o, ",\"svc\":{\"sid\":%d,\"type\":%d,\"name\":", sv->sid, sv->type);
			json_str(o, sv->name);
			fputs(",\"provider\":", o);
			if (*sv->provider) json_str(o, sv->provider); else fputs("null", o);
			fputc('}', o);
		}
		else
			fputs(",\"svc\":null", o);
		fputc('}', o);
		first = 0;
	}
	fputs("]", o);

	if (want_dhcp) {
		char a[4][INET_ADDRSTRLEN];
		fprintf(o, ",\"dhcp_seq\":%u,\"dhcp\":[", dhcp_seq);
		first = 1;
		unsigned from = dhcp_seq > DHCP_RING ? dhcp_seq - DHCP_RING + 1 : 1;
		for (unsigned s = from; s <= dhcp_seq; s++) {
			const struct dhcp_ev *e = &dhcp_ring[s % DHCP_RING];
			if (e->seq != s) continue;
			inet_ntop(AF_INET, &e->ip, a[0], sizeof(a[0]));
			inet_ntop(AF_INET, &e->server, a[1], sizeof(a[1]));
			inet_ntop(AF_INET, &e->mask, a[2], sizeof(a[2]));
			inet_ntop(AF_INET, &e->router, a[3], sizeof(a[3]));
			fprintf(o, "%s{\"seq\":%u,\"t\":%ld,\"type\":%d,\"mac\":\"%02x:%02x:%02x:%02x:%02x:%02x\","
				"\"ip\":\"%s\",\"server\":\"%s\",\"mask\":\"%s\",\"router\":\"%s\",\"lease\":%u}",
				first ? "" : ",", e->seq, e->wall, e->type,
				e->mac[0], e->mac[1], e->mac[2], e->mac[3], e->mac[4], e->mac[5],
				a[0], a[1], a[2], a[3], e->lease);
			first = 0;
		}
		fputc(']', o);
	}
	fputs("}\n", o);
}

static void update_rates(double t)
{
	for (int i = 0; i < MAX_GROUPS; i++) {
		struct group *g = &groups[i];
		if (!g->used) continue;
		double dt = t - g->rep_t;
		if (dt < 0.5) continue;
		g->kbps = (unsigned)((g->bytes - g->rep_bytes) * 8 / dt / 1000);
		g->pps = (unsigned)((g->pkts - g->rep_pkts) / dt);
		g->rep_bytes = g->bytes;
		g->rep_pkts = g->pkts;
		g->rep_t = t;
	}
}

static int write_state(const char *path, double t, double up, const char *dev, int vid)
{
	char tmp[4096];
	if (snprintf(tmp, sizeof(tmp), "%s.tmp", path) >= (int)sizeof(tmp)) return -1;
	FILE *o = fopen(tmp, "w");
	if (!o) return -1;
	write_json(o, t, up, dev, vid, (int)time(NULL));
	if (fclose(o) != 0) { unlink(tmp); return -1; }
	return rename(tmp, path);
}

/* ------------------------------------------------------- pcap file */

static uint32_t rd32(const uint8_t *p, int le)
{
	return le ? (p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24))
	          : (((uint32_t)p[0] << 24) | (p[1] << 16) | (p[2] << 8) | p[3]);
}

static int run_pcap(const char *file)
{
	FILE *f = fopen(file, "rb");
	if (!f) die(1, "cannot open %s: %s", file, strerror(errno));
	uint8_t hdr[24], rec[16];
	static uint8_t buf[262144];
	if (fread(hdr, 1, 24, f) != 24) die(1, "%s: not a pcap file", file);
	int le = 0;
	double tdiv = 1e6;
	if (hdr[0] == 0xd4 && hdr[1] == 0xc3 && hdr[2] == 0xb2 && hdr[3] == 0xa1) le = 1;
	else if (hdr[0] == 0xa1 && hdr[1] == 0xb2 && hdr[2] == 0xc3 && hdr[3] == 0xd4) le = 0;
	else if (hdr[0] == 0x4d && hdr[1] == 0x3c && hdr[2] == 0xb2 && hdr[3] == 0xa1) { le = 1; tdiv = 1e9; }
	else if (hdr[0] == 0xa1 && hdr[1] == 0xb2 && hdr[2] == 0x3c && hdr[3] == 0x4d) { le = 0; tdiv = 1e9; }
	else die(1, "%s: not a pcap file", file);
	if (rd32(hdr + 20, le) != 1) die(1, "%s: not an Ethernet capture", file);

	double t0 = -1, t = 0;
	while (fread(rec, 1, 16, f) == 16) {
		uint32_t incl = rd32(rec + 8, le), orig = rd32(rec + 12, le);
		if (incl > sizeof(buf)) break;
		if (fread(buf, 1, incl, f) != incl) break;
		t = rd32(rec, le) + rd32(rec + 4, le) / tdiv;
		if (t0 < 0) t0 = t;
		handle_frame(buf, incl, orig, t);
	}
	fclose(f);
	/* rates over the whole file */
	for (int i = 0; i < MAX_GROUPS; i++)
		if (groups[i].used) groups[i].rep_t = groups[i].t_first;
	update_rates(t);
	write_json(stdout, t, t0 >= 0 ? t - t0 : 0, file, 0, (int)time(NULL));
	return 0;
}

/* ----------------------------------------------------------- live */

struct prog {
	struct sock_filter ins[128];
	int n;
	/* jumps to fix up: index, target for jt, target for jf (-1 = keep) */
	int fix_jt[128], fix_jf[128];
};

#define L_ACCEPT 1000
#define L_DROP   1001

static int emit(struct prog *p, uint16_t code, uint32_t k, int jt, int jf)
{
	int i = p->n++;
	p->ins[i] = (struct sock_filter){ code, 0, 0, k };
	p->fix_jt[i] = jt;
	p->fix_jf[i] = jf;
	return i;
}

/* IPv4 header at base: UDP, to 224.0.0.0/4 but not 224.0.0.0/24; with -D
 * also unfragmented UDP from port 67 to port 68 (DHCP server replies) */
static void emit_ipcheck(struct prog *p, int base)
{
	int next, j_mc;
	emit(p, BPF_LD | BPF_B | BPF_ABS, base + 9, 0, 0);
	next = p->n + 1;
	emit(p, BPF_JMP | BPF_JEQ | BPF_K, 17, next, L_DROP);
	emit(p, BPF_LD | BPF_W | BPF_ABS, base + 16, 0, 0);
	emit(p, BPF_ALU | BPF_AND | BPF_K, 0xf0000000, 0, 0);
	next = p->n + 1;
	j_mc = emit(p, BPF_JMP | BPF_JEQ | BPF_K, 0xe0000000, next, want_dhcp ? -2 : L_DROP);  /* jf fixed below */
	emit(p, BPF_LD | BPF_W | BPF_ABS, base + 16, 0, 0);
	emit(p, BPF_ALU | BPF_AND | BPF_K, 0xffffff00, 0, 0);
	emit(p, BPF_JMP | BPF_JEQ | BPF_K, 0xe0000000, L_DROP, L_ACCEPT);
	if (!want_dhcp) return;
	p->fix_jf[j_mc] = p->n;
	emit(p, BPF_LD | BPF_H | BPF_ABS, base + 6, 0, 0);
	emit(p, BPF_JMP | BPF_JSET | BPF_K, 0x1fff, L_DROP, p->n + 1);
	emit(p, BPF_LDX | BPF_B | BPF_MSH, base, 0, 0);
	emit(p, BPF_LD | BPF_H | BPF_IND, base, 0, 0);
	emit(p, BPF_JMP | BPF_JEQ | BPF_K, 67, p->n + 1, L_DROP);
	emit(p, BPF_LD | BPF_H | BPF_IND, base + 2, 0, 0);
	emit(p, BPF_JMP | BPF_JEQ | BPF_K, 68, L_ACCEPT, L_DROP);
}

static void build_filter(struct prog *p, int vid)
{
	int accept, drop, i;
	p->n = 0;
	if (!vid) {
		emit(p, BPF_LD | BPF_H | BPF_ABS, 12, 0, 0);
		emit(p, BPF_JMP | BPF_JEQ | BPF_K, 0x0800, p->n + 1, L_DROP);
		emit_ipcheck(p, 14);
	}
	else {
		/* the tag is usually moved out of the frame by the kernel (ancillary
		 * data); handle a tag left inline too */
		int j_inline;
		emit(p, BPF_LD | BPF_W | BPF_ABS, SKF_AD_OFF + SKF_AD_VLAN_TAG_PRESENT, 0, 0);
		j_inline = emit(p, BPF_JMP | BPF_JEQ | BPF_K, 1, p->n + 1, -2);  /* jf fixed below */
		emit(p, BPF_LD | BPF_W | BPF_ABS, SKF_AD_OFF + SKF_AD_VLAN_TAG, 0, 0);
		emit(p, BPF_ALU | BPF_AND | BPF_K, 0x0fff, 0, 0);
		emit(p, BPF_JMP | BPF_JEQ | BPF_K, vid, p->n + 1, L_DROP);
		emit(p, BPF_LD | BPF_H | BPF_ABS, 12, 0, 0);
		emit(p, BPF_JMP | BPF_JEQ | BPF_K, 0x0800, p->n + 1, L_DROP);
		emit_ipcheck(p, 14);
		p->fix_jf[j_inline] = p->n;
		emit(p, BPF_LD | BPF_H | BPF_ABS, 12, 0, 0);
		emit(p, BPF_JMP | BPF_JEQ | BPF_K, 0x8100, p->n + 1, L_DROP);
		emit(p, BPF_LD | BPF_H | BPF_ABS, 14, 0, 0);
		emit(p, BPF_ALU | BPF_AND | BPF_K, 0x0fff, 0, 0);
		emit(p, BPF_JMP | BPF_JEQ | BPF_K, vid, p->n + 1, L_DROP);
		emit(p, BPF_LD | BPF_H | BPF_ABS, 16, 0, 0);
		emit(p, BPF_JMP | BPF_JEQ | BPF_K, 0x0800, p->n + 1, L_DROP);
		emit_ipcheck(p, 18);
	}
	accept = emit(p, BPF_RET | BPF_K, 0x40000, 0, 0);
	drop = emit(p, BPF_RET | BPF_K, 0, 0, 0);
	for (i = 0; i < p->n; i++) {
		if (BPF_CLASS(p->ins[i].code) != BPF_JMP) continue;
		int tt = p->fix_jt[i] == L_ACCEPT ? accept : p->fix_jt[i] == L_DROP ? drop : p->fix_jt[i];
		int tf = p->fix_jf[i] == L_ACCEPT ? accept : p->fix_jf[i] == L_DROP ? drop : p->fix_jf[i];
		if (tt <= i || tf <= i || tt - i - 1 > 255 || tf - i - 1 > 255)
			die(1, "internal error: filter jump");
		p->ins[i].jt = tt - i - 1;
		p->ins[i].jf = tf - i - 1;
	}
}

static void on_signal(int sig) { (void)sig; stop = 1; }

static int run_live(const char *dev, int vid, int dir_out, const char *state)
{
	struct prog prog;
	unsigned ifindex = if_nametoindex(dev);
	if (!ifindex) die(3, "no such device: %s", dev);

	int fd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
	if (fd < 0) die(4, "packet socket: %s", strerror(errno));

	/* filter first, then bind: no unfiltered packet is ever queued */
	build_filter(&prog, vid);
	struct sock_fprog fp = { .len = prog.n, .filter = prog.ins };
	if (setsockopt(fd, SOL_SOCKET, SO_ATTACH_FILTER, &fp, sizeof(fp)) < 0)
		die(4, "attach filter: %s", strerror(errno));

	int rcv = 2 * 1024 * 1024;
	setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &rcv, sizeof(rcv));

	struct sockaddr_ll sll = { .sll_family = AF_PACKET, .sll_protocol = htons(ETH_P_ALL), .sll_ifindex = ifindex };
	if (bind(fd, (struct sockaddr *)&sll, sizeof(sll)) < 0)
		die(4, "bind %s: %s", dev, strerror(errno));

	/* multicast the device has not joined itself (e.g. a decoder's
	 * channels on a bridge port) must reach the socket too */
	struct packet_mreq mr = { .mr_ifindex = ifindex, .mr_type = PACKET_MR_ALLMULTI };
	setsockopt(fd, SOL_PACKET, PACKET_ADD_MEMBERSHIP, &mr, sizeof(mr));

	/* drop what was queued before the filter took effect */
	{
		uint8_t junk[64];
		while (recv(fd, junk, sizeof(junk), MSG_DONTWAIT) > 0);
		struct tpacket_stats ps;
		socklen_t pl = sizeof(ps);
		getsockopt(fd, SOL_PACKET, PACKET_STATISTICS, &ps, &pl);
	}

	static uint8_t buf[65536];
	double t_start = mono_now(), next_rep = t_start + 1.0;
	/* packets are stamped with the monotonic clock when read, so a clock
	 * step (NTP) is never taken for a pause */
	write_state(state, t_start, 0, dev, vid);

	while (!stop) {
		double nowm = mono_now();
		int timeout = (int)((next_rep - nowm) * 1000);
		if (timeout < 0) timeout = 0;
		struct pollfd pfd = { .fd = fd, .events = POLLIN };
		int r = poll(&pfd, 1, timeout);
		if (r < 0 && errno != EINTR) die(5, "poll: %s", strerror(errno));
		if (r > 0 && (pfd.revents & (POLLERR | POLLHUP | POLLNVAL)))
			die(6, "%s: device went away", dev);

		/* read what is queued, but report at least once a second */
		for (int burst = 0; r > 0 && burst < 4096; burst++) {
			struct sockaddr_ll from;
			struct iovec iov = { buf, sizeof(buf) };
			struct msghdr mh = { .msg_name = &from, .msg_namelen = sizeof(from),
				.msg_iov = &iov, .msg_iovlen = 1 };
			ssize_t n = recvmsg(fd, &mh, MSG_DONTWAIT | MSG_TRUNC);
			if (n < 0) {
				if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) break;
				if (errno == ENETDOWN) { usleep(200000); break; }
				die(6, "recv: %s", strerror(errno));
			}
			int outgoing = from.sll_pkttype == PACKET_OUTGOING;
			if (outgoing != dir_out) continue;
			int caplen = (n > (ssize_t)sizeof(buf)) ? (int)sizeof(buf) : (int)n;
			int wire = (int)n;
			/* the kernel removed the VLAN tag: count it in the length */
			if (vid && caplen >= 14 && be16(buf + 12) != 0x8100) wire += 4;
			handle_frame(buf, caplen, wire, mono_now());
		}

		nowm = mono_now();
		if (nowm >= next_rep) {
			struct tpacket_stats ps;
			socklen_t pl = sizeof(ps);
			if (getsockopt(fd, SOL_PACKET, PACKET_STATISTICS, &ps, &pl) == 0)
				sock_drops += ps.tp_drops;
			groups_expire(nowm);
			update_rates(nowm);
			if (write_state(state, nowm, nowm - t_start, dev, vid) < 0)
				die(7, "cannot write %s: %s", state, strerror(errno));
			next_rep += 1.0;
			if (next_rep < nowm) next_rep = nowm + 1.0;
			/* the collector is gone (PDEATHSIG covers it, this is a backstop) */
			if (getppid() == 1) break;
		}
	}
	close(fd);
	unlink(state);
	return 0;
}

__attribute__((noreturn))
static void usage(void)
{
	fprintf(stderr,
		"usage: isp-tester-tsmon -i DEV [-v VID] [-d in|out] -o STATE.json [-g GAP_MS] [-D]\n"
		"       isp-tester-tsmon -r CAPTURE.pcap [-g GAP_MS] [-D]\n"
		"  -D  also note the DHCP server's replies (lease of the decoders)\n");
	exit(2);
}

int main(int argc, char **argv)
{
	const char *dev = NULL, *state = NULL, *pcap = NULL;
	int vid = 0, dir_out = 0, c;

	while ((c = getopt(argc, argv, "i:v:d:o:g:r:hD")) != -1) {
		switch (c) {
		case 'D': want_dhcp = 1; break;
		case 'i': dev = optarg; break;
		case 'v': vid = atoi(optarg); if (vid < 1 || vid > 4094) usage(); break;
		case 'd':
			if (!strcmp(optarg, "out")) dir_out = 1;
			else if (!strcmp(optarg, "in")) dir_out = 0;
			else usage();
			break;
		case 'o': state = optarg; break;
		case 'g': gap_ms = (unsigned)atoi(optarg); break;
		case 'r': pcap = optarg; break;
		default: usage();
		}
	}
	crc_init();
	if (pcap) return run_pcap(pcap);
	if (!dev || !state || strlen(dev) >= IFNAMSIZ) usage();

	prctl(PR_SET_PDEATHSIG, SIGTERM);
	if (getppid() == 1) return 0;
	signal(SIGTERM, on_signal);
	signal(SIGINT, on_signal);
	signal(SIGPIPE, SIG_IGN);
	return run_live(dev, vid, dir_out, state);
}
