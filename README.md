# Learning Opportunities — detailobsessed fork

A fork of [**DrCatHicks/learning-opportunities**](https://github.com/DrCatHicks/learning-opportunities) carrying fixes to the `learning-opportunities-auto` commit hook.

**All credit for the skill itself goes to [Dr. Cat Hicks](https://drcathicks.com)** (and to [Dr. Michael Mullarkey](https://mcmullarkey.github.io/) for `orient`). This fork changes no learning content, no exercises, and no research material — only the hook plumbing that decides *when* an exercise gets offered.

📖 **For what this skill is, the science behind it, exercise types, and the full documentation, read the [upstream README](https://github.com/DrCatHicks/learning-opportunities/blob/main/README.md).** This file only covers what differs here.

---

## Why this fork exists

The `learning-opportunities-auto` hook decides whether you just made a commit by pattern-matching the JSON payload Claude Code hands it. That payload contains the tool's *output* as well as the command that was run, and the two were matched together. The practical result:

```
$ git status
nothing to commit, working tree clean
```

…told the model *"The user just committed code."* Same for `git log`, `git show`, `git reflog`, and any command whose text mentioned a commit. The model was being handed a false statement about what you'd just done, a couple of times per session.

Three contributors hit this independently upstream, across four threads ([#20], [#12], [#9], [#21]), and two of them proposed fixes ([#15], [#19]) that are still open. This fork consolidates that work, adds a regression suite, and repairs several further problems that nobody had filed — most of those surfaced by putting the hook under automated review, which no version of it had been through before. That review is also what showed the pattern-matching approach itself to be the problem, which is what `2.0.0` replaces.

Credit belongs to **[@vosechu](https://github.com/vosechu)** ([#20], [#21]), **[@jasikpark](https://github.com/jasikpark)** ([#12], [#15] — the anchored-match approach here is adapted from theirs), **[@larssn](https://github.com/larssn)** ([#9]), and **[@kmfrick](https://github.com/kmfrick)** ([#19]). Where code was taken directly the commit carries a `Co-authored-by` trailer; the reports and proposals behind the rest are cited in the commit messages and in the hook source.

[#20]: https://github.com/DrCatHicks/learning-opportunities/issues/20
[#12]: https://github.com/DrCatHicks/learning-opportunities/issues/12
[#9]: https://github.com/DrCatHicks/learning-opportunities/pull/9
[#15]: https://github.com/DrCatHicks/learning-opportunities/pull/15
[#19]: https://github.com/DrCatHicks/learning-opportunities/pull/19
[#21]: https://github.com/DrCatHicks/learning-opportunities/pull/21
[#18]: https://github.com/DrCatHicks/learning-opportunities/issues/18

## What's different (`learning-opportunities-auto` 2.0.0)

**The hook no longer reads the command. It observes whether `HEAD` moved.**

`PostToolUse` fires *after* the tool ran, so the question "did you just commit?" has a direct answer that doesn't involve the command text at all: does `HEAD` now point at a commit the hook hasn't already accounted for, that `HEAD`'s reflog doesn't attribute to something other than committing, and whose committer date falls after the session began? The last two clauses are what separate a commit from a `git checkout other-branch`, a `git reset --hard HEAD~1`, or a `git pull` that fast-forwards onto a teammate's work — all of which move `HEAD` onto a commit that already existed. The reflog is only ever consulted to *dismiss*, and only for the reasons git writes when no commit was created (`checkout:`, `reset:`, anything ending in `Fast-forward`, and a `rebase (finish)` with nothing picked below it), so a real merge, a real rebase, a cherry-pick, a revert and an amend all still count; where the reflog is off it says nothing and the date decides alone.

Versions 1.0 through 1.1.2 answered it by matching an anchored `git`/`jj` invocation in the command. Getting that right means reimplementing shell lexing in a text scanner, and that is where twelve rounds of automated review kept finding divergences from `bash`: heredoc bodies aren't commands, comments end commands, backslashes continue them, an unquoted heredoc body still *runs* the command substitutions inside it unless the opener is escaped, `cd` resolves logically rather than physically. One round's fix introduced the next round's false positive. The scanner is now gone, and with it that entire class of defect. The `1.1.x` entries in [CHANGELOG.md](CHANGELOG.md) record what it took to get there.

| | Change |
|---|---|
| **Commits nothing could match** | `SKIP=ruff git commit` and `env git commit` move `git` off the anchor; `git ci` is an alias; `./deploy.sh` and `make release` don't mention git at all. Every one of these is a real commit, and none of them is reachable by matching text. All are detected now |
| **No false positives from text** | `git status`, `git log --grep=commit`, `echo "how to git commit"`, a heredoc writing a script that contains `git commit` — none moves `HEAD`, so none can report a commit. This holds by construction rather than by exclusion rules |
| **Which repo** | `-C`, `-R`, `--git-dir`, `--work-tree`, `cd`, `pushd` are still read, but only as hints that **add** repositories to the watch set. That inverts the failure mode: a missed or wrong hint now costs at most the extra coverage it would have added, where before it redirected the lookup and a real commit went unreported. The session's own repo is always checked, and a repo whose `HEAD` didn't move contributes nothing however it got listed. Relative hints compound the way the shell compounds them — `cd parent && cd child` is `parent/child`, and `..` walks back up that accumulated path textually rather than following a symlink to its target's parent — but because the list is additive, a wrong guess costs nothing and the session's own directory stays in the running alongside it. Hints resolve to a repository's *git directory* rather than its work tree, which is what lets `--git-dir` work as a hint — it names a directory that is not a work tree — and collapses a work tree, its `.git`, a `--separate-git-dir` location and the `.git` file pointing at one into a single entry |
| **Failed commits** | A rejected commit — failing pre-commit hook, nothing staged — leaves `HEAD` where it was, so there is nothing new to report |
| **Pulls and fast-forwards** | `git pull`, `git merge --ff-only`, a rebase that picks nothing, a pull into an empty repo and a fresh `git clone` all move `HEAD` onto commits somebody else wrote, whose dates are as fresh as this session's — so the date can't dismiss them and only the reflog can. Agents pull constantly, which makes this the most frequent way to be told about work you didn't do |
| **Early commits** | A `SessionStart` hook records the baseline before the first Bash call, so a commit made early in a session is still attributable |
| **Offer budget** | Emitted commits are de-duplicated per session, the two-offer cap holds, and a corrupt state file no longer disables the rate limit |
| **Parallel hooks** | Tool calls run in parallel, and the session state was read and written without a lock. Six concurrent hooks on one commit reliably emitted **six** nudges; now one. Locking is `mkdir`-based — `flock` is util-linux and absent on stock macOS |
| **Nudge precision** | The nudge names its commit as `(<sha>: <subject>)`, so the skill has a concrete topic instead of inferring what was committed |
| **Hook never firing** | The Claude Code hook expanded `${CLAUDE_PLUGIN_ROOT}` **unquoted**, so a plugin path containing a space word-split and `bash` exited 127 — the hook never ran and nothing said why. Windows is where this bites, `C:\Users\First Last\` being the ordinary shape there. Reported as [#18], where it's attributed to Claude Code not expanding the variable; it does expand it, and the missing quotes are the actual fault |
| **Codex hook path** | *(unfiled upstream)* The Codex hook resolved its script from a cache path with the plugin version **hardcoded**, so every release silently disabled the hook until that string was bumped in lockstep — and a local dev install was never found at all. The version is now resolved at runtime, matching how Codex picks the active one: a `local` dev install if present, otherwise the highest installed version |

### What this costs

**Non-colocated Jujutsu repositories are no longer detected.** They have no `.git` for these queries to read. Colocated `jj` — the default, and what `jj git init --colocate` produces — writes real commits to a real `.git` and works exactly as before, with the commit named in the nudge ([#12]). Recovering the non-colocated layout would mean shelling out to `jj` and pinning its template syntax, or keeping a text matcher alive for one narrow path; neither is worth reopening the approach this release exists to close.

**A commit made outside the session also nudges.** Detection is now "a commit happened since I last looked" rather than "you typed a commit command", so a commit made in a GUI client between two tool calls counts. The per-session de-duplication and the two-offer cap bound it.

A regression suite lives at [`learning-opportunities-auto/hooks/test-post-tool-use.sh`](learning-opportunities-auto/hooks/test-post-tool-use.sh), with no dependencies beyond bash:

```
./learning-opportunities-auto/hooks/test-post-tool-use.sh
```

Run it against the upstream hook and a large fraction fail. It was rewritten around the new contract: every detection case performs a **real commit** and runs a deliberately unrelated or misleading command, so no case can pass by matching text. It's smaller than the suite it replaces mostly because the shell corners that one enumerated only existed as ways for a scanner to be wrong.

### Design constraints kept

Upstream's hook header promises *"no external dependencies beyond bash and standard Unix tools"*, and an earlier fix attempt ([#21]) was withdrawn for reaching for `jq`. Everything here stays within `grep`/`sed`/`tr` plus `git` itself. The hot path — every Bash call that *isn't* a commit — is now one `git rev-parse HEAD` per watched repository where 1.x ran a grep over the payload; that is the one thing v2 costs at runtime, and it buys the whole class of commits a grep can't see.

**bash 3.2 still runs it.** The hook is launched as `bash "$script"` off `PATH`, and on a stock macOS that resolves to `/bin/bash` 3.2.57 — Apple froze bash there in 2007 and never moved. Bash 4 syntax would not degrade gracefully; it is a parse error, so the hook would die on every Bash tool call. The suite enforces this rather than trusting it: when an old `bash` is present it parse-checks the hook and runs two cases end to end through it. That check earns its place — a `declare -A` injected as a probe **parses** fine under 3.2 and only fails at runtime, so the end-to-end case is what catches it. The one visible concession is the watch list, a newline-delimited string rather than an array, because expanding an empty `${arr[@]}` under `set -u` is an error before bash 4.4.

## Installation

Identical to upstream, but pointed at this fork.

**Claude Code**
```
/plugin marketplace add https://github.com/detailobsessed/learning-opportunities.git
/plugin install learning-opportunities@learning-opportunities
/plugin install learning-opportunities-auto@learning-opportunities
```

**Codex**
```
codex plugin marketplace add https://github.com/detailobsessed/learning-opportunities.git
```

Everything else — the `orient` plugin, Windows setup, exercise types, `MEASURE-THIS.md` — works exactly as upstream documents it.

## Upstreaming

These changes are intended to go back to upstream; the fork is where they get reviewed first. Each fix is a separate branch and a separate PR so they can be taken individually or declined without blocking the others.

## License

Unchanged: [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/), © Dr. Cat Hicks. See [LICENSE](LICENSE).
