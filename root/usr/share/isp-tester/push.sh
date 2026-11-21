#!/bin/sh
# luci-app-isp-tester: send the data to another device over SSH, with
# dropbear's own client (dbclient) - no extra package needed.
#
#   push.sh send     -> one .tar.gz (timeline, history, CSV) streamed to
#                       HOST:DIR/isp-tester-<router>-<date>-<time>.tar.gz
#   push.sh test     -> only checks that the login works (key, host, user);
#                       the result also goes to $VARDIR/push_test.json, so the
#                       web UI can start it in the background and wait for it
#   push.sh pubkey   -> public key to add to authorized_keys on the other
#                       device (the key pair is made when missing)
#
# Settings: uci isp_tester.push.{host,port,user,dir,key}. The other device
# keeps the files, so the history there is as long as you keep them.
# Output: one JSON object. 'send' also writes it to $VARDIR/push.json,
# which the collector reads to decide when to send again.

RUNDIR=${ISP_TESTER_RUNDIR:-/tmp/isp-tester}
VARDIR=${ISP_TESTER_VARDIR:-/var/run/isp-tester}
DBCLIENT=${ISP_TESTER_DBCLIENT:-dbclient}
DBKEY=${ISP_TESTER_DBKEY:-dropbearkey}
STATE=$VARDIR/push.json
TSTATE=$VARDIR/push_test.json
LOCK=$VARDIR/push.lock
DATA_FILES="events.json history.json channels.json wanpeak.json samples.csv samples.prev.csv"
DEF_KEY=/etc/dropbear/isp_tester_push_key

fail() {
	# 'send' also notes the failure in push.json: the collector then waits
	# 30 min before the next try (without it, a send that cannot start -
	# no address set, no dbclient - was started again every interval), and
	# the settings page shows why
	[ -n "$SENDING" ] && state "{\"ok\":false,\"ts\":$(date +%s),\"err\":\"$1\"}"
	[ -n "$TESTING" ] && tstate "{\"result\":false,\"ts\":$TS0,\"error\":\"$1\"}"
	printf '{"result":false,"error":"%s"}\n' "$1"
	exit 0
}

conf() {
	uci -q get "isp_tester.push.$1"
}

host() {
	tr -cd 'A-Za-z0-9._-' < /proc/sys/kernel/hostname 2>/dev/null
}

# settings, each checked: they end up in a command line
load() {
	HOST=$(conf host); PORT=$(conf port); USER=$(conf user)
	DIR=$(conf dir); KEY=$(conf key)
	: "${PORT:=22}" "${DIR:=isp-tester}" "${KEY:=$DEF_KEY}"
	[ -n "$HOST" ] && [ -n "$USER" ] || fail no_target
	printf '%s' "$HOST" | grep -Eq '^[A-Za-z0-9._:-]{1,253}$' || fail bad_host
	printf '%s' "$USER" | grep -Eq '^[A-Za-z0-9._-]{1,32}$' || fail bad_user
	printf '%s' "$PORT" | grep -Eq '^[0-9]{1,5}$' && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail bad_port
	# a path on the other device: no spaces, no "..", nothing the shell would act on
	printf '%s' "$DIR" | grep -Eq '^[A-Za-z0-9._/~-]{1,120}$' || fail bad_dir
	case "$DIR" in *..*) fail bad_dir ;; esac
	# a leading "-" would be taken as an option (by dbclient for the host and
	# the user, by mkdir/cat/mv on the other device for the folder)
	case "$HOST" in -*) fail bad_host ;; esac
	case "$USER" in -*) fail bad_user ;; esac
	case "$DIR" in -*) fail bad_dir ;; esac
	printf '%s' "$KEY" | grep -Eq '^/[A-Za-z0-9._/-]{1,120}$' || fail bad_key
	command -v "$DBCLIENT" >/dev/null 2>&1 || fail no_dbclient
}

# create the key pair when missing; prints nothing
ensure_key() {
	[ -s "$1" ] && return 0
	command -v "$DBKEY" >/dev/null 2>&1 || fail no_dropbearkey
	mkdir -p "${1%/*}" && "$DBKEY" -t ed25519 -f "$1" >/dev/null 2>&1 && chmod 600 "$1" || fail keygen
}

pubkey() {
	local key=${1:-$(conf key)}
	: "${key:=$DEF_KEY}"
	printf '%s' "$key" | grep -Eq '^/[A-Za-z0-9._/-]{1,120}$' || fail bad_key
	ensure_key "$key"
	local pub
	pub=$("$DBKEY" -y -f "$key" 2>/dev/null | grep '^ssh-')
	[ -n "$pub" ] || fail no_pubkey
	printf '{"result":true,"pubkey":"%s","path":"%s"}\n' "$pub" "$key"
}

# dbclient: -y = trust a new host key on the first login (a changed one is
# refused), keepalive and idle limits so a dead link does not hang the script.
# stdin of the remote command is a file or /dev/null, never a terminal: with
# no terminal dbclient cannot ask for a password and gives up at once when the
# key is not accepted, instead of waiting for an answer nobody can give.
ssh_run() {
	# $1 = remote command, $2 = file for its stdin (default /dev/null)
	local tmo=${SSH_TMO:-300} in=${2:-/dev/null} pid rc
	# DROPBEAR_PASSWORD would be sent as the password: never use one
	unset DROPBEAR_PASSWORD
	if command -v timeout >/dev/null 2>&1; then
		timeout "$tmo" "$DBCLIENT" -y -T -K 15 -I 60 -i "$KEY" -p "$PORT" -l "$USER" "$HOST" "$1" < "$in" 2>&1
		return $?
	fi
	# no 'timeout' in busybox: a watchdog kills dbclient after $tmo s
	"$DBCLIENT" -y -T -K 15 -I 60 -i "$KEY" -p "$PORT" -l "$USER" "$HOST" "$1" < "$in" > "$VARDIR/ssh.$$.out" 2>&1 &
	pid=$!
	# (the watchdog takes its sleep with it when it is stopped: killing only
	# the subshell left the sleep running for up to 5 minutes)
	( trap 'kill $s 2>/dev/null; exit 0' TERM; sleep "$tmo" & s=$!; wait $s; kill "$pid" 2>/dev/null ) &
	local wd=$!
	wait "$pid"; rc=$?
	kill "$wd" 2>/dev/null
	cat "$VARDIR/ssh.$$.out" 2>/dev/null; rm -f "$VARDIR/ssh.$$.out"
	return $rc
}

# last lines of dbclient's output, only safe characters (it goes into JSON)
clean() {
	# no < > & : the web UI shows it, and the text comes from the other device
	printf '%s' "$1" | tail -n "${2:-3}" | tr '\n' ' ' | tr -cd 'A-Za-z0-9 ._:,/@()=-' | cut -c1-200
}

state() {
	mkdir -p "$VARDIR"
	printf '%s\n' "$1" > "$STATE.$$" && mv "$STATE.$$" "$STATE"
}

tstate() {
	mkdir -p "$VARDIR"
	printf '%s\n' "$1" > "$TSTATE.$$" && mv "$TSTATE.$$" "$TSTATE"
}

test_login() {
	TESTING=1
	TS0=$(date +%s)
	tstate "{\"state\":\"running\",\"ts\":$TS0}"
	load
	ensure_key "$KEY"
	local out rc res
	# the web UI waits for the result: give up after 25 s
	SSH_TMO=25
	out=$(ssh_run "echo isp-tester-ok")
	rc=$?
	case "$out" in
		*isp-tester-ok*) res="{\"result\":true,\"ts\":$TS0}" ;;
		*)
			# 124/143 = stopped by the time limit: no answer from the device
			case $rc in 124|143) res="{\"result\":false,\"ts\":$TS0,\"error\":\"timeout\"}" ;;
			*) res="{\"result\":false,\"ts\":$TS0,\"error\":\"login\",\"out\":\"$(clean "$out")\"}" ;;
			esac
			logger -t isp-tester "push: login test to $USER@$HOST:$PORT failed: $(clean "$out")"
			;;
	esac
	tstate "$res"
	printf '%s\n' "$res"
}

# take the lock: created only when it does not exist (noclobber), so two
# sends started at the same moment (the collector's timer and "Send now")
# cannot both get it; one left by a send that died is taken over
take_lock() {
	( set -C; echo $$ > "$LOCK" ) 2>/dev/null && return 0
	local pid
	pid=$(cat "$LOCK" 2>/dev/null)
	case "$pid" in ''|*[!0-9]*) ;; *) [ -d "/proc/$pid" ] && return 1 ;; esac
	rm -f "$LOCK"
	( set -C; echo $$ > "$LOCK" ) 2>/dev/null
}

send() {
	mkdir -p "$VARDIR"
	# one at a time; checked first: a busy try must not overwrite the state
	# of the running one (SENDING is not set yet)
	take_lock || fail busy
	# global, not local: the EXIT trap runs after this function has returned
	tmp=$VARDIR/push.$$.tar.gz
	trap 'rm -f "$LOCK" "$tmp"' EXIT
	SENDING=1
	load
	ensure_key "$KEY"
	local ts=$(date +%s) name size files= f out rc
	state "{\"ok\":false,\"state\":\"running\",\"ts\":$ts}"
	for f in $DATA_FILES; do [ -f "$RUNDIR/$f" ] && files="$files $f"; done
	[ -n "$files" ] || fail no_data
	name="isp-tester-$(host)-$(date +%Y%m%d-%H%M).tar.gz"
	# the other device writes to a temporary name and renames at the end, so
	# a cut transfer never leaves a broken .tar.gz behind
	( cd "$RUNDIR" && tar -czf "$tmp" $files ) 2>/dev/null || fail tar
	size=$(wc -c < "$tmp")
	# only the exit status counts: dbclient also prints notes (new host key)
	out=$(ssh_run "mkdir -p $DIR && cat > $DIR/$name.part && mv $DIR/$name.part $DIR/$name" "$tmp")
	rc=$?
	if [ $rc -ne 0 ]; then
		out=$(clean "$out" 2)
		logger -t isp-tester "push to $USER@$HOST failed: $out"
		state "{\"ok\":false,\"ts\":$ts,\"err\":\"send\",\"out\":\"$out\"}"
		printf '{"result":false,"error":"send","out":"%s"}\n' "$out"
		exit 0
	fi
	state "{\"ok\":true,\"ts\":$ts,\"done\":$(date +%s),\"name\":\"$name\",\"size\":${size:-0},\"host\":\"$HOST\"}"
	printf '{"result":true,"name":"%s","size":%s}\n' "$name" "${size:-0}"
}

case "$1" in
	send)   send ;;
	test)   test_login ;;
	pubkey) pubkey ;;
	*)      fail usage ;;
esac
