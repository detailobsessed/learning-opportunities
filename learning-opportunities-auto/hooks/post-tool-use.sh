#!/usr/bin/env bash
set -uo pipefail

# learning-opportunities-auto: PostToolUse hook (matches Bash tool)
#
# Fires after every Bash tool use. Checks whether the command was a
# `git commit` or `jj commit` and, if so, suggests that Claude offer a
# learning exercise. The skill itself decides whether the commit's content
# is worth an exercise — this hook just provides the nudge at the right
# moment.
#
# No external dependencies beyond bash and standard Unix tools.

INPUT=$(cat)

# ---------------------------------------------------------------------------
# Check if this was a commit.
#
# Both `git commit` and `jj commit` count. Jujutsu is git-compatible and in
# its default colocated mode operates directly on a standard .git directory,
# so `jj commit` produces a real git commit. The learning-opportunities skill
# is VCS-agnostic anyway — the meaningful event is "the user finalized a chunk
# of work", not which binary they typed.
#
# Claude Code sends shell text in a "command" field; Codex can send it in a
# "cmd" field. The payload also carries the tool's *output* in "tool_response",
# so matching against the whole payload conflates the two: `git status` prints
# "nothing to commit", `git log` prints "commit <sha>", and both used to be
# reported to the model as "the user just committed code".
#
# Two stages:
#   1. A cheap superset grep over the raw payload as a fast early exit. Any
#      real commit necessarily contains this pattern, so a non-match means we
#      can bail immediately without doing the more expensive extraction. This
#      keeps the hot path (every Bash call that isn't a commit) fast.
#   2. Extract each "command"/"cmd" string value and test it on its own, so
#      tool output is never scanned.
# ---------------------------------------------------------------------------

if ! echo "$INPUT" | grep -Eq '"(command|cmd)".*(git|jj).*commit'; then
  exit 0
fi

# Anchored match for a real `git commit` / `jj commit` invocation:
#
#   (^|[;&|`({][[:space:]]*|\$\([[:space:]]*)
#     Start of the command, or immediately after a shell separator (`;`, `&`,
#     `|`, backtick, `(`, `{`) or a `$(` command substitution. Requiring a
#     separator rather than mere whitespace is what rejects `git` appearing
#     inside a quoted argument, e.g. `echo "how to git commit"`.
#
#   (git|jj)
#     The literal command name. The anchor above keeps `foogit`/`git-foo` out.
#
#   ([[:space:]]+-[^[:space:]"]+([[:space:]]+[^-[:space:]"][^[:space:]"]*)?)*
#     Zero or more global-flag blocks: `-flag`, optionally followed by a value
#     that doesn't itself start with `-`. Lets `git -C /repo commit` and
#     `jj -R /repo commit` match while keeping `git log --grep=commit` and
#     `jj log -r commit` out — `log` is not a flag, so the run of flag blocks
#     cannot bridge it to `commit`.
#
#   [[:space:]]+commit
#     The subcommand.
#
#   ([[:space:]";|&)]|$|\\)
#     Terminator: whitespace, quote, separator, end of string, or a JSON
#     backslash escape. Keeps `git commit-tree` from matching.
#
# Adapted from @jasikpark's approach in DrCatHicks/learning-opportunities#15.
COMMIT_RE='(^|[;&|`({][[:space:]]*|\$\([[:space:]]*)(git|jj)([[:space:]]+-[^[:space:]"]+([[:space:]]+[^-[:space:]"][^[:space:]"]*)?)*[[:space:]]+commit([[:space:]";|&)]|$|\\)'

# Pull out every "command"/"cmd" JSON string value. The inner
# ([^"\\]|\\.)* consumes escaped quotes so a value like
# "git commit -m \"msg\"" is captured whole rather than truncated at the
# first inner quote. Testing every extracted value (rather than only the
# first) means we don't depend on tool_input preceding tool_response in the
# payload — a key order the hook contract does not guarantee.
FOUND_COMMIT=0
MATCHED_CMD=""
while IFS= read -r cmd; do
  [[ -z "$cmd" ]] && continue
  # Strip leading whitespace so the `^` anchor still applies to " git commit".
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"
  if echo "$cmd" | grep -Eq "$COMMIT_RE"; then
    FOUND_COMMIT=1
    MATCHED_CMD="$cmd"
    break
  fi
done < <(echo "$INPUT" | grep -oE '"(command|cmd)":"([^"\\]|\\.)*"' | sed -E 's/^"(command|cmd)":"//; s/"$//')

if [[ "$FOUND_COMMIT" -eq 0 ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Extract session_id for rate limiting. It's a top-level UUID — no escaped
# quotes or nesting to worry about, so basic grep/sed is safe.
# ---------------------------------------------------------------------------

SESSION_ID=$(echo "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | sed 's/"session_id":"//;s/"$//')

if [[ -z "$SESSION_ID" ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Identify the commit, if we can.
#
# Everything in this block is best-effort. A colocated Jujutsu repo has a
# real .git directory and answers these queries, but a non-colocated one does
# not, and neither does a repo we can't resolve a working directory for. In
# those cases we fall through with an empty SHA and still nudge — just
# without the extra precision below. Failing closed here would silently
# disable the hook for those users.
# ---------------------------------------------------------------------------

CWD=$(echo "$INPUT" | grep -o '"cwd":"[^"]*"' | head -1 | sed 's/"cwd":"//;s/"$//')
if [[ -z "$CWD" || ! -d "$CWD" ]]; then
  CWD="$PWD"
fi

# The payload's cwd is the session's directory, which is not necessarily where
# the commit landed. `git -C /other/repo commit` and `cd /other/repo &&
# git commit` both target somewhere else, and querying the session directory
# would then read an unrelated repository's HEAD — suppressing a real commit
# because the wrong HEAD looks stale, or nudging with the wrong SHA.
#
# Redirection is read back off the command: an explicit -C (git) or -R (jj)
# wins, since those override the working directory; otherwise a leading `cd`.
# Relative paths resolve against the session cwd. Anything unparseable or
# missing just leaves the session cwd in place.
REPO_DIR="$CWD"
redirect=$(printf '%s' "$MATCHED_CMD" \
  | sed -nE 's/.*[[:space:]]-(C|R)[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+).*/\2/p' | head -1)
if [[ -z "$redirect" ]]; then
  redirect=$(printf '%s' "$MATCHED_CMD" \
    | sed -nE 's/^cd[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+).*/\1/p' | head -1)
fi
if [[ -n "$redirect" ]]; then
  redirect="${redirect%\"}"; redirect="${redirect#\"}"
  redirect="${redirect%\'}"; redirect="${redirect#\'}"
  [[ "$redirect" != /* ]] && redirect="$CWD/$redirect"
  [[ -d "$redirect" ]] && REPO_DIR="$redirect"
fi

SHA=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null) || SHA=""

if [[ -n "$SHA" ]]; then
  # Confirm the commit actually landed. A rejected `git commit` — failing
  # pre-commit hook, nothing staged, empty message — leaves HEAD pointing at
  # the *previous* commit, and nudging about already-finished work is worse
  # than staying quiet. The committer date (%ct, not the author date, which
  # `--amend` preserves) is set when the commit object is written, so a fresh
  # HEAD means the command we just saw succeeded.
  #
  # The window has to be wide, because the hook fires only once the *whole*
  # shell command finishes: `git commit -m x && npm test` can put minutes
  # between the commit being written and this check running, and suppressing
  # that nudge would lose exactly the learning moment the plugin exists for.
  # A rejected commit normally leaves HEAD on work from a previous sitting,
  # which is far older than this window, and the repeated-failure case is
  # caught by the SHA de-dupe below regardless of timing. Erring wide trades
  # a rare spurious nudge for not dropping real ones — the right direction
  # for this plugin.
  COMMIT_TS=$(git -C "$REPO_DIR" log -1 --format=%ct 2>/dev/null) || COMMIT_TS=""
  if [[ -n "$COMMIT_TS" ]] && (( $(date +%s) - COMMIT_TS > 900 )); then
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Session state, both keyed on session ID in $TMPDIR and reset when the
# session ends:
#
#   .state  count of nudges emitted this session, capped at 2
#   .seen   commit SHAs already nudged about
#
# The de-dupe matters because the hook can fire more than once for the same
# commit — a retried tool call, or a command that runs `git commit` inside a
# larger pipeline. Without it a single commit could consume the whole session
# budget. It is skipped when the SHA is unknown, which degrades to the old
# count-only behavior rather than to no rate limiting at all.
# ---------------------------------------------------------------------------

SAFE_ID="${SESSION_ID//[^a-zA-Z0-9_-]/_}"
STATE_FILE="${TMPDIR:-/tmp}/lo_auto_${SAFE_ID}.state"
SEEN_FILE="${TMPDIR:-/tmp}/lo_auto_${SAFE_ID}.seen"

if [[ -n "$SHA" && -f "$SEEN_FILE" ]] && grep -qxF "$SHA" "$SEEN_FILE" 2>/dev/null; then
  exit 0
fi

offers=0
if [[ -f "$STATE_FILE" ]]; then
  offers=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
fi
# A corrupt or truncated state file must not wedge the hook open.
[[ "$offers" =~ ^[0-9]+$ ]] || offers=0

# Stop after 2 offers per session.
if [[ "$offers" -ge 2 ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------
# Grab the commit subject so the nudge names a concrete topic rather than
# making the model guess what was committed. Sanitized for embedding in the
# JSON string below: control characters, double quotes and backslashes
# removed, length capped.
# ---------------------------------------------------------------------------

CONTEXT=""
if [[ -n "$SHA" ]]; then
  SUBJECT=$(git -C "$REPO_DIR" log -1 --pretty=%s 2>/dev/null \
    | tr '[:cntrl:]' ' ' | tr -d '"\\' | cut -c1-120 \
    | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  if [[ -n "$SUBJECT" ]]; then
    CONTEXT=" (${SHA}: ${SUBJECT})"
  else
    CONTEXT=" (${SHA})"
  fi
fi

# Record the emission, then emit. Both writes happen only on the path that
# actually produces a nudge, so a call that exits early above never consumes
# part of the session budget.
[[ -n "$SHA" ]] && echo "$SHA" >> "$SEEN_FILE"
echo $(( offers + 1 )) > "$STATE_FILE"

# ---------------------------------------------------------------------------
# Emit suggestion for Claude via structured JSON. PostToolUse hooks must
# output JSON with hookSpecificOutput on exit 0 to inject context.
# Only $CONTEXT is interpolated, and it is sanitized above.
# ---------------------------------------------------------------------------

cat <<HOOK_JSON
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[learning-opportunities-auto] The user just committed code${CONTEXT}. Per the learning-opportunities skill, consider whether this is a good moment to offer a learning exercise. If the committed work involved new files, schema changes, architectural decisions, refactors, or unfamiliar patterns, ask the user (one short sentence) if they'd like a 10-15 minute exercise. Do not start the exercise until they confirm. If they decline, note it — no more offers this session."}}
HOOK_JSON

exit 0
