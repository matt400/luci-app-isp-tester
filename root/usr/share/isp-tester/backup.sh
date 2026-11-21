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
# manifest of this package, and a settings file that is a UCI file.
# Output: one JSON object.

RUNDIR=${ISP_TESTER_RUNDIR:-/tmp/isp-tester}
CONF=${ISP_TESTER_UCI:-/etc/config/isp_tester}
INIT=${ISP_TESTER_INIT:-/etc/init.d/isp_tester}
OUT=${ISP_TESTER_BACKUP:-/tmp/isp-tester-backup.tar.gz}
WORK=/tmp/isp-tester-bk.$$
DATA_FILES="events.json history.json channels.json wanpeak.json samples.csv samples.prev.csv"
NAMES='^(manifest\.json|config/|config/isp_tester|data/|data/(events\.json|history\.json|channels\.json|wanpeak\.json|samples\.csv|samples\.prev\.csv)|data/archive/|data/archive/(ev|h)-[0-9]{8}\.jsonl)$'

trap 'rm -rf "$WORK"' EXIT

fail() {
	printf '{"result":false,"error":"%s"}\n' "$1"
	exit 0
}

host() {
	cat /proc/sys/kernel/hostname 2>/dev/null | tr -cd 'A-Za-z0-9._-'
}

create() {
	mkdir -p "$WORK/config" || fail mkdir
	cp "$CONF" "$WORK/config/isp_tester" 2>/dev/null || fail no_config
	local files=0
	if [ "$1" = 1 ]; then
		mkdir -p "$WORK/data/archive"
		for f in $DATA_FILES; do
			[ -f "$RUNDIR/$f" ] && cp "$RUNDIR/$f" "$WORK/data/$f" && files=$((files + 1))
		done
		for f in "$RUNDIR"/archive/ev-*.jsonl "$RUNDIR"/archive/h-*.jsonl; do
			[ -f "$f" ] || continue
			case "${f##*/}" in
				ev-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].jsonl|h-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9].jsonl)
					cp "$f" "$WORK/data/archive/" && files=$((files + 1)) ;;
			esac
		done
	fi
	printf '{"app":"luci-app-isp-tester","version":1,"host":"%s","created":%s,"data":%s,"files":%d}\n' \
		"$(host)" "$(date +%s)" "$([ "$1" = 1 ] && echo true || echo false)" "$files" > "$WORK/manifest.json"
	rm -f "$OUT"
	( cd "$WORK" && tar -czf "$OUT" manifest.json config $([ "$1" = 1 ] && echo data) ) 2>/dev/null || fail tar
	chmod 600 "$OUT"
	printf '{"result":true,"path":"%s","size":%s,"name":"isp-tester-%s-%s.tar.gz","files":%d}\n' \
		"$OUT" "$(wc -c < "$OUT")" "$(host)" "$(date +%Y%m%d-%H%M)" "$files"
}

# list, check and unpack FILE into $WORK
unpack() {
	[ -f "$1" ] || fail no_file
	[ "$(wc -c < "$1")" -le $((64 * 1024 * 1024)) ] || fail too_big
	local list
	list=$(tar -tzvf "$1" 2>/dev/null) || fail not_targz
	[ -n "$list" ] || fail empty
	# the type is the first character of the mode: only "-" and "d"
	echo "$list" | awk '{ t = substr($1, 1, 1); if (t != "-" && t != "d") bad = 1 } END { exit bad }' || fail bad_entry
	local n
	for n in $(tar -tzf "$1" 2>/dev/null | sed 's,^\./,,'); do
		echo "$n" | grep -Eq "$NAMES" || fail bad_name
	done
	mkdir -p "$WORK" && tar -xzf "$1" -C "$WORK" 2>/dev/null || fail extract
	grep -q '"app":"luci-app-isp-tester"' "$WORK/manifest.json" 2>/dev/null || fail no_manifest
	if [ -f "$WORK/config/isp_tester" ]; then
		# a UCI file: config / option / list lines, comments, blank lines
		grep -Ev "^[[:space:]]*(config|option|list)[[:space:]]|^[[:space:]]*(#.*)?$" "$WORK/config/isp_tester" | grep -q . && fail bad_config
		grep -q "^config general" "$WORK/config/isp_tester" || fail bad_config
	fi
}

info() {
	local m data=0 arch=0 size
	m=$(cat "$WORK/manifest.json")
	[ -d "$WORK/data" ] && data=$(find "$WORK/data" -type f | wc -l)
	[ -d "$WORK/data/archive" ] && arch=$(find "$WORK/data/archive" -type f | wc -l)
	size=$(du -sk "$WORK" 2>/dev/null | cut -f1)
	printf '{"result":true,"manifest":%s,"config":%s,"data_files":%d,"archive_files":%d,"kb":%d,"this_host":"%s"}\n' \
		"$m" "$([ -f "$WORK/config/isp_tester" ] && echo true || echo false)" "$data" "$arch" "${size:-0}" "$(host)"
}

restore() {
	unpack "$1"
	local conf=0 data=0 running=0
	[ "$2" = 1 ] && [ -f "$WORK/config/isp_tester" ] && conf=1
	[ "$3" = 1 ] && [ -d "$WORK/data" ] && data=1
	[ "$conf" = 1 ] || [ "$data" = 1 ] || fail nothing
	# the collector must not write while the files are replaced
	"$INIT" running >/dev/null 2>&1 && running=1
	"$INIT" stop >/dev/null 2>&1
	if [ "$conf" = 1 ]; then
		cp "$CONF" "$CONF.before-restore" 2>/dev/null
		cat "$WORK/config/isp_tester" > "$CONF" || fail write_config
	fi
	if [ "$data" = 1 ]; then
		mkdir -p "$RUNDIR/archive"
		for f in $DATA_FILES; do
			[ -f "$WORK/data/$f" ] && cat "$WORK/data/$f" > "$RUNDIR/$f.restore" && mv "$RUNDIR/$f.restore" "$RUNDIR/$f"
		done
		for f in "$WORK"/data/archive/*.jsonl; do
			[ -f "$f" ] && cat "$f" > "$RUNDIR/archive/${f##*/}"
		done
	fi
	rm -f "$1"
	# started again when it was running, or with restored settings that turn it on
	if [ "$running" = 1 ] || { [ "$conf" = 1 ] && "$INIT" enabled; }; then
		"$INIT" start >/dev/null 2>&1
	fi
	printf '{"result":true,"config":%s,"data":%s}\n' \
		"$([ "$conf" = 1 ] && echo true || echo false)" "$([ "$data" = 1 ] && echo true || echo false)"
}

case "$1" in
	create)  create "$2" ;;
	check)   unpack "$2"; info ;;
	restore) restore "$2" "$3" "$4" ;;
	*)       fail usage ;;
esac
