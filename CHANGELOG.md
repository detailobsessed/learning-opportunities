# Changelog

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
