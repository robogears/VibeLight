#!/bin/bash
# Self-test for the topology guard. Run it after ANY edit to pre-commit:
#
#   scripts/git-hooks/test-pre-commit.sh
#
# NOTE: every fixture below carries a `topology-ok` marker — the values are
# leak-SHAPED on purpose (and are not the real ones), so without it this file
# would trip the very guard it tests.
#
# Two of these cases exist because the guard shipped broken twice. A guard is
# only worth what its test suite proves, and both bugs FAILED OPEN — the hook
# exited 0 while checking nothing, which looks identical to "all clear".
#   1. a stray sed backreference emptied the candidate set  → fail-closed cases
#   2. `grep -E '^\+[^+]'` dropped added lines starting with '+' → prefix cases
set -u
HOOK="$(cd "$(dirname "$0")" && pwd)/pre-commit"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/stub"; cd "$TMP" || exit 1
git init -q .; git config user.email t@t; git config user.name t
cp "$HOOK" .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
pass=0; fail=0
check() {
  printf '%s\n' "$2" > f.txt; git add f.txt >/dev/null 2>&1
  if git commit -q -m t >/dev/null 2>&1; then got=PASS; else got=BLOCK; fi
  git reset -q --hard >/dev/null 2>&1
  if [ "$got" = "$3" ]; then echo "  ok   [$3] $1"; pass=$((pass+1))
  else echo "  FAIL got=$got want=$3 :: $1"; fail=$((fail+1)); fi
}
echo "Leaks that must be BLOCKED (note the diff-prefix cases):"
check "leak on a line starting with +"   '+ server = "192.168.9.212"'      BLOCK   # topology-ok
check "leak on a line starting with ++"  '++ server = "192.168.9.212"'     BLOCK   # topology-ok
check "leak on a line starting with +++" '+++ b/x 192.168.9.212'           BLOCK   # topology-ok
check "leak on a line starting with -"   '- server = "192.168.9.212"'      BLOCK   # topology-ok
check "leak on a line starting with @@"  '@@ 192.168.9.212 @@'             BLOCK   # topology-ok
check "MAC on a line starting with +"    '+ mac de:ad:be:ef:00:01'         BLOCK   # topology-ok
check "private LAN IP"                   'let addr = "192.168.9.212"'      BLOCK   # topology-ok
check "Tailscale CGNAT IP"               'host = "100.126.19.18"'          BLOCK   # topology-ok
check "MAC address"                      'mac = "de:ad:be:ef:00:01"'       BLOCK   # topology-ok
check "broadcast on a real subnet"       'let b = "192.168.9.255"'         BLOCK   # topology-ok
echo "Legitimate content that must PASS:"
check "documentation placeholder"        'let addr = "192.168.1.10"'       PASS   # topology-ok
check "RFC5737 documentation IP"         'let addr = "203.0.113.5"'        PASS   # topology-ok
check "placeholder MAC"                  'mac = "aa:bb:cc:dd:ee:ff"'       PASS   # topology-ok
check "bare subnet base"                 'let net = "192.168.0.0"'         PASS   # topology-ok
check "topology-ok escape hatch"         'a="192.168.9.9" # topology-ok'   PASS
check "ordinary code"                    'func hello() {}'                 PASS   # topology-ok
check "placeholder on a + line"          '+ addr = "192.168.1.10"'         PASS   # topology-ok
echo "Fail-closed (a guard that cannot check must not approve):"
printf 'let a = "192.168.1.10"\n' > f.txt; git add f.txt >/dev/null 2>&1
printf '#!/bin/sh\nexit 3\n' > stub/sed; chmod +x stub/sed
if PATH="$TMP/stub:$PATH" .git/hooks/pre-commit >/dev/null 2>&1
then echo "  FAIL sanitizer broken but hook approved"; fail=$((fail+1))
else echo "  ok   broken sed refuses";                 pass=$((pass+1)); fi
printf '#!/bin/sh\nexit 129\n' > stub/git; chmod +x stub/git
if PATH="$TMP/stub:$PATH" .git/hooks/pre-commit >/dev/null 2>&1
then echo "  FAIL git rejected the option but hook approved"; fail=$((fail+1))
else echo "  ok   unusable git refuses";                       pass=$((pass+1)); fi
echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
