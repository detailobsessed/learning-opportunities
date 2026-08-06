#!/usr/bin/env bash
set -uo pipefail

# Regression tests for post-tool-use.sh commit detection.
#
# The hook detects a commit by observing that HEAD moved, not by reading the
# command, so every case here *performs* the thing it is asserting about —
# commits, checkouts, resets are real — and the command text is chosen to be
# irrelevant or actively misleading. A case that only fed text would prove
# nothing about a hook that never reads it.
#
# Each case uses a unique session id so the two-offers-per-session cap never
# masks a result, and each session is baselined before its assertions, since
# the hook cannot attribute a commit that predates the session.
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

pass=0
fail=0

json_escape() {
  # Minimal JSON string escaping for the test payloads: backslash, quote, tab,
  # carriage return, newline.
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
    | awk 'BEGIN{ORS=""} NR>1{print "\\n"} {gsub(/\t/,"\\t"); gsub(/\r/,"\\r"); print}'
}

# new_repo <path> [subject] — a git repo with one commit, ready to observe.
new_repo() {
  git init -q "$1"
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name "Test"
  git -C "$1" config commit.gpgsign false
  echo seed > "$1/file.txt"
  git -C "$1" add file.txt
  git -C "$1" commit -q -m "${2:-seed commit}"
}

# commit_in <repo> <subject> — a real commit, which is the event under test.
commit_in() {
  echo "$RANDOM$RANDOM" > "$1/file.txt"
  git -C "$1" add file.txt
  git -C "$1" commit -q -m "$2"
}

# commit_in_at <repo> <subject> <epoch> — a commit that happened at a stated
# time. The committer date carries the reflog entry's date with it, so this
# moves both, which is what a commit made a while ago actually looks like.
commit_in_at() {
  echo "$RANDOM$RANDOM" > "$1/file.txt"
  git -C "$1" add file.txt
  GIT_COMMITTER_DATE="@$3 +0000" git -C "$1" commit -q --date="@$3 +0000" -m "$2"
}

HOOK_OUT=""
HOOK_STATUS=0
# run_hook <session> <cwd> <command> [tool output]
run_hook() {
  local payload
  payload=$(printf '{"session_id":"%s","cwd":"%s","tool_input":{"command":"%s"},"tool_response":{"output":"%s"}}' \
    "$1" "$(json_escape "$2")" "$(json_escape "$3")" "$(json_escape "${4:-}")")
  HOOK_OUT=$(printf '%s' "$payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null)
  HOOK_STATUS=$?
}

# check <expected: nudge|silent> <description> <session> <cwd> <command> [output]
#
# A crash has to be distinguishable from the intended silence: a hook that dies
# before printing anything emits no additionalContext, and every `silent`
# expectation would pass against a hook that never runs.
check() {
  local expected="$1" desc="$2" actual
  shift 2
  run_hook "$@"
  if (( HOOK_STATUS != 0 )); then
    fail=$((fail + 1))
    printf 'FAIL  hook exited %s: %s\n' "$HOOK_STATUS" "$desc" >&2
    return
  fi
  if grep -q additionalContext <<<"$HOOK_OUT"; then actual="nudge"; else actual="silent"; fi
  if [[ "$actual" == "$expected" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL  expected %-6s got %-6s: %s\n' "$expected" "$actual" "$desc" >&2
  fi
}

# baseline <session> <cwd> — establish the session, asserting it stays quiet.
# The first sighting of a session records the current HEADs as already
# accounted for: a commit sitting at HEAD may have been made a moment ago by
# this very tool call or an hour before the session opened, and the hook has no
# way to tell. hooks.json runs the same script on SessionStart so this lands
# before the first Bash call.
baseline() {
  check silent "baseline fire for $1 must stay quiet" "$1" "$2" "ls"
}

ok() { # ok <condition-result> <description>
  if [[ "$1" == 0 ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL  $2" >&2
  fi
}

REPO="$TEST_TMPDIR/repo"
new_repo "$REPO"

# --- the baseline itself ----------------------------------------------------
baseline s-base "$REPO"
# Nothing committed since, so nothing to report.
check silent "no commit since the baseline" s-base "$REPO" "ls -la"

# --- a commit is detected however it was spelled ----------------------------
# The command text in each of these is irrelevant by construction: the commit
# is real, and what the Bash tool happened to run is either unrelated or
# something no text matcher could have anchored.
baseline s-plain "$REPO"
commit_in "$REPO" "a commit while the command was ls"
check nudge "commit detected with an unrelated command (ls)" s-plain "$REPO" "ls"

# An assignment prefix moves `git` off the start of the command, which is
# exactly where an anchored matcher needs it. This is the shape of every
# `SKIP=... git commit` and `GIT_EDITOR=true git commit --amend`.
baseline s-env "$REPO"
commit_in "$REPO" "a commit behind an env assignment"
check nudge "env-assignment prefix (SKIP=x git commit)" s-env "$REPO" 'SKIP=ruff git commit -m "x"'

baseline s-envbin "$REPO"
commit_in "$REPO" "a commit behind env(1)"
check nudge "env(1) prefix (env git commit)" s-envbin "$REPO" 'env git commit -m "x"'

# An alias or shell function: the text says `git ci`, which is not `git commit`
# in any matcher, and the commit still happened.
baseline s-alias "$REPO"
commit_in "$REPO" "a commit through an alias"
check nudge "alias (git ci)" s-alias "$REPO" 'git ci -m "x"'

# A script that commits somewhere inside itself. No parser reaches this: the
# command text never mentions git at all.
baseline s-script "$REPO"
commit_in "$REPO" "a commit from inside a script"
check nudge "commit made inside ./deploy.sh" s-script "$REPO" './deploy.sh --release'

# --- HEAD moving is not enough: it has to be a new commit -------------------
# `git checkout other-branch` moves HEAD onto a commit that already existed.
# Nudging there would congratulate the user for work they did last week.
co_repo="$TEST_TMPDIR/checkout"
new_repo "$co_repo" "old work"
old_date="@$(( $(date +%s) - 86400 )) +0000"
GIT_COMMITTER_DATE="$old_date" GIT_AUTHOR_DATE="$old_date" \
  git -C "$co_repo" commit -q --allow-empty -m "yesterday's commit"
git -C "$co_repo" branch -q yesterday
git -C "$co_repo" checkout -q --detach HEAD~1 2>/dev/null
baseline s-checkout "$co_repo"
git -C "$co_repo" checkout -q yesterday
check silent "checkout onto a pre-existing commit" s-checkout "$co_repo" 'git checkout yesterday'

# `git reset --hard HEAD~1` likewise lands on an older commit.
rs_repo="$TEST_TMPDIR/reset"
new_repo "$rs_repo"
old2="@$(( $(date +%s) - 86400 )) +0000"
GIT_COMMITTER_DATE="$old2" GIT_AUTHOR_DATE="$old2" \
  git -C "$rs_repo" commit -q --allow-empty -m "older tip"
GIT_COMMITTER_DATE="$old2" GIT_AUTHOR_DATE="$old2" \
  git -C "$rs_repo" commit -q --allow-empty -m "newer tip"
baseline s-reset "$rs_repo"
git -C "$rs_repo" reset -q --hard HEAD~1
check silent "reset --hard onto an older commit" s-reset "$rs_repo" 'git reset --hard HEAD~1'

# The two cases above are separated from a commit by their committer date, but
# the date does not always separate them. A pre-existing commit stamped in the
# same second the session started is not older than the baseline, and one
# stamped in the future never will be. HEAD's reflog says `checkout:` either
# way, which is what makes these silent.
eq_repo="$TEST_TMPDIR/eqsecond"
new_repo "$eq_repo"
now="@$(date +%s) +0000"
git -C "$eq_repo" checkout -q -b sibling
GIT_COMMITTER_DATE="$now" GIT_AUTHOR_DATE="$now" \
  git -C "$eq_repo" commit -q --allow-empty -m "same second as the session"
git -C "$eq_repo" checkout -q -
baseline s-eqsecond "$eq_repo"
printf '%s\n' "$(date +%s)" > "$TEST_TMPDIR/lo_auto_s-eqsecond.base"
git -C "$eq_repo" checkout -q sibling
check silent "checkout onto a commit dated in the session's first second" \
  s-eqsecond "$eq_repo" 'git checkout sibling'

fut_repo="$TEST_TMPDIR/futuredate"
new_repo "$fut_repo"
soon="@$(( $(date +%s) + 86400 )) +0000"
git -C "$fut_repo" checkout -q -b ahead
GIT_COMMITTER_DATE="$soon" GIT_AUTHOR_DATE="$soon" \
  git -C "$fut_repo" commit -q --allow-empty -m "dated tomorrow"
git -C "$fut_repo" checkout -q -
baseline s-future "$fut_repo"
git -C "$fut_repo" checkout -q ahead
check silent "checkout onto a commit dated in the future" \
  s-future "$fut_repo" 'git checkout ahead'

# A fast-forward writes no commit. `git pull` lands somebody else's work, and
# their commit is as fresh as this session, so the date cannot dismiss it —
# only the reflog can. Note the reason git records here: `pull -q --ff-only:
# Fast-forward`, with the typed flags inside it, which is why the match is on
# the ending and not on a `pull:`/`merge:` opener.
ff_remote="$TEST_TMPDIR/ffremote.git"
git init -q --bare "$ff_remote"
ff_them="$TEST_TMPDIR/ffthem"
git clone -q "$ff_remote" "$ff_them" 2>/dev/null
git -C "$ff_them" -c user.email=t@t -c user.name=T commit -q --allow-empty -m "shared base"
git -C "$ff_them" push -q origin HEAD:main 2>/dev/null || git -C "$ff_them" push -q origin HEAD:master
ff_us="$TEST_TMPDIR/ffus"
git clone -q "$ff_remote" "$ff_us" 2>/dev/null
baseline s-ffpull "$ff_us"
git -C "$ff_them" -c user.email=t@t -c user.name=T commit -q --allow-empty -m "a teammate's commit"
git -C "$ff_them" push -q origin HEAD 2>/dev/null
git -C "$ff_us" -c user.email=t@t -c user.name=T pull -q --ff-only >/dev/null 2>&1
check silent "a fast-forward pull is not this session's commit" \
  s-ffpull "$ff_us" 'git pull --ff-only'

# `git merge --ff-only` is the same move under another name.
ff_local="$TEST_TMPDIR/fflocal"
new_repo "$ff_local"
git -C "$ff_local" checkout -q -b ahead
git -C "$ff_local" commit -q --allow-empty -m "work to fast-forward onto"
git -C "$ff_local" checkout -q -
baseline s-ffmerge "$ff_local"
git -C "$ff_local" merge -q --ff-only ahead >/dev/null 2>&1
check silent "a fast-forward merge is not a new commit" \
  s-ffmerge "$ff_local" 'git merge --ff-only ahead'

# Filling an unborn HEAD from a remote is transport too, and git names it
# differently again — `initial pull`, with neither a colon prefix nor the
# `Fast-forward` ending. The baseline recorded no SHA at all here, since there
# was no HEAD to record.
ff_branch=$(git -C "$ff_them" rev-parse --abbrev-ref HEAD)
ip_us="$TEST_TMPDIR/initialpull"
git init -q "$ip_us"
git -C "$ip_us" remote add origin "$ff_remote"
baseline s-initpull "$ip_us"
# The commit has to be newer than the baseline, or the committer date dismisses
# it before the reflog reason is ever consulted and the test proves nothing.
git -C "$ff_them" -c user.email=t@t -c user.name=T commit -q --allow-empty -m "pushed before the pull"
git -C "$ff_them" push -q origin HEAD 2>/dev/null
git -C "$ip_us" -c user.email=t@t -c user.name=T pull -q --ff-only origin "$ff_branch" >/dev/null 2>&1
check silent "a pull into an empty repository is not this session's commit" \
  s-initpull "$ip_us" 'git pull --ff-only'

# A clone as the session's first command is the same thing under another name.
cl_us="$TEST_TMPDIR/clonedin"
baseline s-clone "$TEST_TMPDIR"
git -C "$ff_them" -c user.email=t@t -c user.name=T commit -q --allow-empty -m "pushed before the clone"
git -C "$ff_them" push -q origin HEAD 2>/dev/null
git clone -q "$ff_remote" "$cl_us" 2>/dev/null
check silent "a fresh clone is not this session's commit" \
  s-clone "$cl_us" "git clone $ff_remote"

# But a genuine first commit in a fresh repository is a commit, and git says so
# with `commit (initial)` — it must not be swept up with the above.
fresh="$TEST_TMPDIR/freshinit"
git init -q "$fresh"
baseline s-freshinit "$fresh"
git -C "$fresh" -c user.email=t@t -c user.name=T commit -q --allow-empty -m "the very first commit"
check nudge "the first commit in a new repository is a commit" \
  s-freshinit "$fresh" 'ls'

# And a rebase that picks nothing is a fast-forward wearing a different hat:
# its reflog reason is `rebase (finish)`, the same one a real rebase leaves.
# What separates them is whether a `rebase (pick)` sits below it.
rb_us="$TEST_TMPDIR/rbus"
git clone -q "$ff_remote" "$rb_us" 2>/dev/null
baseline s-ffrebase "$rb_us"
git -C "$ff_them" -c user.email=t@t -c user.name=T commit -q --allow-empty -m "more teammate work"
git -C "$ff_them" push -q origin HEAD 2>/dev/null
git -C "$rb_us" fetch -q origin
git -C "$rb_us" -c user.email=t@t -c user.name=T rebase -q origin/HEAD >/dev/null 2>&1 || \
  git -C "$rb_us" -c user.email=t@t -c user.name=T rebase -q "origin/$(git -C "$rb_us" rev-parse --abbrev-ref HEAD)" >/dev/null 2>&1
check silent "a rebase that picks nothing is a fast-forward" \
  s-ffrebase "$rb_us" 'git rebase origin/main'

# A rebase that does pick something rewrites commits, and those are new.
rb_real="$TEST_TMPDIR/rbreal"
git clone -q "$ff_remote" "$rb_real" 2>/dev/null
git -C "$rb_real" -c user.email=t@t -c user.name=T commit -q --allow-empty -m "my own work"
baseline s-realrebase "$rb_real"
git -C "$ff_them" -c user.email=t@t -c user.name=T commit -q --allow-empty -m "yet more teammate work"
git -C "$ff_them" push -q origin HEAD 2>/dev/null
git -C "$rb_real" fetch -q origin
git -C "$rb_real" -c user.email=t@t -c user.name=T rebase -q origin/HEAD >/dev/null 2>&1
check nudge "a rebase that rewrites a commit is a commit" \
  s-realrebase "$rb_real" 'git rebase origin/main'

# The reflog is only ever used to dismiss. Everything that writes a real commit
# carries its own reason there — a merge is the one most likely to be mistaken
# for a fast-forward — and must still nudge.
mg_repo="$TEST_TMPDIR/merge"
new_repo "$mg_repo"
git -C "$mg_repo" checkout -q -b side
git -C "$mg_repo" commit -q --allow-empty -m "side work"
git -C "$mg_repo" checkout -q -
baseline s-merge "$mg_repo"
git -C "$mg_repo" merge -q --no-ff -m "merge side" side >/dev/null 2>&1
check nudge "a merge commit is a commit" s-merge "$mg_repo" 'git merge --no-ff side'

# A rejected commit — failing pre-commit hook, nothing staged — leaves HEAD
# exactly where it was, so there is nothing new to see.
baseline s-failed "$REPO"
git -C "$REPO" commit -q -m "nothing staged" >/dev/null 2>&1
check silent "rejected commit leaves HEAD unmoved" s-failed "$REPO" 'git commit -m "x"'

# --- command text that mentions commits, with no commit behind it -----------
# These are the false positives the original hook shipped with. Under text
# matching each needed its own rule; here none of them can matter, because the
# text is not consulted. They stay as assertions precisely to hold that line.
baseline s-status "$REPO"
check silent "git status output says 'nothing to commit'" s-status "$REPO" 'git status' 'nothing to commit, working tree clean'
check silent "git log output says 'commit <sha>'" s-status "$REPO" 'git log' 'commit 0a1b2c3d
Author: Someone'
check silent "echo of the words git commit" s-status "$REPO" 'echo "how to git commit"'
check silent "heredoc writing a script that contains a commit" s-status "$REPO" 'cat <<EOF > deploy.sh
git commit -m "in the body"
EOF'
check silent "an unquoted heredoc body with a command substitution" s-status "$REPO" 'cat <<EOF > notes.txt
built at $(git commit -m "x")
EOF'
check silent "a commit on a later line of a multi-line command" s-status "$REPO" 'git add -A
git commit -m "x"'

# --- other repositories, found by hint --------------------------------------
# The command text is still read, but only to *add* repositories to the watch
# list. A hint that is missed or bogus costs at most the extra coverage it
# would have added — the session's own repository is always checked, and a
# repository whose HEAD did not move produces nothing however it got listed.
other="$TEST_TMPDIR/other"
new_repo "$other"
baseline s-dashc "$REPO"
commit_in "$other" "commit in the other repo"
check nudge "commit in a repo named by -C" s-dashc "$REPO" "git -C $other commit -m \"x\""
ok "$(grep -q 'commit in the other repo' <<<"$HOOK_OUT"; echo $?)" \
   "-C hint: nudge should name the other repo's commit"

other2="$TEST_TMPDIR/other2"
new_repo "$other2"
baseline s-cd "$REPO"
commit_in "$other2" "commit after a cd"
check nudge "commit in a repo reached by cd" s-cd "$REPO" "cd $other2 && git commit -m \"x\""

# A relative hint is relative to wherever the shell had got to. Chained, they
# compound: `cd parent && cd child` is `parent/child`, not two siblings of the
# session's directory. The repository is nested inside another one so that
# resolving either step alone lands on the wrong root rather than on nothing.
nest="$TEST_TMPDIR/nest"
new_repo "$nest"
new_repo "$nest/parent/child"
baseline s-chain "$nest"
commit_in "$nest/parent/child" "commit two cds down"
check nudge "commit in a repo reached by chained relative cd" \
  s-chain "$nest" 'cd parent && cd child && git commit -m "x"'
ok "$(grep -q 'commit two cds down' <<<"$HOOK_OUT"; echo $?)" \
   "chained cd: nudge should name the nested repo's commit"

# `..` walks back up the accumulated path, and does so textually, the way the
# shell reads it: `cd link` then `cd ..` returns to the directory holding the
# symlink rather than following it to the parent of its target.
up="$TEST_TMPDIR/up"
new_repo "$up"
new_repo "$up/deep/sibling"
baseline s-updown "$up"
commit_in "$up/deep/sibling" "commit after cd .."
check nudge "commit in a repo reached by cd down then up then across" \
  s-updown "$up" 'cd deep/inner && cd .. && cd sibling && git commit -m "x"'

# A relative -C is relative to the shell's position too, not to where it began.
rel="$TEST_TMPDIR/relc"
new_repo "$rel"
new_repo "$rel/sub/target"
baseline s-relc "$rel"
commit_in "$rel/sub/target" "commit via a relative -C"
check nudge "commit in a repo named by -C relative to an earlier cd" \
  s-relc "$rel" 'cd sub && git -C target commit -m "x"'

# A `--git-dir` names the repository's git directory, which is not a work tree.
# Every hint therefore resolves to a git directory rather than to a work tree,
# and the queries address it with `--git-dir`; resolving the other way round
# meant `git -C <git dir>` on this hint, which fails outright, so the
# repository was never watched and its commit went unreported. The session's
# own directory is deliberately a different repository in each case, so nothing
# here can pass by falling back to it.
gd="$TEST_TMPDIR/gitdirhint"
new_repo "$gd"
baseline s-gitdir "$REPO"
commit_in "$gd" "commit named only by --git-dir"
check nudge "commit in a repo named by --git-dir alone" \
  s-gitdir "$REPO" "git --git-dir=$gd/.git commit -m \"x\""
ok "$(grep -q 'commit named only by --git-dir' <<<"$HOOK_OUT"; echo $?)" \
   "--git-dir hint: nudge should name that repo's commit"

# `--separate-git-dir` puts the git directory outside the work tree entirely and
# leaves a `.git` *file* pointing at it. Both spellings have to work, and the
# file is why the existence test is `-e` rather than `-d`.
sepwt="$TEST_TMPDIR/sepwork"
sepgd="$TEST_TMPDIR/sepgit"
git init -q --separate-git-dir="$sepgd" "$sepwt"
git -C "$sepwt" config user.email test@example.com
git -C "$sepwt" config user.name "Test"
git -C "$sepwt" config commit.gpgsign false
echo seed > "$sepwt/file.txt"
git -C "$sepwt" add file.txt
git -C "$sepwt" commit -q -m "seed commit"

baseline s-sepgd "$REPO"
commit_in "$sepwt" "commit in a separate git directory"
check nudge "commit in a --separate-git-dir repo named by its git directory" \
  s-sepgd "$REPO" "git --git-dir=$sepgd commit -m \"x\""

baseline s-sepfile "$REPO"
commit_in "$sepwt" "commit reached through the .git file"
check nudge "commit in a --separate-git-dir repo named by its .git file" \
  s-sepfile "$REPO" "git --git-dir=$sepwt/.git commit -m \"x\""

# The two spellings of one repository are the same repository, and collapse to
# a single watch entry rather than producing a nudge each.
baseline s-samerepo "$REPO"
commit_in "$gd" "one commit, two spellings"
check nudge "a repo named twice is watched once" \
  s-samerepo "$REPO" "git -C $gd log && git --git-dir=$gd/.git commit -m \"x\""
check silent "the second spelling must not produce a second nudge" \
  s-samerepo "$REPO" "ls"

# Membership in the watch set is bounded on both sides. Entries are stored
# with a newline either side, so `/repo/.git` cannot read as already present
# in a set holding only `/other/repo/.git` — unbounded, the second repository
# was dropped and its commit went unreported. It takes one git directory being
# a literal path suffix of another, which is ordinary enough in life
# (`/repos/app` alongside `/home/u/repos/app`) and is built here by nesting the
# temporary directory inside itself. The longer path is named first, so the
# shorter one is the one at risk of being swallowed.
# Nested with the *resolved* temporary directory, since that is what the hook
# stores: on macOS `$TMPDIR` is under `/var`, a symlink to `/private/var`, and
# nesting the unresolved spelling produces two paths where neither contains
# the other and the case proves nothing.
sfx_real=$(cd "$TEST_TMPDIR" && pwd -P)
sfx_short="$TEST_TMPDIR/sfx/repo"
sfx_long="$TEST_TMPDIR/outer$sfx_real/sfx/repo"
mkdir -p "$(dirname "$sfx_long")"
new_repo "$sfx_short"
new_repo "$sfx_long"
baseline s-suffix "$REPO"
# The longer repository is put beyond suspicion first — an old session and an
# older history — so the nudge under test can only have come from the shorter
# one. Left fresh, its own seed commit is a commit nobody accounted for and it
# answers the assertion by itself, whether or not the shorter repository was
# ever watched.
now=$(date +%s)
echo $(( now - 3600 )) > "$TEST_TMPDIR/lo_auto_s-suffix.base"
commit_in_at "$sfx_long" "the longer repo, long since" $(( now - 7200 ))
commit_in "$sfx_short" "commit in the repo whose path is a suffix"
check nudge "a git dir that is a path suffix of one already watched is still watched" \
  s-suffix "$REPO" "git -C $sfx_long log && git -C $sfx_short commit -m \"x\""
ok "$(grep -q 'commit in the repo whose path is a suffix' <<<"$HOOK_OUT"; echo $?)" \
   "suffix path: the nudge must name the shorter repo's commit"

# The hint is deliberately structure-blind — it does not know what a heredoc
# body or a comment is, and does not need to. Over-collecting is free.
other3="$TEST_TMPDIR/other3"
new_repo "$other3"
baseline s-hint "$REPO"
commit_in "$other3" "commit hinted from inside a heredoc"
check nudge "a path mentioned only inside a heredoc body still gets watched" s-hint "$REPO" "cat <<EOF > notes.txt
remember to cd $other3 later
EOF"

# --- repositories met for the first time ------------------------------------
# A hint adds a repository to the watch list whatever the command was doing
# with it, so a repository can arrive mid-session having never been baselined.
# Its HEAD is then unaccounted for without having moved: only the fact that it
# moved *now* distinguishes a commit from a repository merely being looked at.
#
# The repository is committed to before the session opens, then again while the
# session is running but by something else — the shape of a second agent, or a
# terminal alongside — and only then is it named, by a read-only command.
late="$TEST_TMPDIR/late"
new_repo "$late"
baseline s-late "$REPO"
# The session has been open an hour — long enough for the other repository's
# commit to land inside it. Ten minutes ago is the point: comfortably after
# the session baseline, so the committer date alone says nothing, and just as
# comfortably outside the tool call that has only now named the repository.
now=$(date +%s)
echo $(( now - 3600 )) > "$TEST_TMPDIR/lo_auto_s-late.base"
commit_in_at "$late" "somebody else's commit, mid-session" $(( now - 600 ))
check silent "a repo first seen by a read-only command must not nudge" \
  s-late "$REPO" "git -C $late status"
# And not on the call after, either: having been baselined on sight, its HEAD
# is accounted for and does not become eligible again.
check silent "a repo baselined on sight stays accounted for" \
  s-late "$REPO" "git -C $late log --oneline"

# The other half of the same rule: discovery and commit in one call is the
# ordinary `git -C ../other commit`, and still nudges.
late2="$TEST_TMPDIR/late2"
new_repo "$late2"
baseline s-late2 "$REPO"
commit_in "$late2" "a commit in a repo seen for the first time"
check nudge "a repo first seen by the call that committed in it still nudges" \
  s-late2 "$REPO" "git -C $late2 commit -m \"x\""
ok "$(grep -q 'a commit in a repo seen for the first time' <<<"$HOOK_OUT"; echo $?)" \
   "first-seen repo: nudge should name that repo's commit"

# A repository whose HEAD sits on a commit dated in the future would otherwise
# stay eligible for as long as its clock says, so the window is bounded on both
# sides rather than only below.
ahead="$TEST_TMPDIR/ahead"
new_repo "$ahead"
GIT_COMMITTER_DATE="@$(( $(date +%s) + 86400 )) +0000" \
  git -C "$ahead" commit -q --amend --no-edit --date="@$(( $(date +%s) + 86400 )) +0000"
baseline s-ahead "$REPO"
check silent "a first-seen repo dated in the future must not nudge" \
  s-ahead "$REPO" "git -C $ahead status"

# Colocated Jujutsu writes real git commits to a real .git, so it is observed
# like any other repo. A *non-colocated* jj repo has no .git and is not
# detected — a deliberate regression, documented in the hook header.
baseline s-jj "$REPO"
commit_in "$REPO" "a jj commit, colocated"
check nudge "colocated jj commit" s-jj "$REPO" 'jj commit -m "x"'

# --- context: the nudge names its commit ------------------------------------
baseline s-ctx "$REPO"
commit_in "$REPO" "add the widget schema"
check nudge "context case commits" s-ctx "$REPO" 'ls'
short=$(git -C "$REPO" rev-parse --short HEAD)
ok "$(grep -q "($short: add the widget schema)" <<<"$HOOK_OUT"; echo $?)" \
   "nudge should name the commit as ($short: subject), got: $HOOK_OUT"

# A subject full of quotes and backslashes must not break the JSON envelope.
baseline s-sane "$REPO"
commit_in "$REPO" 'fix "quoted" \ and \\ backslashes'
check nudge "subject with quotes and backslashes" s-sane "$REPO" 'ls'
if command -v jq >/dev/null 2>&1; then
  ok "$(jq -e . >/dev/null 2>&1 <<<"$HOOK_OUT"; echo $?)" "nudge JSON must stay valid: $HOOK_OUT"
else
  pass=$((pass + 1))
fi

# --- de-duplication and the session cap -------------------------------------
baseline s-dedupe "$REPO"
commit_in "$REPO" "committed once"
check nudge "first sighting of a commit" s-dedupe "$REPO" 'ls'
check silent "the same commit seen again" s-dedupe "$REPO" 'ls'

# Each commit is distinct, so this exercises the offer counter rather than the
# de-dupe. Pointing them at one repo would collapse them onto a single SHA and
# the test would pass on the de-dupe path with the counter never involved.
baseline s-cap "$REPO"
cap_nudges=0
for i in 1 2 3 4 5; do
  commit_in "$REPO" "cap commit $i"
  run_hook s-cap "$REPO" "ls"
  grep -q additionalContext <<<"$HOOK_OUT" && cap_nudges=$((cap_nudges + 1))
done
ok "$([[ "$cap_nudges" -eq 2 ]]; echo $?)" "session cap: expected 2 nudges from 5 commits, got $cap_nudges"

# --- concurrency ------------------------------------------------------------
# Tool calls run in parallel, so the read-check-write across the state files is
# genuinely reachable from two processes at once.
conc_repo="$TEST_TMPDIR/conc"
new_repo "$conc_repo"
baseline s-conc "$conc_repo"
commit_in "$conc_repo" "concurrent commit"
conc_payload=$(printf '{"session_id":"s-conc","cwd":"%s","tool_input":{"command":"ls"},"tool_response":{}}' "$conc_repo")
conc_out="$TEST_TMPDIR/concout"; mkdir -p "$conc_out"
for i in 1 2 3 4 5 6; do
  ( printf '%s' "$conc_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null > "$conc_out/$i" ) &
done
wait
conc_nudges=$(grep -l additionalContext "$conc_out"/* 2>/dev/null | wc -l | tr -d ' ')
ok "$([[ "$conc_nudges" -eq 1 ]]; echo $?)" \
   "concurrency: expected 1 nudge from 6 parallel hooks on one commit, got $conc_nudges"

# Bounded on both sides. The lower bound is what a bare `-le 2` misses: losing
# the lock is a silent exit by design, so a regression that made every
# contender lose would show up as zero and still satisfy `-le 2`. An exact
# assertion is not available — how many of six win is genuinely
# timing-dependent, which is the cost of not blocking.
for i in 1 2 3 4 5 6; do
  new_repo "$TEST_TMPDIR/caprepo$i" "cap repo $i"
done
baseline s-conc2 "$TEST_TMPDIR/caprepo1"
for i in 1 2 3 4 5 6; do commit_in "$TEST_TMPDIR/caprepo$i" "parallel commit $i"; done
conc2_out="$TEST_TMPDIR/conc2out"; mkdir -p "$conc2_out"
for i in 1 2 3 4 5 6; do
  p=$(printf '{"session_id":"s-conc2","cwd":"%s","tool_input":{"command":"ls"},"tool_response":{}}' "$TEST_TMPDIR/caprepo$i")
  ( printf '%s' "$p" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" 2>/dev/null > "$conc2_out/$i" ) &
done
wait
conc2_nudges=$(grep -l additionalContext "$conc2_out"/* 2>/dev/null | wc -l | tr -d ' ')
ok "$([[ "$conc2_nudges" -ge 1 && "$conc2_nudges" -le 2 ]]; echo $?)" \
   "concurrency: expected 1-2 nudges from 6 parallel distinct commits, got $conc2_nudges"

# An orphaned lock — left by a process that died before releasing it — must be
# reclaimed rather than wedging the hook shut for the rest of the session.
lock_repo="$TEST_TMPDIR/lockrepo"
new_repo "$lock_repo"
baseline s-lock "$lock_repo"
commit_in "$lock_repo" "after a stale lock"
stale_lock="$TEST_TMPDIR/lo_auto_s-lock.lock"
mkdir -p "$stale_lock"
touch -t 202001010000 "$stale_lock" 2>/dev/null
check nudge "an orphaned lock is reclaimed" s-lock "$lock_repo" 'ls'

# And the lock is released on the early-exit paths, not only the nudging one.
run_hook s-lock "$lock_repo" 'ls'
ok "$([[ ! -d "$TEST_TMPDIR/lo_auto_s-lock.lock" ]]; echo $?)" "lock leaked after an early exit"

# --- robustness -------------------------------------------------------------
check silent "empty tool_input" s-robust "$REPO" ''
run_hook "" "$REPO" 'ls'
ok "$([[ $HOOK_STATUS -eq 0 && -z "$HOOK_OUT" ]]; echo $?)" "missing session_id must exit 0 quietly"

# A corrupt state file must be read as zero, not as "no limit". Asserting that
# one commit still nudges would pass on a hook that re-zeroed the count on every
# fire and nudged forever; three commits and a cap of two is what separates the
# two readings.
echo 'not a number' > "$TEST_TMPDIR/lo_auto_s-corrupt.state"
corrupt_repo="$TEST_TMPDIR/corrupt"
new_repo "$corrupt_repo"
baseline s-corrupt "$corrupt_repo"
corrupt_nudges=0
for i in 1 2 3; do
  commit_in "$corrupt_repo" "after a corrupt state file $i"
  run_hook s-corrupt "$corrupt_repo" 'ls'
  grep -q additionalContext <<< "$HOOK_OUT" && corrupt_nudges=$((corrupt_nudges + 1))
done
ok "$([[ "$corrupt_nudges" -eq 2 ]]; echo $?)" \
   "a corrupt state file must not disable the rate limit: expected 2 nudges from 3 commits, got $corrupt_nudges"

# A directory that is not a repository, with no hints: nothing to observe, so
# nothing is said. This is also where a non-colocated Jujutsu repo lands.
nogit="$TEST_TMPDIR/nogit"; mkdir -p "$nogit"
baseline s-nogit "$nogit"
check silent "a non-repository cwd stays quiet and exits 0" s-nogit "$nogit" 'jj commit -m "x"'

# The hook fires on every Bash call, so a large command must not stall it.
big=$(printf 'a%.0s' $(seq 1 100000))
big_payload=$(printf '{"session_id":"s-big","tool_input":{"command":"echo %s"},"tool_response":{}}' "$big")
start=$(date +%s)
printf '%s' "$big_payload" | TMPDIR="$TEST_TMPDIR" bash "$HOOK" >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
ok "$([[ "$elapsed" -le 5 ]]; echo $?)" "performance: 100KB command took ${elapsed}s"

# --- hooks.json -------------------------------------------------------------
CC_HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hooks.json"
if command -v jq >/dev/null 2>&1; then
  ok "$(jq -e . >/dev/null 2>&1 < "$CC_HOOKS"; echo $?)" "hooks.json is not valid JSON"

  # SessionStart is what puts the baseline in place before the first Bash call.
  # Without it a commit made by the very first tool call cannot be attributed.
  ok "$(jq -e '.hooks.SessionStart[0].hooks[0].command' >/dev/null 2>&1 < "$CC_HOOKS"; echo $?)" \
     "hooks.json must register a SessionStart hook for the baseline"
  cc_post=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$CC_HOOKS")
  cc_start=$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$CC_HOOKS")
  ok "$([[ "$cc_post" == "$cc_start" ]]; echo $?)" \
     "SessionStart and PostToolUse must run the same script"

  # ${CLAUDE_PLUGIN_ROOT} is expanded by Claude Code, but an unquoted expansion
  # word-splits: a plugin under a path with a space runs `bash /Users/John` and
  # exits 127, so the hook never fires and nothing says why. Windows is where
  # this bites — `C:\Users\First Last\` is the ordinary case there.
  spaced="$TEST_TMPDIR/plugin root with spaces"
  mkdir -p "$spaced/hooks"
  printf '#!/usr/bin/env bash\necho CC-HOOK-RAN\n' > "$spaced/hooks/post-tool-use.sh"
  cc_out=$(CLAUDE_PLUGIN_ROOT="$spaced" bash -c "$cc_post" 2>&1)
  ok "$([[ "$cc_out" == "CC-HOOK-RAN" ]]; echo $?)" \
     "Claude Code hook with a space in CLAUDE_PLUGIN_ROOT: got '$cc_out'"

  # An unset CLAUDE_PLUGIN_ROOT must exit quietly. Unquoted it resolved to
  # `bash /hooks/post-tool-use.sh` — exit 127 with a message on every single
  # Bash call, the failure reported upstream as DrCatHicks#18.
  cc_unset=$(env -u CLAUDE_PLUGIN_ROOT bash -c "$cc_post" 2>&1)
  cc_unset_rc=$?
  ok "$([[ $cc_unset_rc -eq 0 && -z "$cc_unset" ]]; echo $?)" \
     "Claude Code hook with CLAUDE_PLUGIN_ROOT unset: rc=$cc_unset_rc out='$cc_unset'"
else
  pass=$((pass + 5))
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
  ok "$(jq -e . >/dev/null 2>&1 < "$CODEX_HOOKS"; echo $?)" "hooks.codex.json is not valid JSON"

  # Runs the real command string out of the config against a fake cache, so the
  # resolution logic is exercised rather than assumed. The rule has to match
  # Codex's own: `local` when that directory exists, otherwise the highest
  # version. Codex loads the plugin config from the directory it considers
  # active, so a hook that picks differently runs a script from another install.
  # Both cases are built so that selecting by modification time picks wrong.
  fake_home="$TEST_TMPDIR/codex"
  fake_base="$fake_home/plugins/cache/learning-opportunities/learning-opportunities-auto"
  for v in 1.0.2 1.10.0 1.9.0; do
    mkdir -p "$fake_base/$v/hooks"
    printf '#!/usr/bin/env bash\necho RESOLVED-%s\n' "$v" > "$fake_base/$v/hooks/post-tool-use.sh"
  done
  codex_cmd=$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$CODEX_HOOKS")

  # Highest version wins — not the newest on disk, and not the lexicographic
  # maximum: 1.0.2 is touched last here, and 1.9.0 sorts above 1.10.0 as text.
  touch "$fake_base/1.0.2"
  resolved=$(CODEX_HOME="$fake_home" bash -c "$codex_cmd" 2>/dev/null)
  ok "$([[ "$resolved" == "RESOLVED-1.10.0" ]]; echo $?)" \
     "Codex hook resolution: expected RESOLVED-1.10.0, got '$resolved'"

  # A local dev install wins over every numbered version, however old. 1.10.0
  # is touched *after* local is written, so any form of recency selection would
  # pick 1.10.0 and this can only pass by preferring local outright.
  mkdir -p "$fake_base/local/hooks"
  printf '#!/usr/bin/env bash\necho RESOLVED-local\n' > "$fake_base/local/hooks/post-tool-use.sh"
  touch "$fake_base/1.10.0/hooks/post-tool-use.sh" "$fake_base/1.10.0"
  resolved=$(CODEX_HOME="$fake_home" bash -c "$codex_cmd" 2>/dev/null)
  ok "$([[ "$resolved" == "RESOLVED-local" ]]; echo $?)" \
     "Codex hook resolution: expected RESOLVED-local, got '$resolved'"

  CODEX_HOME="$TEST_TMPDIR/nonexistent" bash -c "$codex_cmd" >/dev/null 2>&1
  ok "$?" "Codex hook with no cache should exit 0"
else
  pass=$((pass + 4))
fi

# --- the hook must still run under bash 3.2 --------------------------------
# `hooks.json` launches the hook as `bash "$script"`, resolved off PATH, and on
# a stock macOS that is /bin/bash 3.2.57 — Apple never shipped a newer one.
# Bash 4 syntax there is not a graceful degradation but a parse error, so the
# hook would die on every Bash tool call. These run only when an old bash is
# actually present; elsewhere they are counted as passed so the total stays
# stable across machines.
old_bash=""
for candidate in /bin/bash /usr/bin/bash; do
  if [[ -x "$candidate" ]]; then
    v=$("$candidate" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null)
    if [[ -n "$v" && "$v" -lt 4 ]]; then old_bash="$candidate"; break; fi
  fi
done

if [[ -n "$old_bash" ]]; then
  # Syntax first: this is the failure that would take out every tool call.
  if "$old_bash" -n "$HOOK" 2>/dev/null; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL  hook does not parse under $($old_bash --version | head -1)" >&2
  fi

  # Then end to end, because the parser is not the only thing that changed in
  # bash 4: `declare -A` parses fine under 3.2 and only fails at runtime, and
  # expanding an empty array under `set -u` is an error here.
  ob_repo="$TEST_TMPDIR/oldbash"
  new_repo "$ob_repo"
  ob_base=$(printf '{"session_id":"s-oldbash","cwd":"%s","tool_input":{"command":"ls"},"tool_response":{}}' "$ob_repo")
  printf '%s' "$ob_base" | TMPDIR="$TEST_TMPDIR" "$old_bash" "$HOOK" >/dev/null 2>&1
  commit_in "$ob_repo" "committed under old bash"
  ob_out=$(printf '%s' "$ob_base" | TMPDIR="$TEST_TMPDIR" "$old_bash" "$HOOK" 2>/dev/null)
  ob_status=$?
  if (( ob_status == 0 )) && grep -q "committed under old bash" <<<"$ob_out"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL  commit not detected under $old_bash (rc=$ob_status): $ob_out" >&2
  fi

  # Silence is only the right answer if the hook got far enough to be silent,
  # so the exit status is checked alongside the output.
  ob_out=$(printf '%s' "$ob_base" | TMPDIR="$TEST_TMPDIR" "$old_bash" "$HOOK" 2>/dev/null)
  ob_status=$?
  if (( ob_status != 0 )); then
    fail=$((fail + 1))
    echo "FAIL  hook exited $ob_status on a repeat fire under $old_bash" >&2
  elif grep -q additionalContext <<<"$ob_out"; then
    fail=$((fail + 1))
    echo "FAIL  the same commit nudged twice under $old_bash" >&2
  else
    pass=$((pass + 1))
  fi
else
  pass=$((pass + 3))
fi

echo
echo "passed: $pass  failed: $fail"
[[ "$fail" -eq 0 ]]
