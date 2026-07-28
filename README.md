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

Three contributors hit this independently upstream, across four threads ([#20], [#12], [#9], [#21]), and two of them proposed fixes ([#15], [#19]) that are still open. This fork consolidates that work, adds a regression suite, and repairs several further problems that nobody had filed — most of those surfaced by putting the hook under automated review, which no version of it had been through before.

Credit belongs to **[@vosechu](https://github.com/vosechu)** ([#20], [#21]), **[@jasikpark](https://github.com/jasikpark)** ([#12], [#15] — the anchored-match approach here is adapted from theirs), **[@larssn](https://github.com/larssn)** ([#9]), and **[@kmfrick](https://github.com/kmfrick)** ([#19]). Where code was taken directly the commit carries a `Co-authored-by` trailer; the reports and proposals behind the rest are cited in the commit messages and in the hook source.

[#20]: https://github.com/DrCatHicks/learning-opportunities/issues/20
[#12]: https://github.com/DrCatHicks/learning-opportunities/issues/12
[#9]: https://github.com/DrCatHicks/learning-opportunities/pull/9
[#15]: https://github.com/DrCatHicks/learning-opportunities/pull/15
[#19]: https://github.com/DrCatHicks/learning-opportunities/pull/19
[#21]: https://github.com/DrCatHicks/learning-opportunities/pull/21

## What's fixed (`learning-opportunities-auto` 1.1.0)

| | Change |
|---|---|
| **Commit detection** | Reads only the command field, never the tool's output, and matches an anchored `git`/`jj` invocation instead of a loose substring. `git status`, `git log --grep=commit`, and `echo "how to git commit"` no longer report a commit |
| **Quoted paths** | *(unfiled upstream)* `git -C "/other repo" commit` — the form agents use whenever a path might contain a space — was not recognized as a commit **at all**. The payload is JSON, so the quotes arrive escaped, and the escaping was never decoded before matching. Nothing was emitted, silently |
| **Jujutsu support** | `jj commit` is recognized alongside `git commit` ([#12]). Colocated `jj` writes real git commits, and the skill is VCS-agnostic anyway |
| **Failed commits** | A rejected commit — failing pre-commit hook, nothing staged — left `HEAD` on the *previous* commit and nudged about already-finished work. `HEAD`'s committer date now confirms the commit landed |
| **Which repo** | *(unfiled upstream)* A commit landing anywhere other than the session's working directory was checked against the wrong repository, so a real commit could be dropped because an unrelated `HEAD` looked stale. The target is now read off the command — `-C`, `-R`, `--git-dir`, `--work-tree`, a leading `cd`/`pushd` — including bare and out-of-tree layouts, where previously no SHA resolved and both the freshness check and the de-duplication were skipped |
| **Offer budget** | Repeated hook fires for one commit could burn the whole two-offer session budget. Emitted commits are de-duplicated per session, and a corrupt state file no longer disables the rate limit |
| **Parallel hooks** | *(unfiled upstream)* Tool calls run in parallel, and the session state was read and written without a lock. Six concurrent hooks on one commit reliably emitted **six** nudges, on every run; the cap could be overrun the same way. Now one. Locking is `mkdir`-based — `flock` is util-linux and absent on stock macOS |
| **Nudge precision** | The nudge now names its commit as `(<sha>: <subject>)`, so the skill has a concrete topic instead of inferring what was committed |
| **Codex hook path** | *(unfiled upstream)* The Codex hook resolved its script from a cache path with the plugin version **hardcoded**, so every release silently disabled the hook until that string was bumped in lockstep — and a local dev install was never found at all. The version is now resolved at runtime, matching how Codex picks the active one: a `local` dev install if present, otherwise the highest installed version |

A regression suite lives at [`learning-opportunities-auto/hooks/test-post-tool-use.sh`](learning-opportunities-auto/hooks/test-post-tool-use.sh) — 71 assertions, no dependencies beyond bash:

```
./learning-opportunities-auto/hooks/test-post-tool-use.sh
```

The upstream hook fails 39 of them.

### Design constraints kept

Upstream's hook header promises *"no external dependencies beyond bash and standard Unix tools"*, and an earlier fix attempt ([#21]) was withdrawn for reaching for `jq`. Everything here stays within `grep`/`sed`/`tr`, and detection keeps the original whole-payload grep as a fast pre-filter so the hot path — every Bash call that *isn't* a commit — stays as cheap as it was.

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
