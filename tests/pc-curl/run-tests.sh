#!/usr/bin/env bash
# run-tests.sh — pc-curl's waits: a 429's, and an outage's (vault-storage 7as-2, D751, D755).
#
# A local server answers each path from a script of answers, the last one repeated, and logs every
# request; "503:tenant_unavailable" is a 503 whose JSON body names that code, "503:html" the
# balancer's own page. Nothing here reaches a vault.
#
# Exit 0 on all-green, 1 on any failure.

set -uo pipefail

source_dir="$(readlink -f "$(dirname "$(readlink -f "$0")")/../..")"
pc_curl="$source_dir/private_dot_local/bin/executable_pc-curl"
command -v node >/dev/null || {
  echo "node required" >&2
  exit 1
}
work=$(command mktemp -d)
trap 'kill "$server" 2>/dev/null; command rm -rf "$work"' EXIT

pass=0 fail=0
ok() { ((++pass)); }
bad() {
  ((++fail))
  printf 'FAIL  %s\n' "$1"
}

command cat >"$work/server.mjs" <<'EOF'
import http from 'node:http';
import {appendFileSync} from 'node:fs';
const scripts = JSON.parse(process.argv[3]);
const seen = {};
const server = http.createServer((req, res) => {
  req.resume();
  req.on('end', () => {
    const path = new URL(req.url, 'http://x').pathname;
    const script = scripts[path] ?? ['200'];
    const n = (seen[path] = (seen[path] ?? 0) + 1);
    const [status, kind, after] = script[Math.min(n, script.length) - 1].split(':');
    appendFileSync(process.argv[2], `${req.method} ${path}\n`);
    const headers = after ? {'Retry-After': after} : {};
    if (kind === 'html') {
      res.writeHead(Number(status), {...headers, 'Content-Type': 'text/html'});
      res.end('<html><body>503 Service Temporarily Unavailable</body></html>');
    } else {
      res.writeHead(Number(status), {...headers, 'Content-Type': 'application/json'});
      res.end(JSON.stringify(kind ? {code: kind} : {ok: true}));
    }
  });
});
server.listen(0, '127.0.0.1', () => process.stdout.write(`${server.address().port}\n`));
EOF
scripts='{
  "/w-unreached": ["503:tenant_unavailable", "200"],
  "/w-maybe": ["503:database_unavailable", "200"],
  "/w-balancer": ["503:html", "200"],
  "/w-gateway": ["502", "200"],
  "/w-implied": ["502", "200"],
  "/w-hidden": ["503:tenant_unavailable", "200"],
  "/r-maybe": ["503:database_unavailable", "200"],
  "/r-gateway": ["502", "200"],
  "/rate": ["429:too_many_requests:1", "200"],
  "/c-joins": ["503:tenant_unavailable", "200"]
}'
node "$work/server.mjs" "$work/requests" "$scripts" >"$work/port" 2>/dev/null &
server=$!
for _ in $(seq 50); do
  [[ -s $work/port ]] && break
  sleep 0.1
done

export PROGRAM_CLERK_URL="http://127.0.0.1:$(cat "$work/port")" PROGRAM_CLERK_KEY=test-key
export XDG_RUNTIME_DIR="$work/run"
command mkdir -p "$XDG_RUNTIME_DIR"
marker="$XDG_RUNTIME_DIR/pc-curl-outage-$UID"
count() { grep -c " $1\$" "$work/requests" 2>/dev/null || echo 0; }
vc() { bash "$pc_curl" "$@"; }

out=$(vc /w-unreached -s -X POST -d '{}')
rc=$?
[[ $rc -eq 0 && $out == '{"ok":true}' && $(count /w-unreached) -eq 2 ]] && ok ||
  bad "a write refused with a code that applied nothing goes again (rc=$rc out=$out sent=$(count /w-unreached))"
out=$(vc /w-maybe -s -X POST -d '{}')
[[ $(count /w-maybe) -eq 1 && $out == *database_unavailable* ]] && ok ||
  bad "a write that may have applied is answered at once (sent=$(count /w-maybe))"
vc /w-balancer -s -X POST -d '{}' >/dev/null
[[ $(count /w-balancer) -eq 2 ]] && ok || bad "the balancer's own 503 repeats a write (sent=$(count /w-balancer))"
vc /w-gateway -s -X POST -d '{}' >/dev/null
[[ $(count /w-gateway) -eq 1 ]] && ok || bad "a write's 502 is answered at once (sent=$(count /w-gateway))"
vc /w-implied -s -d '{}' >/dev/null
[[ $(count /w-implied) -eq 1 ]] && ok || bad "a body with no -X is a write too (sent=$(count /w-implied))"
vc /w-hidden -s -o /dev/null -X POST -d '{}'
[[ $(count /w-hidden) -eq 1 ]] && ok ||
  bad "a write whose JSON body the caller hides is not sent again (sent=$(count /w-hidden))"
out=$(vc /r-maybe -sf)
rc=$?
[[ $rc -eq 0 && $(count /r-maybe) -eq 2 ]] && ok || bad "a read goes again after any 503, -f and all (rc=$rc sent=$(count /r-maybe))"
vc /r-gateway -s >/dev/null
[[ $(count /r-gateway) -eq 2 ]] && ok || bad "a read goes again after a 502 (sent=$(count /r-gateway))"
[[ ! -e $marker ]] && ok || bad "no outage remembered after an answer"

start=$SECONDS
vc /rate -s >/dev/null
[[ $(count /rate) -eq 2 && $((SECONDS - start)) -ge 1 ]] && ok || bad "a 429 still waits its Retry-After (sent=$(count /rate))"

PC_CURL_OUTAGE_S=2 PROGRAM_CLERK_URL=http://127.0.0.1:9 vc /x -s >/dev/null &
waiting=$!
sleep 0.5
[[ -e $marker ]] && ok || bad "the outage is marked at its first failure, while the first call still waits"
read -r since <"$marker"
[[ $since =~ ^[0-9]+$ ]] && ok || bad "the mark holds the first failure's time (since=$since)"
out=$(vc /c-joins -s -X POST -d '{}')
[[ $out == '{"ok":true}' && $(count /c-joins) -eq 2 ]] && ok ||
  bad "a call that meets the marked outage waits it out too (out=$out sent=$(count /c-joins))"
wait "$waiting"
rm -f -- "$marker"

# The deadline is in whole seconds, so a window of N runs between N - 1 and N.
start=$(date +%s%N)
PC_CURL_OUTAGE_S=2 PROGRAM_CLERK_URL=http://127.0.0.1:9 vc /x -s -X POST -d '{}' >/dev/null
rc=$?
took=$((($(date +%s%N) - start) / 1000000))
[[ $rc -eq 7 && -e $marker && $took -ge 1000 ]] && ok ||
  bad "a refused write waits out the window, then fails and is remembered (rc=$rc took=${took}ms)"
printf '%s\n' "$(($(date +%s) - 90))" >"$marker"
start=$(date +%s%N)
PROGRAM_CLERK_URL=http://127.0.0.1:9 vc /x -s >/dev/null
took=$((($(date +%s%N) - start) / 1000000))
[[ $took -lt 500 ]] && ok || bad "past the outage's deadline, a call tries once (took=${took}ms)"
vc /r-gateway -s >/dev/null
[[ ! -e $marker ]] && ok || bad "an answer ends the outage"

printf 'pass=%d fail=%d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
