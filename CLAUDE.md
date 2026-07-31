# Learning Opportunities

Last verified: 2026-03-03

## What This Is

A Claude Code plugin packaging science-based learning exercises for deliberate skill development during AI-assisted coding. Author: Dr. Cat Hicks. License: CC-BY-4.0.

## Project Structure

- `.claude-plugin/marketplace.json` - Marketplace catalog (repo root is the marketplace)
- `.agents/plugins/marketplace.json` - Codex marketplace catalog
- `learning-opportunities/` - The skill plugin
  - `.claude-plugin/plugin.json` - Plugin manifest
  - `.codex-plugin/plugin.json` - Codex plugin manifest
  - `skills/learning-opportunities/` - The skill (SKILL.md + resources)
- `learning-opportunities-auto/` - The auto-prompting hook plugin (requires `learning-opportunities`)
  - `.claude-plugin/plugin.json` - Plugin manifest
  - `.codex-plugin/plugin.json` - Codex plugin manifest
  - `hooks/post-tool-use.sh` - PostToolUse hook (bash)
- `orient/` - The orientation generator plugin
  - `.claude-plugin/plugin.json` - Plugin manifest
  - `.codex-plugin/plugin.json` - Codex plugin manifest
  - `skills/orient/` - The skill (SKILL.md)
- `CHANGELOG.md` - Release history

## Releasing a New Version

Each plugin has its own version. When releasing, update it in three places atomically:

1. `<plugin>/.claude-plugin/plugin.json` — bump `version`
2. `<plugin>/.codex-plugin/plugin.json` — bump `version`
3. `CHANGELOG.md` — add entry at top, under the `# Changelog` heading

Use semver. Both manifests must show the same version string for the plugin being released. Commit them together.

`.claude-plugin/marketplace.json` is **not** in that list, despite its plugin entries carrying a `version` field. Claude Code resolves a plugin's version from `plugin.json` first and the marketplace entry only if that is absent — ["Claude Code always uses the `plugin.json` value without warning"](https://code.claude.com/docs/en/plugin-marketplaces#version-resolution-and-release-channels), and the docs advise against setting both. The versions in the catalog are inert. The file changes when a plugin is added, renamed, or removed, not on release.

`learning-opportunities-auto/hooks.codex.json` is deliberately **not** in that list. It resolves the hook script out of Codex's plugin cache, whose path contains the installed version, by globbing rather than naming a version. Do not reintroduce a hardcoded version there — it would have to be bumped in lockstep with every release, and it never matches a local dev install.

Selection mirrors how Codex itself picks the active version: `local` if that directory exists, otherwise the highest version by `sort -V`. It has to match, because Codex loads the plugin config from the directory it considers active and the hook must run the script from that same one. Do not select by modification time — a `local` dev install or a reinstall of an older release can easily be the most recently touched directory while Codex is loading a different one, and the hook then runs a script that does not belong to the active plugin.

### Changelog format

```markdown
## <plugin-name> X.Y.Z

Brief description.

**New:**
- Additions

**Changed:**
- Modifications

**Fixed:**
- Bug fixes
```

Only include sections that apply.
