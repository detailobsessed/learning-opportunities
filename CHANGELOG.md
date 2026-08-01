# Changelog

## learning-opportunities-auto 2.0.0

Commit detection no longer reads the command. It observes whether `HEAD` moved.

**Changed:**
- A commit is detected by its effect rather than by its spelling. `PostToolUse` fires *after* the tool ran, so the hook asks whether `HEAD` now points at a commit it has not already accounted for, that `HEAD`'s reflog does not attribute to something other than committing, and whose committer date falls after the session began — the last two conditions are what separate a commit from a `git checkout other-branch`, a `git reset --hard HEAD~1`, or a `git pull` that fast-forwards onto a teammate's work, all of which move `HEAD` onto a commit that already existed. The reflog is consulted only to dismiss, and only for the reasons git writes when no commit was created: `checkout:`, `reset:`, anything ending in `Fast-forward`, a `rebase (finish)` with nothing picked below it, and the two names git uses when it fills an unborn `HEAD` from a remote — `initial pull` and `clone:`, neither of which carries the `Fast-forward` ending. The `Fast-forward` case is matched on that ending rather than on a `merge`/`pull` opener because the opener carries whatever flags were typed — `pull -q --ff-only: Fast-forward`. A real merge, a real rebase, a cherry-pick, a revert and an amend all still count; where the reflog is off or absent the committer date decides alone. The date cannot decide alone in every case, because it is the user's own clock: a pre-existing commit stamped in the second the session began is not older than the baseline, and one stamped in the future never will be. Neither check is reached on an ordinary tool call, where `HEAD` is already in the session's seen set. The previous approach matched an anchored `git`/`jj` invocation in the command text, which meant reimplementing shell lexing in a text scanner: heredoc bodies are not commands, comments end commands, backslashes continue them, an unquoted heredoc body still runs the command substitutions inside it unless the opener is escaped, and `cd` resolves logically rather than physically. Twelve rounds of automated review found twelve divergences from bash, one of them a false positive introduced by the fix for the round before it. The scanner is gone, and with it that entire class of defect
- Commits that no text matcher could reach are now recognized: `SKIP=ruff git commit` and `env git commit`, where an assignment or an `env` prefix moves `git` off the anchor; `git ci` and other aliases; shell functions; and any script that commits somewhere inside itself, such as `./deploy.sh` or `make release`, whose command text never mentions git at all
- `-C`, `-R`, `--git-dir`, `--work-tree`, `cd` and `pushd` are still read, but only as hints that *add* repositories to the set being watched. That inverts the failure mode: a hint that is missed or wrong now costs at most the extra coverage it would have added, where before it redirected the lookup and a real commit went unreported. The session's own repository is always checked, and a repository whose `HEAD` did not move contributes nothing however it got listed. Relative hints compound the way the shell compounds them: `cd parent && cd child` means `parent/child` rather than two siblings of the session's directory, and `..` walks back up that accumulated path textually — the way the shell reads it — instead of letting git follow a symlink to its target's parent. Both readings of a path are watched where they differ, since being wrong about one costs nothing. A hint resolves to the repository's *git directory* rather than to its work tree, which is what makes `--git-dir` usable as a hint at all — it names a directory that is not a work tree, so asking git to resolve it as one fails and the repository went unwatched. Every query the hook runs reads the git directory alone, and a work tree, its `.git`, a `--separate-git-dir` location and the `.git` file pointing at one all resolve to the same entry, so two spellings of one repository are watched once
- A `SessionStart` hook records the baseline before the first Bash call, so a commit made early in a session is still attributable
- The regression suite was rewritten around the new contract: every detection case now performs a real commit and runs a deliberately unrelated or misleading command, so no case can pass by matching text. It is smaller than the suite it replaces — most of what it dropped was combinatorial shell corners that only existed because the scanner could get that particular shape wrong

**Removed:**
- **Non-colocated Jujutsu repositories are no longer detected.** They have no `.git` for these queries to read. Colocated `jj` — the default, and what `jj git init --colocate` produces — writes real commits to a real `.git` and works exactly as before, with the commit named in the nudge. Recovering the non-colocated layout would mean either shelling out to `jj` and pinning its template syntax, or keeping a text matcher alive for one narrow path; neither is worth reopening the approach this release exists to close

**Note:**
- Because detection is now "a commit happened since I last looked" rather than "you typed a commit command", a commit made outside the session — in a GUI client between two tool calls, say — also produces a nudge. The per-session de-duplication and the two-offer cap bound it

## learning-opportunities-auto 1.1.2

**Fixed:**
- A commit on any line but the first of a multi-line command was not recognized, so nothing was emitted. `git add -A` followed by `git commit -m "…"` on the next line — the shape agents write by habit, and the shape of any script handed to the Bash tool — was silently ignored. The line break arrives as the JSON escape `\n`, which left every later line reading as a continuation of the first, where nothing anchors `git`. Line breaks and tabs are now decoded before matching, and each line is matched on its own. A literal backslash-n in the command is still just text
- A `cd` on an earlier line now redirects the repository lookup the same way `cd /repo && git commit` already did on one line, while `-C`, `-R`, `--git-dir`, and `--work-tree` are read only off the commit's own line — so an unrelated `git -C /elsewhere log` above the commit can no longer send the lookup to the wrong repository. Where several `cd`s precede the commit the last one that could have succeeded wins — a `cd` to a directory that does not exist fails and leaves the shell where it was, so `cd /repo` then `cd /gone` then commit still resolves to `/repo` rather than falling back to the session's working directory — and a `cd` below the commit is ignored, matching what the shell actually does. Relative arguments compound the way the shell compounds them: `cd nest` then `cd inner` resolves to `<cwd>/nest/inner`, where each step used to be resolved against the session's directory and found something unrelated or nothing at all. `.` and `..` are folded the way the shell folds them — logically — so `cd link` then `cd ..` returns to the directory holding the symlink rather than following it to the parent of its target, which is a different repository
- Heredoc bodies are not commands. `cat <<EOF > script.sh` writing a script that contains `git commit`, or a doc that spells it out, reads as text rather than an invocation — without this, recognizing later lines would have made every such heredoc report a commit. The delimiter runs to the end of the word, so `<<END-MARKER` closes on its terminator instead of staying open and swallowing every line after it, and neither a `<<<` herestring nor an arithmetic `$((a<<b))` is mistaken for one. The terminator is matched as the shell matches it — `<<-` strips leading tabs, a plain `<<` strips nothing, and neither strips anything trailing — so a space-indented or trailing-space `EOF` no longer closes the body early and turns the lines below it back into commands. A backslash quotes the delimiter as `<<'EOF'` does, so `<<\EOF` opens a heredoc rather than going unrecognized, and a line opening several — `cat <<A; cat <<B`, or `cat <<FIRST <<SECOND`, whose bodies the shell reads in order however little sense the redirect makes — has every one of them skipped instead of only the first. Only a *quoted* delimiter makes a body inert, though: with a plain `<<EOF` the shell substitutes commands in the body before writing it out, so a `$(git commit -m x)` or a backticked one in there is a commit that really lands. The substituted text is now read as the command it is, and only that text — a `;` in the prose around it is body text, not a command separator, and a backslash quotes the opener, so `\$(git commit -m x)` is written out literally and runs nothing
- A comment is not a redirection. `# example: cat <<EOF` opened a heredoc that never closed, so every line below it — a real `git commit` among them — was dropped as body text and nothing was emitted. The text before an unquoted `#` is now what gets scanned for a heredoc opening, judged one line at a time: a `#` inside an unbalanced quote, as in `git commit -m "fix #3"`, is still text. A backslash inside a comment is comment text and not a line continuation, so `echo done # example \` ends there rather than swallowing the line below it — a `git commit` sitting on that line keeps the line start that anchors it
- A backslash continuation is spliced onto the line above it, as the shell does, rather than read as a line of its own. `echo preparing to \` followed by `git commit` passes `git` and `commit` to `echo` and no longer reports a commit, while `cd /repo && \` followed by `git commit` is recognized — the separator and the invocation only meet once the two are joined

## learning-opportunities-auto 1.1.1

**Fixed:**
- The Claude Code hook expanded `${CLAUDE_PLUGIN_ROOT}` unquoted, so a plugin installed under a path containing a space word-split and the hook never ran — exit 127, with nothing to indicate why. Windows is where this bites, `C:\Users\First Last\` being the ordinary shape there. Reported upstream as [#18](https://github.com/DrCatHicks/learning-opportunities/issues/18), where it was attributed to Claude Code not expanding the variable; it does expand it, and the failure is the missing quotes. An unset `CLAUDE_PLUGIN_ROOT` now exits quietly rather than erroring on every Bash call

## learning-opportunities-auto 1.1.0

Commit detection accuracy, Jujutsu support, and a more precise nudge.

**New:**
- Jujutsu (`jj commit`) is recognized alongside `git commit`. In its default colocated mode `jj` writes real commits to the underlying `.git` directory, and the skill is VCS-agnostic in any case
- The nudge names the commit it refers to, as `(<sha>: <subject>)`, so the skill has a concrete topic instead of inferring what was committed
- Regression test suite at `learning-opportunities-auto/hooks/test-post-tool-use.sh`

**Fixed:**
- Commit detection scanned the entire hook payload, which contains the tool's output as well as its command. `git status` (whose output reads "nothing to commit") and `git log` (whose output reads "commit <sha>") therefore told the model that code had been committed. Detection now reads only the command field, and matches an anchored `git`/`jj` invocation rather than a loose substring
- A commit whose path was quoted — `git -C "/other repo" commit`, the form agents use whenever a path might contain a space — was not recognized as a commit at all, because the payload's JSON escaping was never decoded before matching. Nothing was emitted, silently
- A rejected commit — failing pre-commit hook, nothing staged — left HEAD on the previous commit and nudged about already-finished work. HEAD's committer date is now checked to confirm the commit landed
- Commits landing somewhere other than the session's working directory were checked against the wrong repository, so a real commit could be dropped because an unrelated HEAD looked stale. The target is now read back off the command, covering `-C`, `-R`, `--git-dir`, `--work-tree`, and a leading `cd` or `pushd`. Bare and out-of-tree layouts resolve correctly, where previously no SHA was found and both the freshness check and the de-duplication were skipped
- Repeated hook fires for one commit could consume the whole two-offer session budget; emitted commits are now de-duplicated per session
- Hooks running concurrently in one session read and wrote the shared state without a lock, so a single commit could emit several nudges and the two-offer cap could be overrun. Six parallel hooks on one commit reliably produced six nudges; they now produce one
- A corrupt session state file no longer disables the rate limit
- The Codex hook resolved its script from a cache path with the plugin version hardcoded in it, so every release silently disabled the hook until the string was bumped in lockstep, and a local development install was never found at all. The version is now resolved at runtime, matching how Codex selects the active one: a `local` development install if present, otherwise the highest installed version

## learning-opportunities-auto 1.0.2

**Fixed:**
- Fixed Codex hook execution from repository working directories by resolving the hook script from Codex's plugin cache instead of using a repo-relative path

## orient 1.0.0

Added orient plugin to the learning-opportunities marketplace.

**New:**
- `orient` skill for generating repo-specific orientation files using program comprehension research
- Showboat mode for detailed linear code walkthroughs

## learning-opportunities-auto 1.0.1

**Fixed:**
- Moved hook declaration from inline `plugin.json` format to `hooks/hooks.json`, which is the format Claude Code actually reads at runtime
- Moved `scripts/post-tool-use.sh` to `hooks/post-tool-use.sh` to colocate with hook configuration

## learning-opportunities-auto 1.0.0

Initial release of the automatic hook companion plugin.

**New:**
- `PostToolUse` hook that triggers after `git commit` and nudges Claude to offer a learning exercise when appropriate
- Bash implementation — works on Linux and macOS out of the box; Windows users need to configure `CLAUDE_CODE_GIT_BASH_PATH` (see README)
- Session state tracking: respects the learning-opportunities skill's two-exercise-per-session limit and declined-offer flag

## learning-opportunities 1.0.0

Initial release as a Claude Code plugin.

**New:**
- `learning-opportunities` skill for science-based deliberate practice during AI-assisted coding
- Exercise types: Prediction/Observation/Reflection, Generation/Comparison, Trace the Path, Debug This, Teach It Back, Retrieval Check-in
- Supporting resources: PRINCIPLES.md (learning science foundations), MEASURE-THIS.md (team experiment playbook)
