#!/usr/bin/env bash
set -uo pipefail

# Regression tests for post-tool-use.sh commit detection.
#
# Each case feeds a synthetic PostToolUse payload to the hook and asserts
# whether a nudge was emitted. Every case uses a unique session id so the
# two-offers-per-session cap never masks a result.
#
# Run: learning-opportunities-auto/hooks/test-post-tool-use.sh

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/post-tool-use.sh"

if [[ ! -x "$HOOK" ]]; then
  echo "hook not executable: $HOOK" >&2
  exit 1
fi

# Run each case against a throwaway TMPDIR so the state files from a previous
# run can't influence this one.
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# The hook checks that HEAD is a fresh commit before nudging, so cases run
# against a scratch repo whose HEAD we control rather than against the repo
# this suite happens to live in (whose HEAD is arbitrarily old).
REPO="$TEST_TMPDIR/repo"
git init -q "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
git -C "$REPO" config commit.gpgsign false

# fresh_commit <subject> — commit and echo nothing; leaves HEAD current.
fresh_commit() {
  echo "$RANDOM$RANDOM" > "$REPO/file.txt"
  git -C "$REPO" add file.txt
  git -C "$REPO" commit -q -m "$1"
}

fresh_commit "initial commit"

pass=0
fail=0
case_n=0

json_escape() {
  # Minimal JSON string escaping for the test payloads: backslash, quote, tab,
  # carriage return, newline.
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | awk 'BEGIN{ORS=""} NR>1{print "\\n"} {gsub(/\t/,"\\t"); gsub(/\r/,"\\r"); print}'
}

# assert <expected: nudge|silent> <command> [tool output]
assert() {
  local expected="$1" command="$2" output="${3:-}"
  local payload actual
  case_n=$((case_n + 1))

  payload=$(printf '{"session_id":"test-%s","cwd":"%s","tool_input":{"command":"%s"},"tool_response":{"output":"%s"}}' \
    "$case_n" "$(json_escape "$REPO")" "$(json_escape "$command")" "$(json_escape "$output")")

  if printf '%s' "$payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null | grep -q additionalContext; then
    actual="nudge"
  else
    actual="silent"
  fi

  if [[ "$actual" == "$expected" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  expected %-6s got %-6s  cmd=%s\n' "$expected" "$actual" "$command" >&2
    [[ -n "$output" ]] && printf '      output=%s\n' "$output" >&2
  fi
}

# --- real commits: must nudge ----------------------------------------------
assert nudge 'git commit'
assert nudge 'git commit -m "add feature"'
assert nudge 'git commit --amend --no-edit'
assert nudge 'git add -A && git commit -m "wip"'
assert nudge 'cd /some/repo && git commit -m "wip"'
assert nudge 'git commit -m "msg"; echo done'
assert nudge '(git commit -m "msg")'
assert nudge 'git commit -m "msg" | tee log'
assert nudge 'git -C /some/repo commit -m "msg"'
assert nudge 'git -c user.name=Test commit -m "msg"'
assert nudge '$(git commit -m "msg")'
assert nudge '  git commit -m "leading whitespace"'

# --- jj (Jujutsu) commits: must nudge --------------------------------------
assert nudge 'jj commit'
assert nudge 'jj commit -m "add feature"'
assert nudge 'jj commit; echo done'
assert nudge '(jj commit -m "msg")'
assert nudge 'jj commit -m "msg" | tee log'
assert nudge 'jj -R /some/repo commit -m "msg"'
assert nudge 'cd /some/repo && jj commit -m "wip"'

# --- jj non-commits: must stay silent --------------------------------------
assert silent 'jj log -r commit'
assert silent 'jj describe -m "say commit"'
assert silent 'jj status' 'Working copy changes: nothing to commit'
assert silent 'grep -rn "jj commit" docs/'
assert silent 'jj commit-something'

# --- tool output mentioning commits: must stay silent ----------------------
# These are the regressions: the payload's tool_response used to be scanned
# alongside the command, so ordinary read-only git calls reported a commit.
assert silent 'git status' 'nothing to commit, working tree clean'
assert silent 'git log --oneline' 'commit 2b3a5e0 Merge pull request #17'
assert silent 'git show HEAD' 'commit ae8412f
Author: Someone'
assert silent 'git reflog' 'ae8412f HEAD@{0}: commit: fix things'
assert silent 'git diff --stat' '1 file changed, ready to commit'

# --- command text mentioning commits: must stay silent ---------------------
assert silent 'git log --grep=commit'
assert silent 'grep -rn "github.com/owner/repo/commit" .'
assert silent 'echo "how to git commit"'
assert silent 'ls git_commit_history'
assert silent 'git-foo commit'
assert silent 'git commit-tree abc123'
assert silent 'git log -1 --format=%H'

# --- non-git commands: must stay silent ------------------------------------
assert silent 'ls -la'
assert silent 'npm test'

# --- malformed / missing input: must stay silent, never error --------------
printf '%s' '{"session_id":"test-malformed","tool_input":{}}' \
  | TMPDIR="$TEST_TMPDIR" bash "$HOOK" >/dev/null 2>&1
if [[ $? -le 1 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL  malformed payload errored" >&2; fi

printf '%s' 'not json at all' | TMPDIR="$TEST_TMPDIR" bash "$HOOK" >/dev/null 2>&1
if [[ $? -le 1 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL  non-JSON payload errored" >&2; fi

# --- session cap: third distinct commit in a session stays silent ----------
# Each iteration makes a real new commit so the per-SHA de-dupe below isn't
# what's being measured here.
cap_nudges=0
for i in 1 2 3; do
  fresh_commit "cap commit $i"
  payload=$(printf '{"session_id":"test-cap","cwd":"%s","tool_input":{"command":"git commit -m \\"x\\""},"tool_response":{}}' "$REPO")
  if printf '%s' "$payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null | grep -q additionalContext; then
    cap_nudges=$((cap_nudges + 1))
  fi
done
if [[ "$cap_nudges" -eq 2 ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  session cap: expected 2 nudges in 3 distinct commits, got $cap_nudges" >&2
fi

# --- de-dupe: the same commit fired twice consumes only one offer ----------
fresh_commit "dedupe commit"
dedupe_payload=$(printf '{"session_id":"test-dedupe","cwd":"%s","tool_input":{"command":"git commit -m \\"x\\""},"tool_response":{}}' "$REPO")
dedupe_nudges=0
for _ in 1 2 3; do
  if printf '%s' "$dedupe_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null | grep -q additionalContext; then
    dedupe_nudges=$((dedupe_nudges + 1))
  fi
done
if [[ "$dedupe_nudges" -eq 1 ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  de-dupe: expected 1 nudge for 3 fires on one commit, got $dedupe_nudges" >&2
fi

# --- failed commit: stale HEAD must stay silent ----------------------------
# Simulate a rejected commit by backdating HEAD's committer date well past the
# freshness window; the command still looks like a commit but nothing landed.
stale_repo="$TEST_TMPDIR/stale"
git init -q "$stale_repo"
git -C "$stale_repo" config user.email test@example.com
git -C "$stale_repo" config user.name "Test"
git -C "$stale_repo" config commit.gpgsign false
echo x > "$stale_repo/f.txt"
git -C "$stale_repo" add f.txt
GIT_COMMITTER_DATE="2020-01-01T00:00:00" GIT_AUTHOR_DATE="2020-01-01T00:00:00" \
  git -C "$stale_repo" commit -q -m "old commit"
stale_payload=$(printf '{"session_id":"test-stale","cwd":"%s","tool_input":{"command":"git commit -m \\"rejected\\""},"tool_response":{}}' "$stale_repo")
if printf '%s' "$stale_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null | grep -q additionalContext; then
  fail=$((fail + 1))
  echo "FAIL  stale HEAD: expected silent, got nudge" >&2
else
  pass=$((pass + 1))
fi

# --- commit context: SHA and subject reach the nudge -----------------------
fresh_commit "add the widget parser"
ctx_payload=$(printf '{"session_id":"test-ctx","cwd":"%s","tool_input":{"command":"git commit -m \\"x\\""},"tool_response":{}}' "$REPO")
ctx_out=$(printf '%s' "$ctx_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null)
ctx_sha=$(git -C "$REPO" rev-parse --short HEAD)
if grep -q "($ctx_sha: add the widget parser)" <<<"$ctx_out"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  commit context missing or malformed in nudge: $ctx_out" >&2
fi

# --- context sanitization: quotes/backslashes must not break the JSON ------
fresh_commit 'fix "quoted" \ backslash and	tab'
san_payload=$(printf '{"session_id":"test-san","cwd":"%s","tool_input":{"command":"git commit -m \\"x\\""},"tool_response":{}}' "$REPO")
san_out=$(printf '%s' "$san_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null)
if command -v jq >/dev/null 2>&1; then
  if jq -e . >/dev/null 2>&1 <<<"$san_out"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL  emitted invalid JSON for a subject with quotes/backslashes: $san_out" >&2
  fi
else
  pass=$((pass + 1))  # jq unavailable; the hook itself never requires it
fi

# --- commit targeting another repo via -C: uses that repo, not cwd ---------
# The session cwd here is a repo whose HEAD is stale, so a nudge can only
# happen if the hook actually followed the -C into the fresh repo.
other_repo="$TEST_TMPDIR/other"
git init -q "$other_repo"
git -C "$other_repo" config user.email test@example.com
git -C "$other_repo" config user.name "Test"
git -C "$other_repo" config commit.gpgsign false
echo y > "$other_repo/g.txt"
git -C "$other_repo" add g.txt
git -C "$other_repo" commit -q -m "commit in the other repo"
xrepo_payload=$(printf '{"session_id":"test-xrepo","cwd":"%s","tool_input":{"command":"git -C %s commit -m \\"x\\""},"tool_response":{}}' "$stale_repo" "$other_repo")
xrepo_out=$(printf '%s' "$xrepo_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null)
if grep -q "commit in the other repo" <<<"$xrepo_out"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  -C redirect: expected the other repo's commit, got: $xrepo_out" >&2
fi

# --- commit targeting another repo via leading cd ---------------------------
cd_payload=$(printf '{"session_id":"test-cdrepo","cwd":"%s","tool_input":{"command":"cd %s && git commit -m \\"x\\""},"tool_response":{}}' "$stale_repo" "$other_repo")
cd_out=$(printf '%s' "$cd_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null)
if grep -q "commit in the other repo" <<<"$cd_out"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  cd redirect: expected the other repo's commit, got: $cd_out" >&2
fi

# --- other redirect forms: --git-dir, --work-tree, pushd, and = syntax ------
for form in \
  "git --git-dir=%s/.git commit -m \\\\\"x\\\\\"" \
  "git --work-tree %s commit -m \\\\\"x\\\\\"" \
  "pushd %s && git commit -m \\\\\"x\\\\\"" \
  "git -C=%s commit -m \\\\\"x\\\\\""
do
  cmd=$(printf "$form" "$other_repo")
  p=$(printf '{"session_id":"test-redir-%s","cwd":"%s","tool_input":{"command":"%s"},"tool_response":{}}' \
    "$RANDOM" "$stale_repo" "$cmd")
  out=$(printf '%s' "$p" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null)
  if grep -q "commit in the other repo" <<<"$out"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL  redirect form not followed: $cmd" >&2
  fi
done

# --- quoted redirect paths: the JSON escaping must be undone first ----------
# A quoted path in the shell reaches the hook as \"...\", not "...". Parsing
# that as raw shell leaves the backslashes on the extracted value, the path
# stops resolving, and the hook falls back to the session cwd — which here is
# a stale repo, so the real commit would be dropped entirely. These forms are
# what an agent emits the moment a path could contain a space.
for form in \
  "git -C \\\\\"%s\\\\\" commit -m \\\\\"x\\\\\"" \
  "git -C=\\\\\"%s\\\\\" commit -m \\\\\"x\\\\\"" \
  "git --work-tree=\\\\\"%s\\\\\" commit -m \\\\\"x\\\\\"" \
  "cd \\\\\"%s\\\\\" && git commit -m \\\\\"x\\\\\""
do
  cmd=$(printf "$form" "$other_repo")
  p=$(printf '{"session_id":"test-quoted-%s","cwd":"%s","tool_input":{"command":"%s"},"tool_response":{}}' \
    "$RANDOM" "$stale_repo" "$cmd")
  out=$(printf '%s' "$p" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null)
  if grep -q "commit in the other repo" <<<"$out"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL  quoted redirect not followed: $cmd" >&2
  fi
done

# --- out-of-tree layout: --git-dir and --work-tree are independent ----------
# In a bare or separated layout neither option implies the other, so keeping
# only one sends the queries to a directory that is not a repository at all.
# The SHA then comes back empty and both the freshness check and the de-dupe
# are skipped — which is invisible on a single call, so assert on the second:
# a repeat of the same commit can only be suppressed if the SHA resolved.
meta_dir="$TEST_TMPDIR/meta.git"
work_dir="$TEST_TMPDIR/worktree"
mkdir -p "$work_dir"
git init -q --bare "$meta_dir"
git --git-dir="$meta_dir" --work-tree="$work_dir" config user.email test@example.com
git --git-dir="$meta_dir" --work-tree="$work_dir" config user.name "Test"
git --git-dir="$meta_dir" --work-tree="$work_dir" config commit.gpgsign false
echo z > "$work_dir/h.txt"
git --git-dir="$meta_dir" --work-tree="$work_dir" add h.txt
git --git-dir="$meta_dir" --work-tree="$work_dir" commit -q -m "commit in the out-of-tree repo"
oot_payload=$(printf '{"session_id":"test-outoftree","cwd":"%s","tool_input":{"command":"git --git-dir=%s --work-tree=%s commit -m \\"x\\""},"tool_response":{}}' \
  "$stale_repo" "$meta_dir" "$work_dir")
oot_first=$(printf '%s' "$oot_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null)
oot_second=$(printf '%s' "$oot_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null)
if grep -q "commit in the out-of-tree repo" <<<"$oot_first"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  out-of-tree: expected the out-of-tree repo's commit, got: $oot_first" >&2
fi
if grep -q additionalContext <<<"$oot_second"; then
  fail=$((fail + 1))
  echo "FAIL  out-of-tree: SHA never resolved, so the de-dupe was skipped" >&2
else
  pass=$((pass + 1))
fi

# --- an unresolvable redirect falls back to the session cwd ----------------
# Must not guess at a path that isn't there; the session repo stays in use.
bogus_payload=$(printf '{"session_id":"test-bogus","cwd":"%s","tool_input":{"command":"git -C /nope/nowhere commit -m \\"x\\""},"tool_response":{}}' "$REPO")
fresh_commit "fallback commit"
if printf '%s' "$bogus_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null | grep -q "fallback commit"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  unresolvable redirect should fall back to the session cwd" >&2
fi

# --- commit followed by slow work still nudges -----------------------------
# The hook fires only after the whole command finishes, so HEAD can be minutes
# old by the time it runs. Backdate HEAD past the old 120s window but inside
# the current one to prove a slow follow-up doesn't suppress a real commit.
slow_repo="$TEST_TMPDIR/slow"
git init -q "$slow_repo"
git -C "$slow_repo" config user.email test@example.com
git -C "$slow_repo" config user.name "Test"
git -C "$slow_repo" config commit.gpgsign false
echo z > "$slow_repo/h.txt"
git -C "$slow_repo" add h.txt
# Epoch form with an explicit zone — a bare timestamp is read as local time,
# which silently shifts the commit by the UTC offset.
slow_date="@$(( $(date +%s) - 300 )) +0000"
GIT_COMMITTER_DATE="$slow_date" GIT_AUTHOR_DATE="$slow_date" \
  git -C "$slow_repo" commit -q -m "commit then slow test run"
slow_payload=$(printf '{"session_id":"test-slow","cwd":"%s","tool_input":{"command":"git commit -m \\"x\\" && npm test"},"tool_response":{}}' "$slow_repo")
if printf '%s' "$slow_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null | grep -q additionalContext; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  commit + 5min of follow-up work: expected nudge, got silence" >&2
fi

# --- non-git working directory: still nudges, just without context ---------
# Non-colocated Jujutsu repos have no .git, so failing closed here would
# silently disable the hook for those users.
nogit_dir="$TEST_TMPDIR/nogit"
mkdir -p "$nogit_dir"
nogit_payload=$(printf '{"session_id":"test-nogit","cwd":"%s","tool_input":{"command":"jj commit -m \\"x\\""},"tool_response":{}}' "$nogit_dir")
if printf '%s' "$nogit_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null | grep -q additionalContext; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  non-git cwd: expected nudge without context, got silence" >&2
fi

# --- concurrency: parallel hooks for one commit emit exactly one nudge -----
# Tool calls can run in parallel, so the read-check-write across the state
# files is genuinely reachable from two processes at once.
fresh_commit "concurrent commit"
conc_payload=$(printf '{"session_id":"test-conc","cwd":"%s","tool_input":{"command":"git commit -m \\"x\\""},"tool_response":{}}' "$REPO")
conc_out="$TEST_TMPDIR/conc"; mkdir -p "$conc_out"
for i in 1 2 3 4 5 6; do
  ( printf '%s' "$conc_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null > "$conc_out/$i" ) &
done
wait
conc_nudges=$(grep -l additionalContext "$conc_out"/* 2>/dev/null | wc -l | tr -d ' ')
if [[ "$conc_nudges" -eq 1 ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  concurrency: expected 1 nudge from 6 parallel hooks on one commit, got $conc_nudges" >&2
fi

# --- the session cap holds across six distinct commits ---------------------
# Each hook gets its own repository, so all six observe a *different* SHA and
# every one of them clears the de-dupe — this exercises the offer counter, not
# de-duplication. Pointing them at a single repo would not: HEAD advances while
# the hooks are still starting, they collapse onto one SHA, and the test then
# passes on the de-dupe path without the counter ever being the thing that
# stopped it.
#
# Run sequentially here, where the assertion can be exact. Under contention it
# could not be — see the parallel case below.
for i in 1 2 3 4 5 6; do
  r="$TEST_TMPDIR/caprepo$i"
  git init -q "$r"
  git -C "$r" config user.email test@example.com
  git -C "$r" config user.name "Test"
  git -C "$r" config commit.gpgsign false
  echo "$i" > "$r/f.txt"
  git -C "$r" add f.txt
  git -C "$r" commit -q -m "cap commit $i"
done
cap_seq_nudges=0
for i in 1 2 3 4 5 6; do
  p=$(printf '{"session_id":"test-capseq","cwd":"%s","tool_input":{"command":"git commit -m \\"x\\""},"tool_response":{}}' "$TEST_TMPDIR/caprepo$i")
  if printf '%s' "$p" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null | grep -q additionalContext; then
    cap_seq_nudges=$((cap_seq_nudges + 1))
  fi
done
if [[ "$cap_seq_nudges" -eq 2 ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  session cap: expected exactly 2 nudges from 6 distinct commits, got $cap_seq_nudges" >&2
fi

# --- concurrency: parallel distinct commits stay within the cap, and the
# --- hook is not silenced altogether ----------------------------------------
# Bounded on both sides. The upper bound is the cap itself. The lower bound
# matters just as much and is what a bare `-le 2` misses: losing the lock is
# a silent exit by design, so a regression that made every contender lose
# would show up as zero nudges and still satisfy `-le 2`. An exact assertion
# is not available here — how many of the six win the lock is genuinely
# timing-dependent, which is the cost of not blocking.
conc2_out="$TEST_TMPDIR/conc2"; mkdir -p "$conc2_out"
for i in 1 2 3 4 5 6; do
  p=$(printf '{"session_id":"test-conc2","cwd":"%s","tool_input":{"command":"git commit -m \\"x\\""},"tool_response":{}}' "$TEST_TMPDIR/caprepo$i")
  ( printf '%s' "$p" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null > "$conc2_out/$i" ) &
done
wait
conc2_nudges=$(grep -l additionalContext "$conc2_out"/* 2>/dev/null | wc -l | tr -d ' ')
if [[ "$conc2_nudges" -ge 1 && "$conc2_nudges" -le 2 ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  concurrency: expected 1-2 nudges from 6 parallel distinct commits, got $conc2_nudges" >&2
fi

# --- an orphaned lock is reclaimed, not treated as permanent ---------------
fresh_commit "after stale lock"
stale_lock="$TEST_TMPDIR/lo_auto_test-stalelock.lock"
mkdir -p "$stale_lock"
touch -t 202001010000 "$stale_lock" 2>/dev/null
lock_payload=$(printf '{"session_id":"test-stalelock","cwd":"%s","tool_input":{"command":"git commit -m \\"x\\""},"tool_response":{}}' "$REPO")
if printf '%s' "$lock_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null | grep -q additionalContext; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  stale lock: expected the orphaned lock to be reclaimed and a nudge emitted" >&2
fi

# --- the lock is released on early-exit paths too --------------------------
printf '%s' "$conc_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" >/dev/null 2>&1
if [[ ! -d "$TEST_TMPDIR/lo_auto_test-conc.lock" ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  lock leaked after an early exit" >&2
fi

# --- performance guard: a large payload must not stall the hot path --------
# A 100 KB heredoc is an ordinary Bash call. The hook fires on every one of
# them, so detection has to stay cheap regardless of command size.
big=$(printf 'a%.0s' $(seq 1 100000))
big_payload=$(printf '{"session_id":"test-big","tool_input":{"command":"echo %s"},"tool_response":{}}' "$big")
start=$(date +%s)
printf '%s' "$big_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
if [[ "$elapsed" -le 5 ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL  100 KB payload took ${elapsed}s (expected <=5s)" >&2
fi

# --- Codex hook path must not pin a plugin version -------------------------
# The Codex hook resolves this script out of Codex's plugin cache, whose path
# contains the installed version. Hardcoding that version means every release
# silently disables the hook until the string is bumped in lockstep, and it
# never matches a local dev install (cached under "local", not a version).
CODEX_HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks.codex.json"
if grep -Eq '/learning-opportunities-auto/[0-9]+\.[0-9]+\.[0-9]+/' "$CODEX_HOOKS"; then
  fail=$((fail + 1))
  echo "FAIL  hooks.codex.json pins a plugin version in the cache path" >&2
else
  pass=$((pass + 1))
fi

if command -v jq >/dev/null 2>&1; then
  if jq -e . >/dev/null 2>&1 < "$CODEX_HOOKS"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL  hooks.codex.json is not valid JSON" >&2
  fi
else
  pass=$((pass + 1))
fi

# --- Codex hook resolves the version Codex itself considers active ---------
# Runs the real command string out of the config against a fake cache, so the
# resolution logic is exercised rather than assumed.
#
# The rule has to match Codex's own: `local` when that directory exists,
# otherwise the highest version. Codex loads the plugin config from the
# directory it considers active, so a hook that picks differently runs a
# script belonging to a different install. Both cases below are built so that
# selecting by modification time would pick the wrong one.
if command -v jq >/dev/null 2>&1; then
  fake_home="$TEST_TMPDIR/codex"
  fake_base="$fake_home/plugins/cache/learning-opportunities/learning-opportunities-auto"
  for v in 1.0.2 1.10.0 1.9.0; do
    mkdir -p "$fake_base/$v/hooks"
    printf '#!/usr/bin/env bash\necho RESOLVED-%s\n' "$v" > "$fake_base/$v/hooks/post-tool-use.sh"
  done
  codex_cmd=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$CODEX_HOOKS")

  # Highest version wins, not the newest on disk and not the lexicographic
  # maximum — 1.0.2 is touched last here, and 1.9.0 sorts above 1.10.0 as text.
  touch "$fake_base/1.0.2"
  resolved=$(CODEX_HOME="$fake_home" bash -c "$codex_cmd" 2>/dev/null)
  if [[ "$resolved" == "RESOLVED-1.10.0" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL  Codex hook resolution: expected RESOLVED-1.10.0, got '$resolved'" >&2
  fi

  # A local dev install wins over every numbered version, however old it is.
  # 1.10.0 is touched *after* local is written — both the directory and the
  # script inside it — so any form of recency selection would pick 1.10.0 here
  # and this assertion can only pass by preferring local outright.
  mkdir -p "$fake_base/local/hooks"
  printf '#!/usr/bin/env bash\necho RESOLVED-local\n' > "$fake_base/local/hooks/post-tool-use.sh"
  touch "$fake_base/1.10.0/hooks/post-tool-use.sh" "$fake_base/1.10.0"
  resolved=$(CODEX_HOME="$fake_home" bash -c "$codex_cmd" 2>/dev/null)
  if [[ "$resolved" == "RESOLVED-local" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL  Codex hook resolution: expected RESOLVED-local, got '$resolved'" >&2
  fi

  # A missing cache must exit silently rather than erroring.
  CODEX_HOME="$TEST_TMPDIR/nonexistent" bash -c "$codex_cmd" >/dev/null 2>&1
  if [[ $? -eq 0 ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL  Codex hook with no cache should exit 0" >&2
  fi
else
  pass=$((pass + 3))
fi

echo
echo "passed: $pass  failed: $fail"
[[ "$fail" -eq 0 ]]
