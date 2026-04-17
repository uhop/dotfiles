# test_warmup.sh — pkg_avail_bulk + warmup + cache consultation (§3.6.1–2).

load_lib

# ---------- pkg_avail_bulk: no template → fail ----------

detect::reset
detect::mgr_register fake '' '' '' ''
# No bulk template registered.
assert::fail "pkg_avail_bulk: no template → fail" detect::pkg_avail_bulk fake foo

# ---------- pkg_avail_bulk: empty args → success no-op ----------

detect::reset
detect::mgr_register_avail_bulk fake 'fake-bulk {pkgs}'
assert::ok "pkg_avail_bulk: empty args → success" detect::pkg_avail_bulk fake

# ---------- pkg_avail_bulk populates cache + emits uniform output ----------

detect::reset
detect::mgr_register_avail_bulk fake 'fake-bulk {pkgs}'
# Stub returns lines for pkgs that exist.
detect::_run() {
  if [[ $1 == bash && $2 == -c ]]; then
    case "$3" in
      'fake-bulk alpha beta gamma')
        echo alpha
        echo gamma
        return 0 ;;
    esac
  fi
  return 1
}
# Run bulk in the current shell so cache writes propagate; redirect output
# to a tempfile for the shape assertion. ($(...) would subshell + lose
# the cache writes.)
tmp=$(mktemp)
detect::pkg_avail_bulk fake alpha beta gamma >|"$tmp"
out=$(<"$tmp")
command rm -f "$tmp"
expected="alpha	avail
beta	missing
gamma	avail"
assert::eq "$out" "$expected" "pkg_avail_bulk: uniform output (tab-separated, ordered per input)"

# Cache populated.
assert::eq "${__DETECT_PKG_AVAIL_CACHE[fake:alpha]:-}" "1"  "cache: alpha → 1"
assert::eq "${__DETECT_PKG_AVAIL_CACHE[fake:beta]:-}"  "0"  "cache: beta → 0"
assert::eq "${__DETECT_PKG_AVAIL_CACHE[fake:gamma]:-}" "1"  "cache: gamma → 1"

# ---------- pkg_avail reads the cache ----------

# After the bulk call above, pkg_avail must NOT fire the single-pkg probe.
# Verify by swapping the _run stub to return failure for everything; if
# pkg_avail went through the single-pkg path, it'd say "missing" even
# for alpha.
detect::_run() { return 1; }
assert::ok   "pkg_avail (cached): alpha → present"     detect::pkg_avail fake alpha
assert::fail "pkg_avail (cached): beta → missing"      detect::pkg_avail fake beta
assert::ok   "pkg_avail (cached): gamma → present"     detect::pkg_avail fake gamma

# ---------- Cache miss still falls back to single-pkg probe ----------

# delta wasn't in the bulk pass, so pkg_avail has to fire the single-pkg
# avail template. Set that template + a stub that returns true for delta.
detect::reset
detect::mgr_register fake 'fake-single {pkg}' '' '' ''
detect::mgr_register_avail_bulk fake 'fake-bulk {pkgs}'
detect::_run() {
  if [[ $1 == bash && $2 == -c ]]; then
    case "$3" in
      'fake-single delta') return 0 ;;
    esac
  fi
  return 1
}
assert::ok "pkg_avail: cache miss falls back to single-pkg probe" detect::pkg_avail fake delta

# ---------- warmup drives pkg_avail_bulk from __DETECT_CANDIDATES ----------
#
# Verification strategy: recording _run calls doesn't work because
# pkg_avail_bulk's $(...) capture subshells the recorder away. Instead,
# verify the observable outcome — the populated cache — and log the
# packages each bulk template saw via a sentinel file on disk.

detect::reset
detect::mgr_register fake1 'fake1-single {pkg}' '' '' ''
detect::mgr_register fake2 'fake2-single {pkg}' '' '' ''
# Bulk templates echo the last arg (the last package name) if it's one
# of the expected ones — emulates "these packages exist in the index".
# The side-effect (touching a sentinel file) proves the template ran.
sentinel=$(mktemp -d)
detect::mgr_register_avail_bulk fake1 "command touch $sentinel/fake1-ran && printf '%s\n' {pkgs} | command tr ' ' '\n'"
detect::mgr_register_avail_bulk fake2 "command touch $sentinel/fake2-ran && printf '%s\n' {pkgs} | command tr ' ' '\n'"

__DETECT_CANDIDATES[cap_a]='
fake1:alpha
fake2:gamma
'
__DETECT_CANDIDATES[cap_b]='
fake1:beta
fake1:alpha
'  # alpha referenced twice — warmup must dedupe

# Restore the default _run so real commands execute.
unset -f detect::_run 2>/dev/null
detect::_run() { "$@"; }

detect::warmup

[[ -e "$sentinel/fake1-ran" ]] && \
  printf '  ok   warmup: fake1 bulk template fired\n' || \
  { printf '  FAIL warmup: fake1 bulk template did not fire\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)); }

[[ -e "$sentinel/fake2-ran" ]] && \
  printf '  ok   warmup: fake2 bulk template fired\n' || \
  { printf '  FAIL warmup: fake2 bulk template did not fire\n'
    ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1)); }

# After warmup, each referenced package should be cached as avail.
assert::eq "${__DETECT_PKG_AVAIL_CACHE[fake1:alpha]:-}" "1"  "warmup: fake1:alpha cached"
assert::eq "${__DETECT_PKG_AVAIL_CACHE[fake1:beta]:-}"  "1"  "warmup: fake1:beta cached"
assert::eq "${__DETECT_PKG_AVAIL_CACHE[fake2:gamma]:-}" "1"  "warmup: fake2:gamma cached"

command rm -rf "$sentinel"

# ---------- warmup skips managers without a bulk template ----------

detect::reset
detect::mgr_register fake_no_bulk 'fake-single {pkg}' '' '' ''
# No mgr_register_avail_bulk call for fake_no_bulk.
__DETECT_CANDIDATES[cap]='fake_no_bulk:alpha'
bulk_calls=()
detect::_run() {
  if [[ $1 == bash && $2 == -c ]]; then bulk_calls+=("$3"); return 0; fi
  return 1
}
detect::warmup
assert::eq "${#bulk_calls[@]}" "0" "warmup: skips managers without bulk template"

# ---------- reset() clears cache ----------

detect::reset
__DETECT_PKG_AVAIL_CACHE[fake:foo]=1
detect::reset
if [[ ${#__DETECT_PKG_AVAIL_CACHE[@]} -eq 0 ]]; then
  printf '  ok   reset: __DETECT_PKG_AVAIL_CACHE cleared\n'
else
  printf '  FAIL reset: cache has %d entries after reset\n' "${#__DETECT_PKG_AVAIL_CACHE[@]}"
  ASSERT_FAIL_LOCAL=$((ASSERT_FAIL_LOCAL + 1))
fi
