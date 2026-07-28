#!/usr/bin/env bash
set -uo pipefail

# learning-opportunities-auto: PostToolUse hook (matches Bash tool)
#
# Fires after every Bash tool use. Checks whether the command was a
# `git commit` and, if so, suggests that Claude offer a learning exercise.
# The skill itself decides whether the commit's content is worth an
# exercise — this hook just provides the nudge at the right moment.
#
# No external dependencies beyond bash and standard Unix tools.

INPUT=$(cat)

# ---------------------------------------------------------------------------
# Check if this was a git commit.
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

if ! echo "$INPUT" | grep -Eq '"(command|cmd)".*git.*commit'; then
  exit 0
fi

# Anchored match for a real `git commit` invocation:
#
#   (^|[;&|`({][[:space:]]*|\$\([[:space:]]*)
#     Start of the command, or immediately after a shell separator (`;`, `&`,
#     `|`, backtick, `(`, `{`) or a `$(` command substitution. Requiring a
#     separator rather than mere whitespace is what rejects `git` appearing
#     inside a quoted argument, e.g. `echo "how to git commit"`.
#
#   git
#     The literal command name. The anchor above keeps `foogit`/`git-foo` out.
#
#   ([[:space:]]+-[^[:space:]"]+([[:space:]]+[^-[:space:]"][^[:space:]"]*)?)*
#     Zero or more global-flag blocks: `-flag`, optionally followed by a value
#     that doesn't itself start with `-`. Lets `git -C /repo commit` match
#     while keeping `git log --grep=commit` out — `log` is not a flag, so the
#     run of flag blocks cannot bridge it to `commit`.
#
#   [[:space:]]+commit
#     The subcommand.
#
#   ([[:space:]";|&)]|$|\\)
#     Terminator: whitespace, quote, separator, end of string, or a JSON
#     backslash escape. Keeps `git commit-tree` from matching.
#
# Adapted from @jasikpark's approach in DrCatHicks/learning-opportunities#15.
COMMIT_RE='(^|[;&|`({][[:space:]]*|\$\([[:space:]]*)git([[:space:]]+-[^[:space:]"]+([[:space:]]+[^-[:space:]"][^[:space:]"]*)?)*[[:space:]]+commit([[:space:]";|&)]|$|\\)'

# Pull out every "command"/"cmd" JSON string value. The inner
# ([^"\\]|\\.)* consumes escaped quotes so a value like
# "git commit -m \"msg\"" is captured whole rather than truncated at the
# first inner quote. Testing every extracted value (rather than only the
# first) means we don't depend on tool_input preceding tool_response in the
# payload — a key order the hook contract does not guarantee.
FOUND_COMMIT=0
while IFS= read -r cmd; do
  [[ -z "$cmd" ]] && continue
  # Strip leading whitespace so the `^` anchor still applies to " git commit".
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"
  if echo "$cmd" | grep -Eq "$COMMIT_RE"; then
    FOUND_COMMIT=1
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
# Session state: track how many exercises have been offered this session.
# Uses a temp file keyed on session ID; resets when the session ends.
# ---------------------------------------------------------------------------

STATE_FILE="${TMPDIR:-/tmp}/lo_auto_${SESSION_ID//[^a-zA-Z0-9_-]/_}.state"

offers=0
if [[ -f "$STATE_FILE" ]]; then
  offers=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
fi

# Stop after 2 offers per session.
if [[ "$offers" -ge 2 ]]; then
  exit 0
fi

# Record the offer.
echo $(( offers + 1 )) > "$STATE_FILE"

# ---------------------------------------------------------------------------
# Emit suggestion for Claude via structured JSON. PostToolUse hooks must
# output JSON with hookSpecificOutput on exit 0 to inject context.
# The message contains no special characters that need escaping.
# ---------------------------------------------------------------------------

cat <<'HOOK_JSON'
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[learning-opportunities-auto] The user just committed code. Per the learning-opportunities skill, consider whether this is a good moment to offer a learning exercise. If the committed work involved new files, schema changes, architectural decisions, refactors, or unfamiliar patterns, ask the user (one short sentence) if they'd like a 10-15 minute exercise. Do not start the exercise until they confirm. If they decline, note it — no more offers this session."}}
HOOK_JSON

exit 0
