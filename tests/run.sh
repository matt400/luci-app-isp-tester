#!/bin/sh
# Lint and tests of the whole package, the same as CI (.github/workflows/test.yml).
#
#   sh tests/run.sh            everything
#   sh tests/run.sh lint       only the linters
#   sh tests/run.sh test       only the tests
#
# Needs: ucode (with the fs module), shellcheck, gcc, python3, node + npm.
# UCODE may carry options, e.g. UCODE="ucode -L /path/to/ucode/build".

set -u
cd "$(dirname "$0")/.." || exit 1
UCODE=${UCODE:-ucode}
WHAT=${1:-all}
FAILED=

step() { echo; echo "==== $1"; }
bad() { FAILED="$FAILED
  - $1"; }

# empty native modules stand in for the ones only a router has (uloop, uci,
# ubus): enough to compile, the tests do not load them
STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT
for m in uloop uci ubus; do : > "$STUB/$m.so"; done

if [ "$WHAT" = all ] || [ "$WHAT" = lint ]; then
	step "ucode: syntax and imports"
	for f in root/usr/share/isp-tester/*.uc root/usr/share/rpcd/ucode/luci.isp_tester; do
		$UCODE -L "$STUB" -c -o /dev/null "$f" || bad "ucode $f"
	done
	for f in root/usr/share/isp-tester/lib/*.uc; do
		$UCODE -L "$STUB" -cmodule -o /dev/null "$f" || bad "ucode $f"
	done

	step "shellcheck"
	shellcheck -S warning \
		root/etc/init.d/isp_tester \
		root/etc/uci-defaults/80_luci-isp-tester \
		root/etc/hotplug.d/ntp/90-isp-tester \
		root/usr/share/isp-tester/push.sh \
		tests/run.sh tests/querier/test_querier_gen.sh || bad shellcheck

	step "eslint"
	npx --no-install eslint htdocs || bad eslint

	step "tsmon: gcc -Werror"
	gcc -std=gnu99 -O2 -Wall -Wextra -Wformat=2 -Wshadow -Werror -fsyntax-only tsmon/src/tsmon.c || bad "tsmon warnings"
fi

if [ "$WHAT" = all ] || [ "$WHAT" = test ]; then
	step "tsmon: tests on synthetic captures (ASan + UBSan)"
	TSMON_BIN=$STUB/isp-tester-tsmon
	if gcc -std=gnu99 -O1 -g -Wall -Wextra -fsanitize=address,undefined -fno-sanitize-recover=undefined \
		-fno-omit-frame-pointer -o "$TSMON_BIN" tsmon/src/tsmon.c; then
		TSMON=$TSMON_BIN python3 tests/tsmon/test_tsmon.py || bad "tsmon tests"
	else
		bad "tsmon build"
	fi

	step "ucode unit tests"
	for f in tests/uc/test_*.uc; do
		TZ=UTC $UCODE -L "$PWD/tests/uc/stub/*.uc" "$f" || bad "$f"
	done

	step "querier-gen"
	UCODE="$UCODE" sh tests/querier/test_querier_gen.sh || bad querier-gen

	step "probable-cause analysis (diagnose.js)"
	node --test tests/js/*.test.js || bad diagnose.js

	step "translations and event types"
	python3 tests/consistency/test_consistency.py || bad consistency
fi

echo
if [ -n "$FAILED" ]; then
	echo "FAILED:$FAILED"
	exit 1
fi
echo "all passed"
