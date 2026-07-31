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
#
# A command may be several lines — `git add -A` and `git commit -m "..."` on
# consecutive lines is how agents habitually write one, and a shell script
# passed to the tool arrives the same way. In JSON those line breaks are the
# two-character escape `\n`, so they are decoded to real newlines below and
# every line is then matched on its own.
# ---------------------------------------------------------------------------

if ! echo "$INPUT" | grep -Eq '"(command|cmd)".*(git|jj).*commit'; then
  exit 0
fi

# Anchored match for a real `git commit` / `jj commit` invocation:
#
#   (^[[:space:]]*|[;&|`({][[:space:]]*|\$\([[:space:]]*)
#     Start of a line — grep matches line by line, so with the newlines decoded
#     this covers every line of a multi-line command — or immediately after a
#     shell separator (`;`, `&`, `|`, backtick, `(`, `{`) or a `$(` command
#     substitution. Requiring a separator rather than mere whitespace is what
#     rejects `git` appearing inside a quoted argument, e.g.
#     `echo "how to git commit"`. Leading indentation is skipped, so `git` is
#     still found on an indented line of a script.
#
#   (git|jj)
#     The literal command name. The anchor above keeps `foogit`/`git-foo` out.
#
#   ([[:space:]]+-[^[:space:]"]+("[^"]*"|'[^']*')?([[:space:]]+("[^"]*"|'[^']*'|[^-[:space:]"][^[:space:]"]*))?)*
#     Zero or more global-flag blocks: `-flag`, optionally followed by a value
#     that doesn't itself start with `-`. Lets `git -C /repo commit` and
#     `jj -R /repo commit` match while keeping `git log --grep=commit` and
#     `jj log -r commit` out — `log` is not a flag, so the run of flag blocks
#     cannot bridge it to `commit`.
#
#     A value may be quoted, in both the `--opt "value"` and `--opt="value"`
#     positions, because a path that might contain a space usually is quoted.
#     Without those alternatives the quote terminates the flag block and
#     `git -C "/other repo" commit` is not recognized as a commit at all.
#
#   [[:space:]]+commit
#     The subcommand.
#
#   ([[:space:]";|&)]|$|\\)
#     Terminator: whitespace, quote, separator, end of string, or a JSON
#     backslash escape. Keeps `git commit-tree` from matching.
#
# Adapted from @jasikpark's approach in DrCatHicks/learning-opportunities#15.
COMMIT_RE='(^[[:space:]]*|[;&|`({][[:space:]]*|\$\([[:space:]]*)(git|jj)([[:space:]]+-[^[:space:]"]+("[^"]*"|'"'"'[^'"'"']*'"'"')?([[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^-[:space:]"][^[:space:]"]*))?)*[[:space:]]+commit([[:space:]";|&)]|$|\\)'

# Drop the lines that cannot start a command: heredoc bodies, and lines that
# continue the previous one. Both are text the shell never runs as a command,
# but with the line breaks decoded they start at column zero and would anchor
# exactly like a real invocation.
#
# A line whose predecessor ends in an odd number of backslashes is a
# continuation — `echo preparing to \` then `git commit` passes `git` and
# `commit` to echo. An even count is escaped backslashes, not a continuation.
# Such a line is spliced onto the one above rather than dropped, because the
# joined text is what the shell runs: dropping it would lose the commit in
# `env \` + `git commit -m x`, and a missed nudge is the failure this hook
# exists to prevent. Joined, a continuation behaves exactly like the same
# command written on one line.
#
# The heredoc's opening line is kept, because
# `git commit -m "$(cat <<EOF ... EOF)"` is a real commit that merely takes
# its message from a heredoc.
#
# `<<WORD`, `<<-WORD`, and a quoted `<<"WORD"` / `<<'WORD'` / `<<\WORD` all
# start one, and one line can start several. The terminator is matched as the
# shell matches it: leading tabs stripped after `<<-`, nothing stripped after
# a plain `<<`, and nothing trailing stripped after either.
#
# The delimiter runs to the end of the word, dots and hyphens included:
# capturing only `END` from `<<END-MARKER` means the real terminator never
# matches, the heredoc never closes, and every line after it — including a
# real commit — is swallowed.
#
# Two things are kept out of it. The leading (^|[^<]) rejects a `<<<`
# herestring, whose word is data rather than a delimiter. The trailing
# boundary rejects an arithmetic left-shift, `$((a<<b))`, where `b))` would
# otherwise be read as a delimiter that no later line can match; a real
# delimiter is followed by whitespace, a redirect, a separator, or the end of
# the line. Both mistakes fail the same way — swallowing the rest of the
# command — which is why they are worth excluding by construction.
#
# `<<` inside a quoted string still reads as a heredoc here, so a command that
# prints the text `<<EOF` could suppress a commit on a later line. That
# direction — a missed nudge on a contrived command — is the safe one.
#
# What is deliberately *not* tracked is quoting state across lines. A
# multi-line single-quoted string — `printf '%s' 'notes:` then
# `git commit -m x'` — still reads as a commit. Tracking it properly means
# tracking comments across lines as well, and one `# don't do this` would then
# read as an open quote and suppress a real commit on the next line. (The
# comment handling below is a different thing: it looks at one line at a time
# and only to decide whether a `<<` on it opens a heredoc.) That trades a rare
# spurious offer — already capped at two per session and gated on a fresh
# HEAD — for the silently missed nudge this hook exists to prevent. Wrong
# direction, and declined deliberately when automated review raised it.
# Fold `.` and `..` out of a path textually, which is what the shell means by
# resolving `cd` *logically* — its default. `cd link` then `cd ..` returns to
# the directory holding `link`, not to the parent of whatever `link` points at.
# Joining the raw components instead and handing `…/link/..` to `git -C` lets
# the kernel resolve it physically, through the symlink, and git then reads a
# different repository — the wrong-repo failure this block exists to avoid.
#
# Split by parameter expansion rather than `IFS=/` word splitting, which would
# glob-expand a component containing `*`.
normalize_logical() {
  local path="$1" part out=""
  while [[ -n "$path" ]]; do
    part="${path%%/*}"
    if [[ "$part" == "$path" ]]; then path=""; else path="${path#*/}"; fi
    case "$part" in
      ''|.) ;;
      ..)   out="${out%/*}" ;;
      *)    out="$out/$part" ;;
    esac
  done
  printf '%s' "${out:-/}"
}

# The contents of every command substitution on a line, one per output line.
# An unquoted heredoc body is not inert: the shell expands `$(...)` and
# backticks in it and runs what is inside, so that text is code even though the
# line around it is not. Only the substituted text is returned — the prose
# around it stays out, so a body line reading `then ; git commit` is not
# mistaken for a command while `$(git commit -m x)` is found.
#
# Non-nested, and the inner `)`/backtick wins where they nest. That truncates
# `$(git commit -m "$(date)")` to `git commit -m "$(date`, which still matches;
# a nesting this deep inside a heredoc body is not worth a character-by-
# character scan on every line.
command_substitutions() {
  local s="$1" subs="" inner before_d before_b before esc kind
  while :; do
    before_d="${s%%\$(*}"
    before_b="${s%%\`*}"
    if [[ "$s" == *'$('* ]] && { [[ "$s" != *\`* ]] || (( ${#before_d} < ${#before_b} )); }; then
      kind=dollar; before="$before_d"
    elif [[ "$s" == *\`* ]]; then
      kind=backtick; before="$before_b"
    else
      break
    fi
    # A backslash quotes the opener, so `\$(git commit -m x)` in a body is
    # written out literally and runs nothing. An even run of backslashes is
    # escaped backslashes and the opener still opens. Skipping past a quoted
    # opener rather than stopping keeps a real substitution later on the same
    # line findable.
    esc="${before##*[!\\]}"
    if [[ "$kind" == dollar ]]; then
      s="${s#*\$(}"
      (( ${#esc} % 2 == 1 )) && continue
      inner="${s%%)*}"
      s="${s#*)}"
    else
      s="${s#*\`}"
      (( ${#esc} % 2 == 1 )) && continue
      inner="${s%%\`*}"
      s="${s#*\`}"
    fi
    subs+="$inner"$'\n'
  done
  printf '%s' "$subs"
}

strip_noncommand_lines() {
  local line tail rest head dash delim quoted body scan comment_head dquotes squotes
  local tab=$'\t' squote="'" pending="" continued="" out=""
  local heredoc_re='(^|[^<])<<(-?)[[:space:]]*("|'"'"'|\\)?([A-Za-z_][A-Za-z0-9_.-]*)("|'"'"'|\\)?([[:space:];|&<>]|$)'
  while IFS= read -r line; do
    if [[ -n "$pending" ]]; then
      head="${pending%%$'\n'*}"
      dash="${head%%$tab*}"
      delim="${head##*$tab}"
      quoted="${head#*$tab}"
      quoted="${quoted%%$tab*}"
      # The terminator is matched the way the shell matches it. `<<-` strips
      # leading tabs, and only tabs; a plain `<<` strips nothing; neither
      # strips anything trailing. Accepting a space-indented or
      # trailing-space `EOF` closes the heredoc early, and the body lines
      # below it — `git commit -m x` among them — then read as commands.
      if [[ "$dash" == - ]]; then
        [[ "${line#"${line%%[!$tab]*}"}" == "$delim" ]] && pending="${pending#*$'\n'}"
      else
        [[ "$line" == "$delim" ]] && pending="${pending#*$'\n'}"
      fi
      # A quoted delimiter — `<<'EOF'`, `<<"EOF"`, `<<\EOF` — makes the body
      # literal text and there is nothing in it to run. An unquoted one does
      # not: the shell substitutes commands in the body before writing it out,
      # so a `$(git commit -m x)` there is a commit that really happens. Keep
      # the substituted text alone; the rest of the body stays out.
      if [[ -z "$quoted" ]]; then
        body=$(command_substitutions "$line")
        [[ -n "$body" ]] && out+="$body"
      fi
      continue
    fi
    if [[ -n "$continued" ]]; then
      # Splice onto the previous line, exactly as the shell does: the
      # backslash and the newline both go, and what is left is one command.
      out="${out%$'\n'}"
      out="${out%\\}"
    fi
    out+="$line"$'\n'
    # A `#` that starts a comment ends the command, so `# example: cat <<EOF`
    # opens nothing. Without this the phantom heredoc never closes and every
    # line below it is dropped, including a real commit — the silent miss this
    # hook exists to prevent.
    #
    # This has to come before the continuation check below, not after it. A
    # backslash inside a comment is part of the comment: bash runs
    # `echo done # example \` and the line after it as two separate commands,
    # and splicing them would strip the second line's anchor and lose a commit
    # sitting on it.
    #
    # The `#` has to be unquoted to start a comment, and quoting is only
    # tracked within this one line: the text before the `#` counts as a
    # comment marker when its quotes balance and it ends at a word boundary.
    # `git commit -m "fix #3"` leaves an odd double quote open, so the whole
    # line is used as before. Erring that way costs at most the heredoc
    # handling that was already in place.
    scan="$line"
    comment_head="${line%%#*}"
    if [[ "$comment_head" != "$line" ]]; then
      dquotes="${comment_head//[!\"]/}"
      squotes="${comment_head//[!$squote]/}"
      if (( ${#dquotes} % 2 == 0 && ${#squotes} % 2 == 0 )) \
         && [[ -z "$comment_head" || "$comment_head" == *[[:space:]] ]]; then
        scan="$comment_head"
      fi
    fi
    # The trailing run of backslashes, which is the whole line when the line is
    # nothing but backslashes. An odd count continues the command; an even count
    # is escaped backslashes and ends it. Counted on the pre-comment text for
    # the reason given above.
    tail="${scan##*[!\\]}"
    if (( ${#tail} % 2 == 1 )); then continued=1; else continued=""; fi
    # One line can open several heredocs — `cat <<A; cat <<B`, and also
    # `cat <<FIRST <<SECOND`, whose bodies the shell reads in order however
    # little sense the redirect makes. Queue every opener on the line, in
    # order, rather than only the first.
    rest="$scan"
    while [[ "$rest" =~ $heredoc_re ]]; do
      pending+="${BASH_REMATCH[2]}$tab${BASH_REMATCH[3]}$tab${BASH_REMATCH[4]}"$'\n'
      rest="${rest#*"${BASH_REMATCH[0]}"}"
    done
  done <<< "$1"
  printf '%s' "$out"
}

# Pull out every "command"/"cmd" JSON string value. The inner
# ([^"\\]|\\.)* consumes escaped quotes so a value like
# "git commit -m \"msg\"" is captured whole rather than truncated at the
# first inner quote. Testing every extracted value (rather than only the
# first) means we don't depend on tool_input preceding tool_response in the
# payload — a key order the hook contract does not guarantee.
FOUND_COMMIT=0
MATCHED_CMD=""
PRE_CMD=""
while IFS= read -r cmd; do
  [[ -z "$cmd" ]] && continue
  # The payload is JSON, so the command arrives escaped: a quoted path written
  # `git -C "/other repo" commit` reaches us as `git -C \"/other repo\" commit`.
  # Undo that here, once, so neither the pattern above nor the redirect parsing
  # further down has to reason about backslashes — left escaped, the quotes
  # defeat both, and the hook silently falls back to the session cwd.
  #
  # `\\` is folded to a sentinel first so an escaped backslash sitting right
  # before a quote (`...\\"`) isn't misread as an escaped quote. That also
  # keeps a literal backslash-n in the command — `printf 'a\nb'`, which the
  # payload escapes as `\\n` — from being turned into a line break here.
  #
  # Line breaks and tabs become real characters, because they are separators
  # the pattern has to see: `git add -A\ngit commit -m "..."` is one command
  # with two lines, and left as the two-character `\n` the second line reads
  # as a continuation of the first, where nothing anchors `git`. A `\r` is
  # folded into a newline as well — as a separator the two are equivalent
  # here, and a CRLF payload then splits like any other.
  cmd="${cmd//\\\\/$'\001'}"
  cmd="${cmd//\\\"/\"}"
  cmd="${cmd//\\n/$'\n'}"
  cmd="${cmd//\\r/$'\n'}"
  cmd="${cmd//\\t/$'\t'}"
  cmd="${cmd//$'\001'/\\}"
  cmd=$(strip_noncommand_lines "$cmd")
  match_line=$(echo "$cmd" | grep -nE "$COMMIT_RE" | head -1 | cut -d: -f1)
  if [[ -n "$match_line" ]]; then
    FOUND_COMMIT=1
    # The redirect parsing below reads the options of the commit invocation
    # itself, so it gets that line rather than the whole command: a `-C` or
    # `--git-dir` belonging to some unrelated line of a multi-line script
    # would otherwise send the queries to a different repository.
    MATCHED_CMD=$(echo "$cmd" | sed -n "${match_line}p")
    # Everything up to and including that line, for the `cd` fallback: a
    # directory change only moves the shell for what comes after it, so a `cd`
    # below the commit is irrelevant and must not be read.
    PRE_CMD=$(echo "$cmd" | sed -n "1,${match_line}p")
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

# MATCHED_CMD was JSON-unescaped when it was extracted, so quoting here is
# ordinary shell quoting.
#
# Value of an option in the matched command, accepting either `--opt value` or
# `--opt=value`, and single- or double-quoted values.
opt_value() {
  printf '%s' "$MATCHED_CMD" \
    | sed -nE "s/.*[[:space:]]-{1,2}($1)[=[:space:]][[:space:]]*(\"[^\"]*\"|'[^']*'|[^[:space:]]+).*/\2/p" \
    | head -1
}

# Strip one layer of quoting and resolve a relative path against the session
# cwd, which is where the shell would have resolved it.
unquote() {
  local v="$1"
  v="${v%\"}"; v="${v#\"}"
  v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

# Quote removal plus resolution against the session cwd, which is the right
# base for -C, -R, --git-dir and --work-tree: those take effect wherever the
# shell already is. A chain of `cd`s is the exception and resolves each step
# against the one before it, so that loop unquotes without resolving.
unquote_path() {
  local v
  v=$(unquote "$1")
  [[ -n "$v" && "$v" != /* ]] && v="$CWD/$v"
  printf '%s' "$v"
}

# How to point git at the repository the commit actually landed in.
#
# --git-dir and --work-tree are passed straight through rather than collapsed
# into a single directory: they are independent in an out-of-tree or bare
# layout (`git --git-dir=/srv/meta/project.git --work-tree=/srv/work commit`),
# and keeping only one of them would send the queries below to a directory
# that is not a repository at all. Otherwise the working directory is enough:
# -C (git) and -R (jj) change where the command looks, and a leading cd or
# pushd moves the shell before any of it runs.
#
# GIT_LOC is always non-empty — expanding an empty array under `set -u` is an
# error in the bash 3.2 that ships with macOS.
WORK_TREE=$(unquote_path "$(opt_value 'work-tree')")
GIT_DIR_OPT=$(unquote_path "$(opt_value 'git-dir')")

if [[ -n "$GIT_DIR_OPT" && -e "$GIT_DIR_OPT" ]]; then
  GIT_LOC=(--git-dir "$GIT_DIR_OPT")
  [[ -n "$WORK_TREE" && -d "$WORK_TREE" ]] && GIT_LOC+=(--work-tree "$WORK_TREE")
elif [[ -n "$WORK_TREE" && -d "$WORK_TREE" ]]; then
  GIT_LOC=(-C "$WORK_TREE")
else
  redirect=$(unquote_path "$(opt_value 'C|R')")
  if [[ -z "$redirect" ]]; then
    # This one reads every line up to the commit, not just the commit's own: a
    # `cd` on an earlier line of a multi-line script moves the shell for
    # everything that follows, exactly as `cd /repo && git commit` does on one
    # line. The last one that *could have succeeded* wins — `cd /a`, then
    # `cd /b`, then commit lands in /b — and a `cd` below the commit was
    # excluded from PRE_CMD.
    #
    # Existence is what makes a cd the winner, not position. A cd to a missing
    # directory fails and leaves the shell where it was, so `cd /repo` then
    # `cd /gone` then commit still lands in /repo; taking /gone and then
    # discarding it for not existing would fall back to the session cwd and
    # attribute the commit to a repository it was never made in.
    #
    # Relative arguments compound, so each is resolved against the directory
    # the previous cd established rather than against the session cwd: `cd a`
    # then `cd b` lands in <cwd>/a/b, and testing <cwd>/b instead finds an
    # unrelated directory or none at all. `cd_base` walks forward exactly as
    # the shell's working directory does.
    #
    # This is an approximation either way — a cd inside a branch that never
    # runs still counts here — but one that errs toward the directory the
    # commit most likely landed in.
    cd_base="$REPO_DIR"
    while IFS= read -r cd_arg; do
      cd_arg=$(unquote "$cd_arg")
      [[ -z "$cd_arg" ]] && continue
      case "$cd_arg" in
        /*) cd_candidate=$(normalize_logical "$cd_arg") ;;
        *)  cd_candidate=$(normalize_logical "$cd_base/$cd_arg") ;;
      esac
      if [[ -d "$cd_candidate" ]]; then
        cd_base="$cd_candidate"
        redirect="$cd_candidate"
      fi
    done <<< "$(printf '%s' "$PRE_CMD" \
      | sed -nE 's/^[[:space:]]*(cd|pushd)[[:space:]]+("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+).*/\2/p')"
  fi
  # An unresolvable path leaves the session cwd in place rather than guessing.
  [[ -n "$redirect" && -d "$redirect" ]] && REPO_DIR="$redirect"
  GIT_LOC=(-C "$REPO_DIR")
fi

SHA=$(git "${GIT_LOC[@]}" rev-parse --short HEAD 2>/dev/null) || SHA=""

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
  COMMIT_TS=$(git "${GIT_LOC[@]}" log -1 --format=%ct 2>/dev/null) || COMMIT_TS=""
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
LOCK_DIR="${TMPDIR:-/tmp}/lo_auto_${SAFE_ID}.lock"

# Both files are read, tested, and then written, so concurrent hooks in one
# session would otherwise interleave: two could clear the de-dupe check for
# the same SHA before either records it, and two could read the same offer
# count and each write count+1, losing an increment and overrunning the cap.
# Tool calls do run in parallel, so this is reachable — committing in two
# repositories at once is enough.
#
# mkdir is the lock because it is atomic on POSIX and needs nothing that
# isn't already assumed here. flock would be the conventional choice but is
# util-linux, absent on stock macOS, and this hook ships to both.
#
# Losing the race means staying silent rather than waiting. Contention here
# means another commit in the same session is being handled right now, so at
# worst one nudge is skipped in a situation already near the session cap —
# cheaper than making every commit wait on a lock.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # Reclaim a lock orphaned by a process that died before releasing it,
  # then take one more shot.
  if [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null
  fi
  mkdir "$LOCK_DIR" 2>/dev/null || exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

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
  SUBJECT=$(git "${GIT_LOC[@]}" log -1 --pretty=%s 2>/dev/null \
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
