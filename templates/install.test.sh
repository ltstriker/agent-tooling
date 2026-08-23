#!/usr/bin/env bash
# Tests for the floating consumer bootstrap and its companions:
#
#   templates/install.sh                  resolve tooling.ref -> fetch -> validate -> record
#   scripts/verify-installation.sh        gates hold commits to the RECORD, offline
#   scripts/refresh-installation.sh       advances the record when the branch moves
#   scripts/sync-installation.sh          spawns the refresh in the background, throttled
#
# Hermetic by construction: a gitconfig (GIT_CONFIG_GLOBAL) rewrites the one
# hard-coded tooling URL to a local fixture remote via url.insteadOf, and pins
# http.proxy at a dead loopback port so a broken rewrite fails instantly instead of
# dialing github.com. "Offline" is simulated by pointing the rewrite at a path that
# does not exist.
#
# The properties that matter most here, because every one of them fails silently in
# production if it regresses:
#
#   - current is written LAST: a tip that fetches but fails validation must leave the
#     previous revision adopted and verifiable (validate-before-adopt).
#   - resolution failure with an installed revision is a warning, not an error;
#     without one it is an error (only the first install needs the network).
#   - a hold is obeyed without any resolution at all, a malformed hold stops
#     everything, and the gates stay closed until a new hold is adopted.
#   - the gates never touch the network: verify passes and fails identically with
#     the remote unreachable.
#
# Run with:  bash templates/install.test.sh
# Exits non-zero on any failure.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_ROOT="$REPO_ROOT/plugins/boxlite-agent-tooling"
# pwd -P: macOS mktemp answers under /var/folders, a symlink to /private/var — the
# suite compares absolute paths against setup's physically-resolved ones.
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check_eq() {
  local desc="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then ok "$desc"; else bad "$desc (got=$got want=$want)"; fi
}

command -v jq >/dev/null 2>&1 || { printf 'jq is required to run these tests\n' >&2; exit 2; }

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
point_remote() {  # $1 = directory to serve as the tooling repository
  : > "$GIT_CONFIG_GLOBAL"
  git config --file "$GIT_CONFIG_GLOBAL" http.proxy "http://127.0.0.1:9"
  git config --file "$GIT_CONFIG_GLOBAL" \
    url."file://$1".insteadOf "https://github.com/boxlite-ai/agent-tooling.git"
}

# The fixture tooling repository: the real plugin tree, committed on main.
REMOTE="$TMP/remote"
git -c init.defaultBranch=main init -q "$REMOTE"
git -C "$REMOTE" config user.email t@t.test
git -C "$REMOTE" config user.name tester
git -C "$REMOTE" config uploadpack.allowReachableSHA1InWant true  # what GitHub allows
mkdir -p "$REMOTE/plugins"
cp -R "$PLUGIN_ROOT" "$REMOTE/plugins/boxlite-agent-tooling"
git -C "$REMOTE" add -A
git -C "$REMOTE" commit -qm one
TIP_ONE="$(git -C "$REMOTE" rev-parse HEAD)"
advance_remote() {
  printf 'x\n' >> "$REMOTE/tick"
  git -C "$REMOTE" add tick
  git -C "$REMOTE" commit -qm tick
  git -C "$REMOTE" rev-parse HEAD
}
point_remote "$REMOTE"

make_consumer() {  # $1 = directory
  local c="$1"
  mkdir -p "$c"
  git init -q "$c"
  git -C "$c" config user.email t@t.test
  git -C "$c" config user.name tester
  mkdir -p "$c/.agent-tooling" "$c/.agents/plugins" "$c/.claude" "$c/.github/copilot"
  jq -nc '{schemaVersion:1,profile:"consumer",repository:"boxlite-ai/example-consumer",tooling:{repository:"boxlite-ai/agent-tooling",ref:"main"},checks:[{name:"test",command:"true"}]}' \
    > "$c/.agent-tooling/profile.json"
  jq -nc '{extraKnownMarketplaces:{"boxlite-agent-tooling":{source:{repo:"boxlite-ai/agent-tooling",ref:"main"}}},enabledPlugins:{"boxlite-agent-tooling@boxlite-agent-tooling":true}}' \
    > "$c/.claude/settings.json"
  cp "$c/.claude/settings.json" "$c/.github/copilot/settings.json"
  jq -nc '{plugins:[{name:"boxlite-agent-tooling",source:{url:"https://github.com/boxlite-ai/agent-tooling.git",ref:"main",path:"./plugins/boxlite-agent-tooling"},policy:{installation:"INSTALLED_BY_DEFAULT"}}]}' \
    > "$c/.agents/plugins/marketplace.json"
  printf '/.agents/state/\n/.claude/.*\n' > "$c/.gitignore"
  printf 'base\n' > "$c/file"
  git -C "$c" add -A
  git -C "$c" commit -qm base
  cp "$REPO_ROOT/templates/install.sh" "$c/.agent-tooling/install.sh"
  chmod +x "$c/.agent-tooling/install.sh"
}

CONSUMER="$TMP/consumer"
make_consumer "$CONSUMER"
CACHE="$CONSUMER/.git/agent-tooling"
RECORD="$CACHE/current"
record() { head -n1 "$RECORD" 2>/dev/null || printf 'none'; }
installed_plugin() { printf '%s/%s/plugins/boxlite-agent-tooling' "$CACHE" "$1"; }
run_install() { (cd "$CONSUMER" && ./.agent-tooling/install.sh); }
run_verify() { "$(installed_plugin "$(record)")/scripts/verify-installation.sh" "$CONSUMER"; }

echo "## First installation resolves the branch and adopts its tip"
run_install > "$TMP/out" 2> "$TMP/err"
check_eq "bootstrap succeeds" "$?" 0
check_eq "records the resolved tip" "$(record)" "$TIP_ONE"
check_eq "configures the recorded revision's hooks" \
  "$(git -C "$CONSUMER" config --worktree --get core.hooksPath)" "$(installed_plugin "$TIP_ONE")/.githooks"
check_eq "history logs the adoption source" \
  "$(awk 'END{print $2, $3}' "$CACHE/history.log")" "main $TIP_ONE"
[ -e "$CACHE/last-check" ] && ok "stamps last-check" || bad "stamps last-check"
run_verify >/dev/null 2>&1
check_eq "fresh installation verifies" "$?" 0

echo
echo "## Re-running against an unmoved branch is a cheap no-op"
run_install > "$TMP/out" 2>/dev/null
check_eq "second run succeeds" "$?" 0
check_eq "record is unchanged" "$(record)" "$TIP_ONE"

echo
echo "## A moved branch is adopted on the next install"
TIP_TWO="$(advance_remote)"
run_install >/dev/null 2>&1
check_eq "install adopts the new tip" "$(record)" "$TIP_TWO"
[ -d "$(installed_plugin "$TIP_ONE")" ] && ok "previous revision stays cached" \
                                        || bad "previous revision stays cached"

echo
echo "## Resolution failure keeps the last adopted revision"
point_remote "$TMP/void"
run_install > "$TMP/out" 2> "$TMP/err"
check_eq "offline install with a record succeeds" "$?" 0
grep -q 'could not resolve' "$TMP/err" && ok "explains it kept the record" \
                                       || bad "explains it kept the record"
check_eq "record survives the failed resolution" "$(record)" "$TIP_TWO"
run_verify >/dev/null 2>&1
check_eq "gates verify with the remote unreachable" "$?" 0

echo
echo "## Only the very first installation needs the network"
FRESH="$TMP/fresh"
make_consumer "$FRESH"
(cd "$FRESH" && ./.agent-tooling/install.sh) >/dev/null 2> "$TMP/err"
check_eq "offline bootstrap without a record fails" "$?" 1
grep -q 'no revision is installed' "$TMP/err" && ok "names the missing installation" \
                                              || bad "names the missing installation"

echo
echo "## A hold is obeyed without resolving anything"
# The remote is still unreachable; the held revision is served from the cache.
printf '%s\n' "$TIP_ONE" > "$CONSUMER/.agent-tooling/hold"
run_install >/dev/null 2> "$TMP/err"
check_eq "held install succeeds offline" "$?" 0
check_eq "record moves to the held revision" "$(record)" "$TIP_ONE"
check_eq "history logs the hold as the source" \
  "$(awk 'END{print $2, $3}' "$CACHE/history.log")" "hold $TIP_ONE"

echo
echo "## Gates stay closed until a changed hold is adopted"
printf '%s\n' "$TIP_TWO" > "$CONSUMER/.agent-tooling/hold"
run_verify >/dev/null 2> "$TMP/err"
check_eq "verify fails on an un-adopted hold" "$?" 1
grep -q 'is not adopted' "$TMP/err" && ok "verify names the un-adopted hold" \
                                    || bad "verify names the un-adopted hold"
run_install >/dev/null 2>&1
check_eq "install adopts the changed hold from cache" "$(record)" "$TIP_TWO"
run_verify >/dev/null 2>&1
check_eq "verify passes once the hold is adopted" "$?" 0

echo
echo "## A malformed hold stops everything"
printf 'not-a-sha\n' > "$CONSUMER/.agent-tooling/hold"
run_install >/dev/null 2> "$TMP/err"
check_eq "install refuses a malformed hold" "$?" 1
grep -q 'exactly one full lowercase commit SHA' "$TMP/err" && ok "install names the malformed hold" \
                                                          || bad "install names the malformed hold"
run_verify >/dev/null 2>&1
check_eq "verify refuses a malformed hold" "$?" 1
rm "$CONSUMER/.agent-tooling/hold"

echo
echo "## A tip that fails validation is never adopted"
point_remote "$REMOTE"
TIP_THREE="$(advance_remote)"
jq '.extraKnownMarketplaces["boxlite-agent-tooling"].source.ref = "other"' \
  "$CONSUMER/.claude/settings.json" > "$TMP/settings" && cp "$TMP/settings" "$CONSUMER/.claude/settings.json"
run_install >/dev/null 2> "$TMP/err"
check_eq "install fails when validation rejects the consumer" "$?" 1
check_eq "record still names the last validated revision" "$(record)" "$TIP_TWO"
jq '.extraKnownMarketplaces["boxlite-agent-tooling"].source.ref = "main"' \
  "$CONSUMER/.claude/settings.json" > "$TMP/settings" && cp "$TMP/settings" "$CONSUMER/.claude/settings.json"
run_install >/dev/null 2>&1
check_eq "install adopts the tip once validation passes" "$(record)" "$TIP_THREE"

echo
echo "## The profile only accepts a branch"
jq '.tooling.ref = "-evil"' "$CONSUMER/.agent-tooling/profile.json" > "$TMP/p" && cp "$TMP/p" "$CONSUMER/.agent-tooling/profile.json"
run_install >/dev/null 2> "$TMP/err"
check_eq "install refuses an invalid ref" "$?" 1
jq --arg sha "$TIP_ONE" '.tooling.ref = $sha' "$CONSUMER/.agent-tooling/profile.json" > "$TMP/p" && cp "$TMP/p" "$CONSUMER/.agent-tooling/profile.json"
run_install >/dev/null 2> "$TMP/err"
check_eq "install refuses a revision as the ref" "$?" 1
grep -q 'write it to .agent-tooling/hold' "$TMP/err" && ok "points a pinner at the hold file" \
                                                     || bad "points a pinner at the hold file"
jq '.tooling.ref = "main"' "$CONSUMER/.agent-tooling/profile.json" > "$TMP/p" && cp "$TMP/p" "$CONSUMER/.agent-tooling/profile.json"

echo
echo "## The refresh advances the record when the branch moves"
REFRESH="$(installed_plugin "$(record)")/scripts/refresh-installation.sh"
TIP_FOUR="$(advance_remote)"
bash "$REFRESH" "$CONSUMER" >/dev/null 2>&1
check_eq "refresh adopts the moved tip" "$(record)" "$TIP_FOUR"
bash "$REFRESH" "$CONSUMER" >/dev/null 2>&1
check_eq "refresh with an unmoved tip is a no-op" "$(record)" "$TIP_FOUR"
point_remote "$TMP/void"
bash "$REFRESH" "$CONSUMER" >/dev/null 2> "$TMP/err"
check_eq "refresh tolerates an unreachable remote" "$?" 0
grep -q 'could not resolve' "$TMP/err" && ok "refresh says it kept the record" \
                                       || bad "refresh says it kept the record"
check_eq "record survives the failed refresh" "$(record)" "$TIP_FOUR"
point_remote "$REMOTE"
# A SHA-shaped ref must fail the refresh the same way it fails the bootstrap and
# the profile validation — loudly, before resolution, without stamping last-check —
# not resolve to nothing and read as an ordinary offline interval.
jq --arg sha "$TIP_ONE" '.tooling.ref = $sha' "$CONSUMER/.agent-tooling/profile.json" > "$TMP/p" && cp "$TMP/p" "$CONSUMER/.agent-tooling/profile.json"
bash "$REFRESH" "$CONSUMER" >/dev/null 2> "$TMP/err"
check_eq "refresh refuses a revision as the ref" "$?" 1
grep -q 'write it to .agent-tooling/hold' "$TMP/err" && ok "refresh points a pinner at the hold file" \
                                                    || bad "refresh points a pinner at the hold file"
check_eq "record survives the refused ref" "$(record)" "$TIP_FOUR"
jq '.tooling.ref = "main"' "$CONSUMER/.agent-tooling/profile.json" > "$TMP/p" && cp "$TMP/p" "$CONSUMER/.agent-tooling/profile.json"

echo
echo "## Lifecycle sync spawns the refresh, throttled"
SYNC="$(installed_plugin "$(record)")/scripts/sync-installation.sh"
TIP_FIVE="$(advance_remote)"
touch "$CACHE/last-check"
(cd "$CONSUMER" && bash "$SYNC") 2>/dev/null
sleep 0.3
check_eq "a fresh last-check suppresses the refresh" "$(record)" "$TIP_FOUR"
(cd "$CONSUMER" && AGENT_TOOLING_REFRESH=0 AGENT_TOOLING_REFRESH_MINUTES=0 bash "$SYNC") 2>/dev/null
sleep 0.3
check_eq "AGENT_TOOLING_REFRESH=0 disables the refresh" "$(record)" "$TIP_FOUR"
(cd "$CONSUMER" && AGENT_TOOLING_REFRESH_MINUTES=0 bash "$SYNC") 2>/dev/null
for _ in $(seq 1 100); do [[ "$(record)" == "$TIP_FIVE" ]] && break; sleep 0.1; done
check_eq "a due sync adopts the moved tip in the background" "$(record)" "$TIP_FIVE"

echo
printf 'RESULT: %d passed, %d failed\n' "$pass" "$fail"
exit $(( fail > 0 ? 1 : 0 ))
