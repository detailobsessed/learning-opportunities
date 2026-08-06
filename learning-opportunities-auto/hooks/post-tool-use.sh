#!/usr/bin/env bash
set -uo pipefail

# learning-opportunities-auto: PostToolUse hook (matches Bash tool)
#
# Fires after every Bash tool use. Decides whether the user just committed and,
# if so, suggests that Claude offer a learning exercise. The skill itself
# decides whether the commit's content is worth an exercise — this hook just
# provides the nudge at the right moment.
#
# No external dependencies beyond bash and standard Unix tools.
#
# ---------------------------------------------------------------------------
# How this decides a commit happened
#
# It does not read the command. Earlier versions matched an anchored
# `git`/`jj` invocation in the Bash tool's command text, which meant
# reimplementing shell lexing in a text scanner: heredoc bodies are not
# commands, comments end commands, backslashes continue them, unquoted heredoc
# bodies still run their command substitutions unless the opener is escaped,
# and `cd` resolves logically rather than physically. Twelve rounds of review
# found twelve divergences from bash, one of them a false positive introduced
# by the fix for the round before it. The domain is unbounded; the scanner was
# never going to converge.
#
# `PostToolUse` fires *after* the tool ran, so the effect is observable
# directly: ask whether HEAD moved. A commit is a HEAD that
#
#   1. we have not already accounted for this session,
#   2. HEAD's reflog does not say something other than committing put it
#      there, and
#   3. was written during this session, per its committer date.
#
# Conditions 2 and 3 are what separate a commit from a `git checkout
# other-branch`, a `git reset --hard HEAD~1`, or a `git pull` that fast-forwards
# onto somebody else's work — all of which move HEAD to a commit that already
# existed.
#
# Condition 1 assumes the repository was baselined. `SessionStart` baselines the
# session's own; a repository named by a hint arrives later and, unbaselined,
# has a HEAD that is unaccounted for without having moved at all — a read-only
# `git -C ../other status` is enough to put one on the list. So the same script
# also runs on `PreToolUse`, where the command has not run yet and HEAD is
# therefore where the command found it, and records the ones it is meeting for
# the first time. A repository that reaches `PostToolUse` still unmet was not
# baselined by either, and is recorded rather than reported.
#
# The reflog is consulted only to dismiss, and only for the reasons git writes
# when no commit was created: `checkout:`, `reset:`, anything ending in
# `Fast-forward`, and a `rebase (finish)` with nothing picked below it. A
# merge that actually merges, a rebase that actually rewrites, a cherry-pick,
# a revert and an amend all write real commits and carry their own reasons.
# Where the reflog is off or absent it says nothing and the date decides alone,
# which is what it did before condition 2 existed.
#
# The date is %ct rather than the author date, which `--amend` and `rebase`
# preserve. It is the user's own clock and so cannot be the whole answer —
# a pre-existing commit stamped in the second the session began is not older
# than the baseline, and one stamped in the future never will be. Condition 2
# is what covers both.
#
# Neither condition is reached on an ordinary tool call: HEAD is already in the
# seen set by then, and condition 1 exits first.
#
# What this buys beyond ending the scanner bugs: every commit no parser could
# reach now counts. `SKIP=ruff git commit` and `env git commit` (an assignment
# or `env` prefix moved `git` off the anchor), `git ci` and other aliases,
# shell functions, and any script that commits somewhere inside itself —
# `./deploy.sh`, `make release`, a pre-push hook.
#
# What it costs, in three parts.
#
# One `git rev-parse` per Bash tool call in place of a grep.
#
# The semantics shift from "you typed a commit command" to "a commit happened
# since I last looked", so a commit made in a GUI client between two tool calls
# now nudges too. The per-session de-duplication and the two-offer cap bound
# that, and it is arguably the more useful reading anyway.
#
# And a genuine regression: a *non-colocated* Jujutsu repo has no .git for
# these queries to read, so it is no longer detected. Colocated `jj` — the
# default, and what `jj git init --colocate` produces — writes real commits to
# a real .git and works exactly as before, with the commit named in the nudge.
# Only the non-colocated layout is dropped, deliberately: recovering it means
# either shelling out to `jj` and pinning its template syntax, or keeping a
# text matcher alive for one narrow path, and neither is worth reopening the
# approach this rewrite exists to close.
# ---------------------------------------------------------------------------

INPUT=$(cat)

# ---------------------------------------------------------------------------
# Session identity and working directory. Both are top-level JSON strings with
# no escaped quotes or nesting, so basic grep/sed is safe.
# ---------------------------------------------------------------------------

SESSION_ID=$(echo "$INPUT" | grep -o '"session_id":"[^"]*"' | head -1 | sed 's/"session_id":"//;s/"$//')
[[ -z "$SESSION_ID" ]] && exit 0

CWD=$(echo "$INPUT" | grep -o '"cwd":"[^"]*"' | head -1 | sed 's/"cwd":"//;s/"$//')
if [[ -z "$CWD" || ! -d "$CWD" ]]; then
  CWD="$PWD"
fi

EVENT=$(echo "$INPUT" | grep -o '"hook_event_name":"[^"]*"' | head -1 | sed 's/"hook_event_name":"//;s/"$//')

# ---------------------------------------------------------------------------
# Session state, all keyed on session ID in $TMPDIR and reset when the session
# ends:
#
#   .base    epoch second the session was first seen; a commit older than this
#            predates the session and is not ours to nudge about
#   .seen    commit SHAs already accounted for, including the baseline HEADs
#   .watched git directories already under observation; one not listed here is
#            being seen for the first time and has never been baselined
#   .state   count of nudges emitted this session, capped at 2
# ---------------------------------------------------------------------------

SAFE_ID="${SESSION_ID//[^a-zA-Z0-9_-]/_}"
BASE_FILE="${TMPDIR:-/tmp}/lo_auto_${SAFE_ID}.base"
SEEN_FILE="${TMPDIR:-/tmp}/lo_auto_${SAFE_ID}.seen"
WATCHED_FILE="${TMPDIR:-/tmp}/lo_auto_${SAFE_ID}.watched"
STATE_FILE="${TMPDIR:-/tmp}/lo_auto_${SAFE_ID}.state"
LOCK_DIR="${TMPDIR:-/tmp}/lo_auto_${SAFE_ID}.lock"

# ---------------------------------------------------------------------------
# Which repositories to look at.
#
# The session's working directory is the one that matters in nearly every
# case, and it is the only one we can know without reading the command.
#
# The command text is still consulted, but only as a *hint* and only to add
# repositories to the list — never to decide whether a commit happened. That
# inverts the old failure mode. Under the scanner a misread `cd` sent the
# lookup to the wrong repository and a real commit went unreported; here a
# missed or bogus hint costs at most the extra coverage it would have added,
# because the session's own repository is always checked, and a repository
# whose HEAD did not move produces nothing regardless of how it got on the
# list. So the hint deliberately ignores shell structure: it takes every
# `-C`, `-R`, `--git-dir`, `--work-tree`, `cd` and `pushd` argument anywhere in
# the text, including inside heredoc bodies and comments, in any order.
# ---------------------------------------------------------------------------

# A hint is resolved to the repository's *git directory*, not to its work tree,
# and every query below addresses its repository with `--git-dir`. A
# `--git-dir` hint names that directory itself, which is not a work tree, so
# `git -C` on it fails outright for every query and the repository would never
# be watched. Resolving this way round accepts either spelling: a work tree, a
# `.git` directory, a `--separate-git-dir` location, and the `.git` *file* that
# points at one all report the same absolute git directory, which also collapses
# two spellings of one repository into a single watch entry. Nothing is lost by
# dropping the work tree, because every query the hook runs — HEAD, its reflog,
# its committer date, its subject — reads the git directory alone.
repo_gitdir() {
  git -C "$1" rev-parse --absolute-git-dir 2>/dev/null \
    || git --git-dir="$1" rev-parse --absolute-git-dir 2>/dev/null
}

# Newline-delimited, and newline-*prefixed* so that every entry is bounded on
# both sides. Without the leading newline the first entry has no left boundary
# and `/repo/.git` reads as already present in a set holding only
# `/other/repo/.git`, which would drop the second repository from the watch.
# The readers below skip empty lines, so the extra leading newline costs
# nothing.
WATCH=$'\n'
add_watch() {
  local gitdir
  # `-e` rather than `-d`: a repository with a separate git directory has a
  # `.git` *file*, and that is a valid `--git-dir` argument.
  [[ -e "$1" ]] || return 0
  gitdir=$(repo_gitdir "$1") || return 0
  [[ -z "$gitdir" ]] && return 0
  case "$WATCH" in
    *$'\n'"$gitdir"$'\n'*) ;;
    *) WATCH+="$gitdir"$'\n' ;;
  esac
}

add_watch "$CWD"

# The payload is JSON, so a quoted path arrives escaped: `git -C "/other repo"`
# reaches us as `git -C \"/other repo\"`. Undo that much, then pull the
# arguments out. `\\` folds to a sentinel first so an escaped backslash before
# a quote is not misread as an escaped quote.
RAW=$(echo "$INPUT" | grep -oE '"(command|cmd)":"([^"\\]|\\.)*"' | sed -E 's/^"(command|cmd)":"//; s/"$//')
if [[ -n "$RAW" ]]; then
  RAW="${RAW//\\\\/$'\001'}"
  RAW="${RAW//\\\"/\"}"
  RAW="${RAW//\\n/$'\n'}"
  RAW="${RAW//\\r/$'\n'}"
  RAW="${RAW//\\t/$'\t'}"
  RAW="${RAW//$'\001'/\\}"
  # A relative hint is relative to wherever the shell had got to, not to where
  # it started, so `cd parent && cd child` means `parent/child`. LOGICAL tracks
  # that as the cd/pushd hints go by. It is a guess — a `cd` may have failed, or
  # sat in a branch that never ran — but a wrong guess only adds a directory
  # that is not a repository or whose HEAD did not move, and both cost nothing.
  # The session's CWD stays in the running too, for the same reason.
  LOGICAL="$CWD"
  while IFS= read -r hint; do
    [[ -z "$hint" ]] && continue
    # Keep the keyword: only cd/pushd move the shell, the flags do not.
    kind=$(printf '%s' "$hint" | sed -E 's/^[^-a-zA-Z]*(-C|-R|--git-dir|--work-tree|cd|pushd).*/\1/')
    # Strip the flag or keyword and the separator, then one layer of quoting.
    hint=$(printf '%s' "$hint" | sed -E 's/^[^-a-zA-Z]*(-C|-R|--git-dir|--work-tree|cd|pushd)[[:space:]=]+//')
    hint="${hint%\"}"; hint="${hint#\"}"
    hint="${hint%\'}"; hint="${hint#\'}"
    [[ -z "$hint" ]] && continue
    case "$hint" in
      /*)
        add_watch "$hint"
        [[ "$kind" == cd || "$kind" == pushd ]] && LOGICAL="$hint"
        ;;
      *)
        add_watch "$LOGICAL/$hint"
        add_watch "$CWD/$hint"
        # `..` off the accumulated path textually, which is how the shell reads
        # it: `cd link` then `cd ..` returns to the directory holding the
        # symlink, where letting git resolve `link/..` lands at the parent of
        # its target instead. Both are watched; only one of them can be right,
        # and neither is expensive to be wrong about.
        [[ "$hint" == ".." ]] && add_watch "${LOGICAL%/*}"
        if [[ "$kind" == cd || "$kind" == pushd ]]; then
          case "$hint" in
            .)  ;;
            ..) LOGICAL="${LOGICAL%/*}" ;;
            *)  LOGICAL="$LOGICAL/$hint" ;;
          esac
        fi
        ;;
    esac
  done < <(printf '%s' "$RAW" | grep -oE '(^|[^[:alnum:]_./-])(-C|-R|--git-dir|--work-tree|cd|pushd)[[:space:]=]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:];&|"]+)')
fi

# ---------------------------------------------------------------------------
# Baseline. The first time we see a session, every watched HEAD is recorded as
# already accounted for and the clock starts. Nothing is emitted: we cannot
# tell whether a commit sitting at HEAD was made a moment ago by this very tool
# call or an hour ago before the session opened.
#
# `hooks.json` also runs this on SessionStart precisely so the baseline is in
# place before the first Bash call, which closes that gap for the ordinary
# case of committing early in a session.
# ---------------------------------------------------------------------------

record_heads() {
  local gitdir sha
  while IFS= read -r gitdir; do
    [[ -z "$gitdir" ]] && continue
    sha=$(git --git-dir="$gitdir" rev-parse HEAD 2>/dev/null) || continue
    [[ -n "$sha" ]] && echo "$sha" >> "$SEEN_FILE"
  done <<< "$WATCH"
}

# Which of the watched repositories this session has not met before. Computed
# before the set is written back, since writing makes them all old.
NEW_REPOS=$'\n'
collect_new_repos() {
  local gitdir
  while IFS= read -r gitdir; do
    [[ -z "$gitdir" ]] && continue
    grep -qxF "$gitdir" "$WATCHED_FILE" 2>/dev/null && continue
    case "$NEW_REPOS" in
      *$'\n'"$gitdir"$'\n'*) ;;
      *) NEW_REPOS+="$gitdir"$'\n'; echo "$gitdir" >> "$WATCHED_FILE" ;;
    esac
  done <<< "$WATCH"
}

if [[ ! -f "$BASE_FILE" ]]; then
  date +%s > "$BASE_FILE"
  record_heads
  collect_new_repos
  exit 0
fi

# SessionStart has no tool to follow, so once the baseline exists there is
# nothing more for it to do.
[[ "$EVENT" == SessionStart ]] && exit 0

# ---------------------------------------------------------------------------
# PreToolUse: baseline what the command is about to touch.
#
# `SessionStart` covers the repositories that existed on the watch list when
# the session opened, which is the session's own and nothing else. A hint adds
# repositories as the session goes, and a repository added that way has never
# been baselined: whatever sits at its HEAD arrives unaccounted for without
# having moved at all, and no amount of looking at it afterwards can separate
# "this call committed here" from "this is where it already was".
#
# Running the same hints before the command settles that, because at this point
# the command has not run: HEAD is where the command found it. Recording it
# here is what makes the PostToolUse question — did HEAD move? — answerable for
# a repository the session is meeting for the first time.
#
# Only the newly met ones are recorded. A repository already being watched
# keeps whatever the session knows about it, so a commit made between two tool
# calls — in a GUI client, or by another agent — is still a HEAD that moved
# while we were watching, and still reported.
#
# Nothing is written to stdout on this path. A PreToolUse hook's output is how
# a host is told to block a tool call, and this hook has no opinion about that.
# ---------------------------------------------------------------------------

record_new_heads() {
  local gitdir sha
  while IFS= read -r gitdir; do
    [[ -z "$gitdir" ]] && continue
    sha=$(git --git-dir="$gitdir" rev-parse HEAD 2>/dev/null) || continue
    [[ -n "$sha" ]] && echo "$sha" >> "$SEEN_FILE"
  done <<< "$NEW_REPOS"
}

if [[ "$EVENT" == PreToolUse ]]; then
  collect_new_repos
  record_new_heads
  exit 0
fi

collect_new_repos

BASE_TS=$(cat "$BASE_FILE" 2>/dev/null || echo "")
[[ "$BASE_TS" =~ ^[0-9]+$ ]] || BASE_TS=0

# ---------------------------------------------------------------------------
# Look for a HEAD that moved.
#
# Everything here is best-effort. A non-colocated Jujutsu repo has no .git to
# answer these queries and a bare or out-of-tree layout may not resolve; those
# simply contribute nothing rather than failing the hook.
# ---------------------------------------------------------------------------

SHA=""
GITDIR=""
while IFS= read -r gitdir; do
  [[ -z "$gitdir" ]] && continue
  candidate=$(git --git-dir="$gitdir" rev-parse HEAD 2>/dev/null) || continue
  [[ -z "$candidate" ]] && continue
  # Already accounted for: either a baseline HEAD, or one we have nudged about.
  if [[ -f "$SEEN_FILE" ]] && grep -qxF "$candidate" "$SEEN_FILE" 2>/dev/null; then
    continue
  fi
  # A repository still being met for the first time *here* is one PreToolUse
  # did not baseline — the host does not run that event, or the hook was added
  # to a session already in progress. Nothing about its HEAD is evidence of
  # anything: it has not been observed to move, only found somewhere, and a
  # commit made in it minutes ago by another agent looks exactly like one made
  # by the call that just ran. It is recorded and passed over.
  #
  # What that costs, where PreToolUse is missing, is a commit in a repository
  # the session had never touched until the call that committed in it. The
  # call after that one is detected normally. A missed nudge is the safe
  # direction; announcing a commit the user did not make is the bug this hook
  # exists to avoid.
  case "$NEW_REPOS" in
    *$'\n'"$gitdir"$'\n'*)
      echo "$candidate" >> "$SEEN_FILE"
      continue
      ;;
  esac
  # New to us, but is it new at all? `git checkout other-branch` and
  # `git reset --hard HEAD~1` both move HEAD onto a commit that already
  # existed, and neither is something to congratulate the user for.
  #
  # HEAD's reflog says what moved it, and says so whatever the dates involved.
  # Only `checkout:` and `reset:` are dismissed on that basis: a merge, a
  # rebase, a cherry-pick, a revert and an amend all write real commits and
  # carry their own reasons. Where the reflog is off or absent this is empty
  # and the committer date decides alone, as it did before.
  reason=$(git --git-dir="$gitdir" reflog show -1 --format=%gs HEAD 2>/dev/null) || reason=""
  case "$reason" in
    checkout:*|reset:*) continue ;;
    # A fast-forward writes no commit — it moves HEAD onto commits that were
    # already fetched, usually somebody else's. Matched on the `Fast-forward`
    # ending rather than on `merge`/`pull` openers, because the opener carries
    # whatever flags were typed: `pull -q --ff-only: Fast-forward`.
    *": Fast-forward") continue ;;
    # Filling an unborn HEAD from a remote is transport, not authorship, and
    # git names it differently again. Surveyed rather than guessed: of the four
    # ways an empty repository gets its first commit from elsewhere, `git
    # fetch && git checkout` and `git fetch && git reset` say `checkout:` and
    # `reset:` and are already covered; `git pull` into an empty repository
    # says `initial pull`, with no colon and no `Fast-forward`; and a `git
    # clone` run as a session's first command says `clone: from <url>`. A real
    # first commit is `commit (initial): <subject>` and is untouched by these.
    "initial pull"|clone:*) continue ;;
    # A rebase that picked nothing is a fast-forward wearing a different hat.
    # A real one leaves a `rebase (pick)` — or (continue), (squash), (fixup),
    # (reword) — between start and finish; a fast-forward has start directly
    # below finish.
    "rebase (finish)"*)
      prev=$(git --git-dir="$gitdir" reflog show -2 --format=%gs HEAD 2>/dev/null | tail -1)
      case "$prev" in "rebase (start)"*) continue ;; esac
      ;;
  esac
  # And the committer date, for repositories with no reflog to consult. `%ct`
  # rather than the author date, which `--amend` and `rebase` preserve.
  #
  # This is the user's own clock and the user can set it: a commit written with
  # GIT_COMMITTER_DATE backdated before the session began is not recognized as
  # one. That is deliberate. There is no unspoofable timestamp here — reflog
  # entries take their date from the same committer ident — and the failure is
  # a missed nudge on a commit whose date says it predates the session, which
  # is the safer direction to fail in.
  ts=$(git --git-dir="$gitdir" log -1 --format=%ct 2>/dev/null) || ts=""
  [[ "$ts" =~ ^[0-9]+$ ]] || continue
  (( ts < BASE_TS )) && continue
  SHA="$candidate"
  GITDIR="$gitdir"
  break
done <<< "$WATCH"

[[ -z "$SHA" ]] && exit 0

# ---------------------------------------------------------------------------
# Rate limiting and de-duplication.
#
# The state is read, tested, and then written, so concurrent hooks in one
# session would otherwise interleave: two could clear the de-dupe check for the
# same SHA before either records it, and two could read the same offer count
# and each write count+1, losing an increment and overrunning the cap. Tool
# calls do run in parallel, so this is reachable — committing in two
# repositories at once is enough.
#
# mkdir is the lock because it is atomic on POSIX and needs nothing that isn't
# already assumed here. flock would be the conventional choice but is
# util-linux, absent on stock macOS, and this hook ships to both.
#
# Losing the race means staying silent rather than waiting. Contention means
# another commit in the same session is being handled right now, so at worst
# one nudge is skipped in a situation already near the session cap — cheaper
# than making every commit wait on a lock.
# ---------------------------------------------------------------------------

if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # Reclaim a lock orphaned by a process that died before releasing it, then
  # take one more shot.
  if [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null
  fi
  mkdir "$LOCK_DIR" 2>/dev/null || exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

# Re-check under the lock: another hook may have claimed this SHA between the
# scan above and here.
if [[ -f "$SEEN_FILE" ]] && grep -qxF "$SHA" "$SEEN_FILE" 2>/dev/null; then
  exit 0
fi

offers=0
if [[ -f "$STATE_FILE" ]]; then
  offers=$(cat "$STATE_FILE" 2>/dev/null || echo 0)
fi
# A corrupt or truncated state file must not wedge the hook open.
[[ "$offers" =~ ^[0-9]+$ ]] || offers=0

# Stop after 2 offers per session. The SHA is still recorded, so a commit that
# arrives over the cap is not re-examined on every subsequent tool call.
if [[ "$offers" -ge 2 ]]; then
  echo "$SHA" >> "$SEEN_FILE"
  exit 0
fi

# ---------------------------------------------------------------------------
# Grab the commit subject so the nudge names a concrete topic rather than
# making the model guess what was committed. Sanitized for embedding in the
# JSON string below: control characters, double quotes and backslashes
# removed, length capped.
# ---------------------------------------------------------------------------

SHORT=$(git --git-dir="$GITDIR" rev-parse --short "$SHA" 2>/dev/null) || SHORT=""
[[ -z "$SHORT" ]] && SHORT="${SHA:0:7}"

SUBJECT=$(git --git-dir="$GITDIR" log -1 --pretty=%s "$SHA" 2>/dev/null \
  | tr '[:cntrl:]' ' ' | tr -d '"\\' | cut -c1-120 \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
if [[ -n "$SUBJECT" ]]; then
  CONTEXT=" (${SHORT}: ${SUBJECT})"
else
  CONTEXT=" (${SHORT})"
fi

# Record the emission, then emit. Both writes happen only on the path that
# actually produces a nudge, so a call that exits early above never consumes
# part of the session budget.
echo "$SHA" >> "$SEEN_FILE"
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
