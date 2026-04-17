# test_network.sh — has_ipv6, can_reach (network probes, stubbed via _net_get/_run).

load_lib

# ---------- has_ipv6 ----------

detect::reset
detect::_which() { [[ $1 == ip ]]; }
detect::_run() {
  case "$1" in
    timeout) return 0 ;;     # `timeout 3 ip -6 route get ...` succeeds
    *) return 1 ;;
  esac
}
assert::ok "has_ipv6: ip route get succeeds"  detect::has_ipv6

detect::reset
detect::_which() { [[ $1 == ip ]]; }
detect::_run() { return 1; }
assert::fail "has_ipv6: ip route get fails"  detect::has_ipv6

detect::reset
detect::_which() { return 1; }
assert::fail "has_ipv6: no ip binary"  detect::has_ipv6

# Memoization: swap _run; cached result holds.
detect::reset
detect::_which() { [[ $1 == ip ]]; }
detect::_run() { [[ $1 == timeout ]]; }
detect::has_ipv6 >/dev/null
detect::_run() { return 1; }
assert::ok "has_ipv6 memoized"  detect::has_ipv6

# ---------- can_reach ----------

detect::reset
detect::_net_get() { return 0; }
assert::ok "can_reach: 200 OK"  detect::can_reach https://example.test/

detect::reset
detect::_net_get() { return 1; }
assert::fail "can_reach: network error"  detect::can_reach https://example.test/

# Per-URL memoization: different URLs cache separately.
detect::reset
calls=0
detect::_net_get() { calls=$((calls + 1)); return 0; }
detect::can_reach https://a.test/ >/dev/null
detect::can_reach https://a.test/ >/dev/null
assert::eq "$calls" "1"  "can_reach memoized per-URL (a.test one call)"

detect::can_reach https://b.test/ >/dev/null
assert::eq "$calls" "2"  "can_reach different URL hits again"
