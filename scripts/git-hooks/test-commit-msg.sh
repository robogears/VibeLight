#!/bin/bash
# Self-test for the commit-MESSAGE topology guard. Run after any edit to it:
#
#   scripts/git-hooks/test-commit-msg.sh
#
# The '#'-line cases exist because the guard shipped with a hole: it skipped
# comment lines as "git strips them anyway", which is true for editor commits
# (cleanup=strip) and FALSE for `git commit -m` (cleanup=whitespace). A real
# address on such a line passed the guard and was stored in the commit.
#
# NOTE: the fixtures below are leak-SHAPED on purpose and are not the real
# values; they carry no topology-ok marker precisely because these run the hook
# directly on a file rather than through a commit.
set -u
HOOK="$(cd "$(dirname "$0")" && pwd)/commit-msg"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0

check() { # $1=label  $2=message  $3=BLOCK|PASS
  printf '%s\n' "$2" > "$TMP/msg"
  if "$HOOK" "$TMP/msg" >/dev/null 2>&1; then got=PASS; else got=BLOCK; fi
  if [ "$got" = "$3" ]; then echo "  ok   [$3] $1"; pass=$((pass+1))
  else echo "  FAIL got=$got want=$3 :: $1"; fail=$((fail+1)); fi
}

echo "Messages that must be BLOCKED:"
check "LAN IP in the subject"        'Fix pairing against 192.168.9.212'                 BLOCK   # topology-ok
check "Tailscale IP in the body"     'Fix pairing

tested on 100.126.19.18'                                                                 BLOCK   # topology-ok
check "MAC in the body"              'WoL now works

sent to de:ad:be:ef:00:01'                                                               BLOCK   # topology-ok
check "LAN IP on a #-leading line"   'Fix pairing
# tested against 192.168.9.212'                                                          BLOCK   # topology-ok
check "MAC on a #-leading line"      'Fix WoL
#   de:ad:be:ef:00:01'                                                                   BLOCK   # topology-ok
check "IP indented under a # line"   'Fix pairing
#notes
    192.168.9.212'                                                                       BLOCK   # topology-ok

echo "Messages that must PASS:"
check "ordinary message"             'Move the presets under the games'                  PASS
check "documentation placeholder"    'Explain the 192.168.1.10 example in the hint'      PASS
check "placeholder MAC"              'Use aa:bb:cc:dd:ee:ff in the docs'                 PASS   # topology-ok
check "topology-ok escape"           'Note 192.168.9.9 as an example  topology-ok'       PASS
check "git scissors diff is ignored" 'Fix pairing

# ------------------------ >8 ------------------------
diff --git a/x b/x
-let old = "192.168.9.212"'                                                              PASS   # topology-ok

echo "Fail-closed:"
printf 'Fix pairing\n' > "$TMP/msg"
mkdir -p "$TMP/stub"; printf '#!/bin/sh\nexit 3\n' > "$TMP/stub/sed"; chmod +x "$TMP/stub/sed"
if PATH="$TMP/stub:$PATH" "$HOOK" "$TMP/msg" >/dev/null 2>&1
then echo "  FAIL sanitizer broken but hook approved"; fail=$((fail+1))
else echo "  ok   broken sed refuses";                 pass=$((pass+1)); fi

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
