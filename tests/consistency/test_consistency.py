#!/usr/bin/env python3
"""Cross-file checks: translations and event types.

  - every _('...') of the LuCI views is in the .pot template and translated
    in po/pl, with the same %s / %d in the same order (a swapped or missing
    one garbles the text or throws in String.format)
  - every event type the collector emits has a text in the web UI
    (overview.js) and in the notifications / syslog (lib/messages.uc)

    python3 tests/consistency/test_consistency.py
"""
import ast
import glob
import json
import os
import re
import unittest

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), '..', '..'))
UC = os.path.join(ROOT, 'root/usr/share/isp-tester')
OVERVIEW = os.path.join(ROOT, 'htdocs/luci-static/resources/view/isp-tester/overview.js')

# emitted only as information, never shown on their own / notified
NO_MESSAGE = {'cleared', 'monitor_start', 'stream_start'}


def read(p):
	with open(p, encoding='utf-8') as f:
		return f.read()


def js_unquote(lit):
	if lit[0] == '"':
		return ast.literal_eval(lit)
	body = lit[1:-1].replace("\\'", "'").replace('"', '\\"')
	return ast.literal_eval('"' + body + '"')


def ui_strings():
	out = {}
	for f in glob.glob(os.path.join(ROOT, 'htdocs/**/*.js'), recursive=True):
		for m in re.finditer(r"\bN?_\(\s*('(?:[^'\\\n]|\\.)*'|\"(?:[^\"\\\n]|\\.)*\")\s*[,)]", read(f)):
			out.setdefault(js_unquote(m.group(1)), os.path.relpath(f, ROOT))
	for f in glob.glob(os.path.join(ROOT, 'root/usr/share/luci/menu.d/*.json')):
		for node in json.loads(read(f)).values():
			if 'title' in node:
				out.setdefault(node['title'], os.path.relpath(f, ROOT))
	return out


def parse_po(path):
	entries, cur, key = {}, None, None
	for line in read(path).splitlines():
		m = re.match(r'^(msgctxt|msgid|msgid_plural|msgstr(?:\[\d+\])?) "(.*)"$', line)
		if m:
			key = m.group(1)
			if key == 'msgid':
				cur = {}
			cur[key] = ast.literal_eval('"' + m.group(2) + '"')
			if key.startswith('msgstr'):
				entries[cur['msgid']] = cur
		elif line.startswith('"') and cur is not None:
			cur[key] += ast.literal_eval(line)
	entries.pop('', None)
	return entries


def specs(s):
	return re.findall(r'%[-+ 0#]*\d*(?:\.\d+)?[dsfxXJhq]', s.replace('%%', ''))


def call_args(src, name):
	"""top-level argument texts of every name(...) call"""
	for m in re.finditer(r'\b' + name + r'\(', src):
		i, depth, args, cur, quote = m.end(), 0, [], '', None
		while i < len(src):
			c = src[i]
			if quote:
				cur += c
				if c == '\\':
					cur += src[i + 1]
					i += 1
				elif c == quote:
					quote = None
			elif c in '\'"`':
				quote = c
				cur += c
			elif c in '([{':
				depth += 1
				cur += c
			elif c in ')]}':
				if depth == 0:
					args.append(cur.strip())
					break
				depth -= 1
				cur += c
			elif c == ',' and depth == 0:
				args.append(cur.strip())
				cur = ''
			else:
				cur += c
			i += 1
		yield args


def emitted_types():
	"""event types given as literals to emit(lvl, area, src, TYPE, ...)"""
	types = set()
	files = [os.path.join(UC, 'collector.uc')] + glob.glob(os.path.join(UC, 'lib/*.uc'))
	for f in files:
		src = read(f)
		for args in call_args(src, 'emit'):
			if len(args) < 4:
				continue
			a = args[3]
			# 'x', or cond ? 'x' : 'y' (not the literals of the condition)
			lits = re.findall(r"^'([a-z][a-z0-9_]*)'$", a) or re.findall(r"[?:]\s*'([a-z][a-z0-9_]*)'", a)
			types.update(lits)
	return types


def js_cases(src, func_start):
	"""case labels of the switch in the function starting at func_start"""
	i = src.index(func_start)
	j = src.index('default:', i)
	return set(re.findall(r"case '([a-z0-9_]+)':", src[i:j]))


class TestTranslations(unittest.TestCase):

	@classmethod
	def setUpClass(cls):
		cls.ui = ui_strings()
		cls.pot = parse_po(os.path.join(ROOT, 'po/templates/isp-tester.pot'))
		cls.pl = parse_po(os.path.join(ROOT, 'po/pl/isp-tester.po'))

	def test_ui_strings_in_template(self):
		missing = sorted('%s (%s)' % (s, f) for s, f in self.ui.items() if s not in self.pot)
		self.assertEqual(missing, [], 'run the LuCI i18n scan (./build/i18n-scan.pl) and update the .pot')

	def test_template_has_no_stale_strings(self):
		stale = sorted(s for s in self.pot if s not in self.ui)
		self.assertEqual(stale, [])

	def test_polish_complete(self):
		missing = sorted(s for s in self.pot if not self.pl.get(s, {}).get('msgstr'))
		self.assertEqual(missing, [])

	def test_polish_same_placeholders(self):
		bad = ['%r -> %r' % (k, v['msgstr']) for k, v in self.pl.items()
			if v.get('msgstr') and specs(k) != specs(v['msgstr'])]
		self.assertEqual(bad, [])


class TestEventTypes(unittest.TestCase):

	@classmethod
	def setUpClass(cls):
		cls.types = emitted_types()
		msg = read(os.path.join(UC, 'lib/messages.uc'))
		en = msg[msg.index('en: {'):msg.index('pl: {')]
		cls.msg = set(re.findall(r'\b([a-z][a-z0-9_]*):\s*\'', en))

	def test_found_the_emits(self):
		self.assertGreater(len(self.types), 50)

	def test_every_type_has_a_ui_text(self):
		src = read(OVERVIEW)
		ui = js_cases(src, "case 'monitor_start':")
		self.assertEqual(sorted(self.types - ui), [])

	def test_every_type_has_a_message(self):
		self.assertEqual(sorted(self.types - self.msg - NO_MESSAGE), [])


if __name__ == '__main__':
	unittest.main(verbosity=2)
