#!/usr/bin/env python3
"""Tests of isp-tester-tsmon on synthetic captures (tsmon -r FILE.pcap).

Every test builds a small pcap in a temporary directory, runs the helper in
offline mode and checks the JSON it prints. Addresses are documentation /
locally administered ones, nothing from a real network.

    TSMON=/path/to/isp-tester-tsmon python3 tests/tsmon/test_tsmon.py
"""
import json
import os
import struct
import subprocess
import tempfile
import unittest

TSMON = os.environ.get('TSMON', '/tmp/isp-tester-tsmon')

DEC_MAC = bytes.fromhex('020000000002')     # decoder (locally administered)
ISP_MAC = bytes.fromhex('020000000001')     # ISP side
GRP = '239.1.1.1'
ISP_IP = '192.0.2.1'
DEC_IP = '192.0.2.50'


# ---------------------------------------------------------------- frames

def ip4(a):
	return bytes(int(x) for x in a.split('.'))


def mcast_mac(grp):
	g = ip4(grp)
	return bytes([0x01, 0x00, 0x5e, g[1] & 0x7f, g[2], g[3]])


def csum(b):
	if len(b) % 2:
		b += b'\0'
	s = sum(struct.unpack('!%dH' % (len(b) // 2), b))
	while s >> 16:
		s = (s & 0xffff) + (s >> 16)
	return ~s & 0xffff


def ipv4(src, dst, proto, payload, ttl=1, opts=b''):
	ihl = 5 + len(opts) // 4
	h = struct.pack('!BBHHHBBH4s4s', 0x40 | ihl, 0, ihl * 4 + len(payload), 0, 0,
		ttl, proto, 0, ip4(src), ip4(dst)) + opts
	h = h[:10] + struct.pack('!H', csum(h)) + h[12:]
	return h + payload


def eth(dst, src, payload, vid=None, et=0x0800):
	if vid is not None:
		return dst + src + struct.pack('!HHH', 0x8100, vid, et) + payload
	return dst + src + struct.pack('!H', et) + payload


def udp(sport, dport, payload):
	return struct.pack('!HHHH', sport, dport, 8 + len(payload), 0) + payload


def ts_packet(pid, cc, payload=True, tei=False, disc=False):
	afc = (3 if disc else 1) if payload else 2
	b1 = (0x80 if tei else 0) | 0x40 | (pid >> 8)
	hdr = bytes([0x47, b1, pid & 0xff, (afc << 4) | (cc & 15)])
	if disc:
		body = bytes([1, 0x80]) + b'\xff' * 182
	elif not payload:
		body = bytes([183]) + b'\0' + b'\xff' * 182
	else:
		body = b'\xff' * 184
	return hdr + body


def rtp(seq, payload, ts=0):
	return struct.pack('!BBHII', 0x80, 33, seq & 0xffff, ts, 0x1234) + payload


def stream_frame(tsdata, grp=GRP, vid=None):
	return eth(mcast_mac(grp), ISP_MAC, ipv4(ISP_IP, grp, 17, udp(1234, 5000, tsdata)), vid)


def igmp(typ, code, grp, extra=b''):
	m = struct.pack('!BBH4s', typ, code, 0, ip4(grp)) + extra
	return m[:2] + struct.pack('!H', csum(m)) + m[4:]


RA = b'\x94\x04\x00\x00'   # router alert option


def igmp_query_v2(src=ISP_IP, maxresp=100):
	return eth(mcast_mac('224.0.0.1'), ISP_MAC, ipv4(src, '224.0.0.1', 2, igmp(0x11, maxresp, '0.0.0.0'), opts=RA))


def igmp_report_v2(grp=GRP):
	return eth(mcast_mac(grp), DEC_MAC, ipv4(DEC_IP, grp, 2, igmp(0x16, 0, grp), opts=RA))


def igmp_leave_v2(grp=GRP):
	return eth(mcast_mac('224.0.0.2'), DEC_MAC, ipv4(DEC_IP, '224.0.0.2', 2, igmp(0x17, 0, grp), opts=RA))


def write_pcap(path, frames):
	"""frames: list of (time_s, bytes)"""
	with open(path, 'wb') as f:
		f.write(struct.pack('<IHHiIII', 0xa1b2c3d4, 2, 4, 0, 0, 65535, 1))
		for t, fr in frames:
			sec = int(t)
			usec = int(round((t - sec) * 1e6))
			f.write(struct.pack('<IIII', sec, usec, len(fr), len(fr)))
			f.write(fr)


class Stream:
	"""A TS stream on one PID, 7 TS packets per datagram (1316 bytes)."""

	def __init__(self, pid=0x100, use_rtp=False):
		self.pid, self.cc, self.seq, self.use_rtp = pid, 0, 0, use_rtp

	def datagram(self, skip_ts=0, skip_rtp=0, tei_at=None):
		self.cc = (self.cc + skip_ts) & 15
		pkts = b''
		for i in range(7):
			pkts += ts_packet(self.pid, self.cc, tei=(tei_at == i))
			self.cc = (self.cc + 1) & 15
		if self.use_rtp:
			self.seq = (self.seq + skip_rtp) & 0xffff
			pkts = rtp(self.seq, pkts)
			self.seq = (self.seq + 1) & 0xffff
		return pkts


# ---------------------------------------------------------------- runner

def run(frames, *args):
	with tempfile.TemporaryDirectory() as d:
		p = os.path.join(d, 'cap.pcap')
		write_pcap(p, frames)
		out = subprocess.run([TSMON, '-r', p] + list(args), capture_output=True, text=True, timeout=30)
		if out.returncode != 0:
			raise AssertionError('tsmon failed (%d): %s' % (out.returncode, out.stderr))
		return json.loads(out.stdout)


def clean_stream(n=100, dt=0.02, t0=1000.0, **kw):
	s = Stream(**kw)
	return [(t0 + i * dt, stream_frame(s.datagram())) for i in range(n)]


def one_group(j):
	assert len(j['groups']) == 1, j['groups']
	return j['groups'][0]


class TestStream(unittest.TestCase):

	def test_clean_stream_has_no_errors(self):
		g = one_group(run(clean_stream(), '-g', '200'))
		self.assertEqual(g['grp'], GRP)
		self.assertEqual(g['pkts'], 100)
		self.assertEqual(g['ts_pkts'], 700)
		for k in ('cc', 'lost', 'tei', 'sync', 'gaps', 'restarts', 'rtp_lost'):
			self.assertEqual(g[k], 0, k)
		self.assertFalse(g['rtp'])

	def test_cc_jump_counts_lost_packets(self):
		s = Stream()
		fr = []
		for i in range(50):
			fr.append((1000 + i * 0.02, stream_frame(s.datagram(skip_ts=3 if i == 20 else 0))))
		g = one_group(run(fr))
		self.assertEqual(g['cc'], 1)
		self.assertEqual(g['lost'], 3)

	def test_one_duplicate_is_not_an_error(self):
		s = Stream()
		fr = [(1000 + i * 0.02, stream_frame(s.datagram())) for i in range(10)]
		# repeat the last TS packet once: allowed by ISO 13818-1
		last = (s.cc - 1) & 15
		dup = b''.join(ts_packet(s.pid, last) for _ in range(1)) + b''.join(
			ts_packet(s.pid, (s.cc + i) & 15) for i in range(6))
		s.cc = (s.cc + 6) & 15
		fr.append((1000.3, stream_frame(dup)))
		g = one_group(run(fr))
		self.assertEqual(g['cc'], 0)
		self.assertEqual(g['lost'], 0)

	def test_discontinuity_flag_is_not_an_error(self):
		s = Stream()
		fr = [(1000 + i * 0.02, stream_frame(s.datagram())) for i in range(10)]
		jump = ts_packet(s.pid, (s.cc + 7) & 15, disc=True)
		s.cc = (s.cc + 8) & 15
		fr.append((1000.3, stream_frame(jump + b''.join(ts_packet(s.pid, (s.cc + i) & 15) for i in range(6)))))
		g = one_group(run(fr))
		self.assertEqual(g['cc'], 0)

	def test_tei_counted_once(self):
		s = Stream()
		fr = [(1000 + i * 0.02, stream_frame(s.datagram(tei_at=3 if i == 5 else None))) for i in range(20)]
		g = one_group(run(fr))
		self.assertEqual(g['tei'], 1)
		self.assertEqual(g['cc'], 0, 'a TEI packet must not count again as a CC error')

	def test_tei_then_real_loss(self):
		s = Stream()
		fr = []
		for i in range(20):
			fr.append((1000 + i * 0.02, stream_frame(s.datagram(tei_at=6 if i == 5 else None,
				skip_ts=3 if i == 6 else 0))))
		g = one_group(run(fr))
		self.assertEqual(g['tei'], 1)
		self.assertEqual(g['cc'], 1)
		self.assertEqual(g['lost'], 3, 'the TEI packet is not counted again among the lost ones')

	def test_pause_counted_as_gap(self):
		s = Stream()
		fr, t = [], 1000.0
		for i in range(40):
			t += 0.45 if i == 20 else 0.02
			fr.append((t, stream_frame(s.datagram())))
		g = one_group(run(fr, '-g', '200'))
		self.assertEqual(g['gaps'], 1)
		self.assertGreaterEqual(g['gap_max_ms'], 440)
		self.assertLessEqual(g['gap_max_ms'], 460)
		self.assertEqual(g['restarts'], 0)

	def test_long_silence_is_restart_not_loss(self):
		s = Stream()
		fr, t = [], 1000.0
		for i in range(40):
			t += 6.0 if i == 20 else 0.02
			fr.append((t, stream_frame(s.datagram(skip_ts=5 if i == 20 else 0))))
		g = one_group(run(fr, '-g', '200'))
		self.assertEqual(g['restarts'], 1)
		self.assertEqual(g['cc'], 0, 'counters start over after a zap back')
		self.assertEqual(g['gaps'], 0)

	def test_rtp_sequence_gap(self):
		s = Stream(use_rtp=True)
		fr = [(1000 + i * 0.02, stream_frame(s.datagram(skip_rtp=2 if i == 10 else 0))) for i in range(30)]
		g = one_group(run(fr))
		self.assertTrue(g['rtp'])
		self.assertEqual(g['rtp_lost'], 2)

	def test_rtp_reordered_packet_is_not_loss(self):
		s = Stream(use_rtp=True)
		dg = [s.datagram() for _ in range(20)]
		dg[10], dg[11] = dg[11], dg[10]
		fr = [(1000 + i * 0.02, stream_frame(d)) for i, d in enumerate(dg)]
		g = one_group(run(fr))
		self.assertEqual(g['rtp_lost'], 1, 'the skipped one is counted once, the late one not again')

	def test_vlan_tagged_stream(self):
		s = Stream()
		fr = [(1000 + i * 0.02, stream_frame(s.datagram(), vid=236)) for i in range(20)]
		g = one_group(run(fr))
		self.assertEqual(g['pkts'], 20)

	def test_non_ts_datagram_ignored(self):
		fr = clean_stream(20)
		fr.append((1001.0, stream_frame(b'\x00' * 400, grp='239.1.1.2')))
		j = run(fr)
		self.assertEqual(len(j['groups']), 1)
		self.assertGreaterEqual(j['other'], 1)

	def test_two_groups_kept_apart(self):
		a, b = Stream(), Stream()
		fr = []
		for i in range(30):
			fr.append((1000 + i * 0.02, stream_frame(a.datagram(), grp='239.1.1.1')))
			fr.append((1000 + i * 0.02 + 0.01, stream_frame(b.datagram(skip_ts=1 if i == 3 else 0), grp='239.1.1.2')))
		j = run(fr)
		by = {g['grp']: g for g in j['groups']}
		self.assertEqual(by['239.1.1.1']['cc'], 0)
		self.assertEqual(by['239.1.1.2']['cc'], 1)


class TestIgmp(unittest.TestCase):

	def test_general_query_v2(self):
		fr = clean_stream(20)
		fr.append((1000.1, igmp_query_v2()))
		j = run(fr, '-Q')
		q = j['igmp']
		self.assertEqual(q['q'], 1)
		self.assertEqual(q['gen'], 1)
		self.assertEqual(q['ver'], 2)
		self.assertEqual(q['src'], ISP_IP)
		self.assertEqual(q['max_resp'], 100)

	def test_no_queries(self):
		j = run(clean_stream(20), '-Q')
		self.assertEqual(j['igmp']['q'], 0)
		self.assertEqual(j['igmp']['gen_age'], -1.0)

	def test_member_report_and_leave(self):
		fr = clean_stream(50)
		fr.append((1000.1, igmp_report_v2()))
		fr.append((1000.5, igmp_leave_v2()))
		j = run(fr, '-M')
		self.assertEqual(len(j['members']), 1)
		m = j['members'][0]
		self.assertEqual(m['mac'], '02:00:00:00:00:02')
		self.assertEqual(m['ver'], 2)
		self.assertEqual(m['reports'], 1)
		self.assertEqual(m['leaves'], 1)
		self.assertEqual(m['leave']['grp'], GRP)

	def test_ssdp_report_is_not_a_decoder(self):
		fr = clean_stream(20)
		fr.append((1000.1, igmp_report_v2('239.255.255.250')))
		j = run(fr, '-M')
		self.assertEqual(j['members'], [], 'SSDP joins (TV, phone) must not make a decoder')


if __name__ == '__main__':
	unittest.main(verbosity=2)
