# learning-opportunities-auto

A companion plugin for [learning-opportunities](../learning-opportunities/) that automatically detects good moments to offer learning exercises. Instead of relying on Claude to notice opportunities on its own, this plugin watches for commits and nudges Claude to make the offer.

**Requires:** The `learning-opportunities` plugin must also be installed.

## How It Works

It does not read the command. One script runs on three events: `SessionStart` and `PreToolUse` record where `HEAD` is in the repositories in play, and `PostToolUse` — which fires *after* the tool ran — asks whether `HEAD` has moved onto a commit that is new, that `HEAD`'s reflog does not attribute to a checkout, reset or fast-forward, and whose committer date falls inside the session. So a commit counts however it was spelled: behind an `env` prefix, through an alias or a shell function, from inside a script that never mentions git, or by [Jujutsu](https://github.com/jj-vcs/jj) in its default colocated mode, which writes real commits to the underlying `.git`. A command that only *mentions* committing moves nothing and says nothing.

When a commit is found, it nudges Claude to consider whether the work is a good fit for a learning exercise — the `learning-opportunities` skill decides what kind to offer based on the nature of the changes.

It respects the same session limits as the skill: no more than 2 offers per session, and it stops if the user declines.

## Installation

1. Make sure you've already installed `learning-opportunities` from this marketplace.

2. Install this plugin:
   ```
   /plugin install learning-opportunities-auto@learning-opportunities
   ```

3. Reload:
   ```
   /plugin reload
   ```

## Windows Setup

On Linux, macOS, and WSL2, this plugin works out of the box. On native Windows, Claude Code runs hooks using `cmd.exe` by default, which cannot execute bash scripts. You need to tell Claude Code where to find bash.

Set the `CLAUDE_CODE_GIT_BASH_PATH` environment variable to point at your Git for Windows bash installation. The typical location is:

```
CLAUDE_CODE_GIT_BASH_PATH=C:\Program Files\Git\bin\bash.exe
```

You can set this as a system environment variable, or add it to your shell profile before launching Claude Code.

If you run into issues, check that `Git\bin` (not just `Git\cmd`) is on your PATH, or that the environment variable above is set correctly. This is a [known friction point](https://github.com/anthropics/claude-code/issues/16602) in Claude Code's Windows hook support. If you're not sure how to set an environment variable or update your PATH on Windows, ask Claude — it can walk you through it.

## Codex Support

Codex uses `hooks.codex.json`, which runs the same `hooks/post-tool-use.sh` script from Codex's plugin cache. The script accepts both Claude Code's `command` payload field and Codex-style `cmd` payloads.

## How Hooks Work

This plugin uses post-tool-use hooks to run a script after each shell command. Claude Code reads `hooks/hooks.json`; Codex reads `hooks.codex.json`. The hook script itself lives at `hooks/post-tool-use.sh`.

## License

[![License: CC BY 4.0](https://img.shields.io/badge/License-CC_BY_4.0-lightgrey.svg)](https://creativecommons.org/licenses/by/4.0/)
