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

echo
echo "passed: $pass  failed: $fail"
[[ "$fail" -eq 0 ]]
