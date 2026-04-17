# test_version.sh — version normalization and comparison.

load_lib

# Each row: raw  expected_normalized  label
norm_cases=(
  "2.0.11                 2.0.11     clean"
  "1:2.34.1               2.34.1     strip-epoch"
  "2.0.11-1ubuntu1        2.0.11     strip-debian-packaging"
  "1:2.34.1-1ubuntu1.9    2.34.1     strip-epoch-and-packaging"
  "2.0.11-3.fc39          2.0.11     strip-rpm-packaging"
  "2.0.11~rc1             2.0.11     strip-tilde-prerelease"
  "2.0.11-beta3           2.0.11     strip-dash-prerelease"
  "2.0.11+build4          2.0.11     strip-plus-build"
  "2.0                    2.0        short-version"
  "3                      3          single-component"
)
for row in "${norm_cases[@]}"; do
  read -r raw expected label <<<"$row"
  got=$(detect::_version_normalize "$raw")
  assert::eq "$got" "$expected" "normalize $label ($raw)"
done

# Each row: a  op  b  label
# op is one of: lt, eq, gt
cmp_cases=(
  "2.0.11      lt  2.0.12     patch"
  "2.0.11      eq  2.0.11     same"
  "2.0.12      gt  2.0.11     patch-up"
  "2.0         eq  2.0.0      missing-component-is-zero"
  "2.0.1       gt  2.0        trailing-above"
  "3.0         gt  2.99.99    major-wins"
  "1.10        gt  1.9        numeric-not-lexical"
  "2.0         lt  2.0.1      missing-below-present"
)
for row in "${cmp_cases[@]}"; do
  read -r a op b label <<<"$row"
  got=$(detect::_version_compare "$a" "$b" || true)
  case "$op" in
    lt) exp=-1 ;;
    eq) exp=0  ;;
    gt) exp=1  ;;
  esac
  assert::eq "$got" "$exp" "compare $label ($a $op $b)"
done
