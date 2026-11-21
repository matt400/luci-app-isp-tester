#!/bin/sh
# luci-app-isp-tester: one .tar.gz with the settings and the data (history,
# timeline, archive), e.g. to move the monitoring to another router.
#
#   backup.sh create [data]           -> /tmp/isp-tester-backup.tar.gz
#   backup.sh check  FILE             -> what the archive holds (JSON)
#   backup.sh restore FILE CONF DATA  -> CONF/DATA = 1 to restore that part
#
# An archive to restore is checked first: only regular files and folders
# with the names this script writes (no links, no paths outside), a
# manifest of this package, and a settings file that is a UCI file. It must
# also fit in RAM once unpacked: a small .tar.gz can hold gigabytes.
# The settings hold keys and tokens: every file written here is 0600.
# Output: one JSON object.

umask 077

RUNDIR=${ISP_TESTER_RUNDIR:-/tmp/isp-tester}
CONF=${ISP_TESTER_UCI:-/etc/config/isp_tester}
INIT=${ISP_TESTER_INIT:-/etc/init.d/isp_tester}
OUT=${ISP_TESTER_BACKUP:-/tmp/isp-tester-backup.tar.gz}
WORK=/tmp/isp-tester-bk.$$
DATA_FILES="events.json history.json channels.json wanpeak.json samples.csv samples.prev.csv"
NAMES='^(manifest\.json|config/|config/isp_tester|data/|data/(events\.json|history\.json|channels\.json|wanpeak\.json|samples\.csv|samples\.prev\.csv)|data/archive/|data/archive/(ev|h)-[0-9]{8}\.jsonl)$'
MAX_UNPACKED_KB=262144
UPLOAD=

trap 'rm -rf "$WORK"' EXIT

# a rejected upload is not kept: it would sit in RAM until the next reboot
fail() {
	[ -n "$UPLOAD" ] && rm -f "$UPLOAD"
	printf '{"result":false,"error":"%s"}\n' "$1"
	exit 0
}

host() {
	cat /proc/sys/kernel/hostname 2>/dev/null | tr -cd 'A-Za-z0-9._-'
}

create() {
	local files=0 what="manifest.json config"
	mkdir -p "$WORK/config" || fail mkdir
	cp "$CONF" "$WORK/config/isp_tester" 2>/dev/null || fail no_config
	if [ "$1" = 1 ]; then
		what="$what data"
		mkdir -p "$WORK/data/archive"
		for f in $DATA_FILES; do
			[ -f "$RUNDIR/$f" ] && cp "$RUNDIR/$f" "$WORK/data/$f" 2>/dev/null && files=$((files + 1))
		done
		for f in "$RUNDIR"/archive/ev-*.jsonl "$RUNDIR"/archive/h-*.jsonl; do
			[ -f "$f" ] || continue
			case "${f##*/}" in
				ev-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].jsonl|h-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].jsonl)
					cp "$f" "$WORK/data/archive/" 2>/dev/null && files=$((files + 1)) ;;
			esac
		done
	fi
	printf '{"app":"luci-app-isp-tester","version":1,"host":"%s","created":%s,"data":%s,"files":%d}\n' \
		"$(host)" "$(date +%s)" "$([ "$1" = 1 ] && echo true || echo false)" "$files" > "$WORK/manifest.json"
	rm -f "$OUT"
	# $what: a few fixed names, split on purpose
	# shellcheck disable=SC2086
	( cd "$WORK" && tar -czf "$OUT" $what ) 2>/dev/null || { rm -f "$OUT"; fail tar; }
	chmod 600 "$OUT"
	printf '{"result":true,"path":"%s","size":%s,"name":"isp-tester-%s-%s.tar.gz","files":%d}\n' \
		"$OUT" "$(wc -c < "$OUT")" "$(host)" "$(date +%Y%m%d-%H%M)" "$files"
}

# list, check and unpack FILE into $WORK
unpack() {
	[ -f "$1" ] || fail no_file
	UPLOAD=$1
	[ "$(wc -c < "$1")" -le $((64 * 1024 * 1024)) ] || fail too_big
	local list free
	list=$(tar -tzvf "$1" 2>/dev/null) || fail not_targz
	[ -n "$list" ] || fail empty
	# the type is the first character of the mode: only "-" and "d"
	echo "$list" | awk '{ t = substr($1, 1, 1); if (t != "-" && t != "d") bad = 1 } END { exit bad }' || fail bad_entry
	# the size once unpacked (3rd column of the listing) against a fixed limit
	# and the free RAM in /tmp, keeping a few MB for the system
	free=$(df -k /tmp 2>/dev/null | awk 'NR == 2 && $4 ~ /^[0-9]+$/ { print $4 }')
	echo "$list" | awk -v max_kb="$MAX_UNPACKED_KB" -v free_kb="${free:-0}" '
		substr($1, 1, 1) == "-" { sum += $3 }
		END {
			lim = max_kb * 1024
			if (free_kb > 0 && free_kb * 1024 - 8388608 < lim) lim = free_kb * 1024 - 8388608
			exit (sum > lim)
		}' || fail too_large
	# one name per line (a name with a space or a glob character is not split)
	tar -tzf "$1" 2>/dev/null | sed 's,^\./,,' | grep -v '^$' | grep -Evq "$NAMES" && fail bad_name
	mkdir -p "$WORK" && tar -xzf "$1" -C "$WORK" 2>/dev/null || fail extract
	grep -q '"app":"luci-app-isp-tester"' "$WORK/manifest.json" 2>/dev/null || fail no_manifest
	if [ -f "$WORK/config/isp_tester" ]; then
		# a UCI file: config / option / list lines, comments, blank lines
		grep -Ev "^[[:space:]]*(config|option|list)[[:space:]]|^[[:space:]]*(#.*)?$" "$WORK/config/isp_tester" | grep -q . && fail bad_config
		grep -q "^config general" "$WORK/config/isp_tester" || fail bad_config
	fi
}

info() {
	local mhost mcreated data=0 arch=0 size
	# only the two fields the page shows, rebuilt: the manifest is the uploaded
	# file's, and what is not valid JSON would break the whole answer
	mhost=$(sed -n 's/.*"host":"\([A-Za-z0-9._-]*\)".*/\1/p' "$WORK/manifest.json" | head -n 1)
	mcreated=$(sed -n 's/.*"created":\([0-9][0-9]*\).*/\1/p' "$WORK/manifest.json" | head -n 1)
	[ -d "$WORK/data" ] && data=$(find "$WORK/data" -type f | wc -l)
	[ -d "$WORK/data/archive" ] && arch=$(find "$WORK/data/archive" -type f | wc -l)
	size=$(du -sk "$WORK" 2>/dev/null | cut -f1)
	printf '{"result":true,"manifest":{"app":"luci-app-isp-tester","host":"%s","created":%s},"config":%s,"data_files":%d,"archive_files":%d,"kb":%d,"this_host":"%s"}\n' \
		"$mhost" "${mcreated:-0}" "$([ -f "$WORK/config/isp_tester" ] && echo true || echo false)" "$data" "$arch" "${size:-0}" "$(host)"
}

# copy $1 to $2 so that $2 is either the old file or the whole new one
put() {
	# silent: the answer must stay one JSON object (rpcd adds stderr to it)
	{ cat "$1" > "$2.restore" && mv "$2.restore" "$2"; } 2>/dev/null && return 0
	rm -f "$2.restore" 2>/dev/null
	return 1
}

restore() {
	unpack "$1"
	local conf=0 data=0 running=0 err=
	[ "$2" = 1 ] && [ -f "$WORK/config/isp_tester" ] && conf=1
	[ "$3" = 1 ] && [ -d "$WORK/data" ] && data=1
	[ "$conf" = 1 ] || [ "$data" = 1 ] || fail nothing
	# the collector must not write while the files are replaced
	"$INIT" running >/dev/null 2>&1 && running=1
	"$INIT" stop >/dev/null 2>&1
	if [ "$conf" = 1 ]; then
		cp "$CONF" "$CONF.before-restore" 2>/dev/null && chmod 600 "$CONF.before-restore"
		put "$WORK/config/isp_tester" "$CONF" || err=write_config
	fi
	if [ "$data" = 1 ] && [ -z "$err" ]; then
		if mkdir -p "$RUNDIR/archive" 2>/dev/null; then
			for f in $DATA_FILES; do
				[ -f "$WORK/data/$f" ] || continue
				put "$WORK/data/$f" "$RUNDIR/$f" || err=write_data
			done
			for f in "$WORK"/data/archive/*.jsonl; do
				[ -f "$f" ] || continue
				put "$f" "$RUNDIR/archive/${f##*/}" || err=write_data
			done
		else
			err=write_data
		fi
	fi
	rm -f "$1"
	# started again when it was running, or with restored settings that turn
	# it on; also after an error, so the monitoring is not left stopped
	if [ "$running" = 1 ] || { [ "$conf" = 1 ] && [ -z "$err" ] && "$INIT" enabled; }; then
		"$INIT" start >/dev/null 2>&1
	fi
	[ -z "$err" ] || fail "$err"
	printf '{"result":true,"config":%s,"data":%s}\n' \
		"$([ "$conf" = 1 ] && echo true || echo false)" "$([ "$data" = 1 ] && echo true || echo false)"
}

case "$1" in
	create)  create "$2" ;;
	check)   unpack "$2"; info ;;
	restore) restore "$2" "$3" "$4" ;;
	*)       fail usage ;;
esac
