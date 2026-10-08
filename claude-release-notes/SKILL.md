---
name: claude-release-notes
description: "Report the Claude Code CLI release notes for the versions released since the previous run of this skill, filtered to the user's development workflow and environment."
disable-model-invocation: true
---

Report what changed in the Claude Code CLI since the previous run of this skill.

## Steps

1. Find the version range.
   - Current version: run `claude --version`.
   - Previous version: read `last-version.txt` in this skill's directory. If the file does not exist, this is the first run: the range is the current version alone.
   - The range is every version after the previous version, up to and including the current version.
   - If the current version equals the previous version, reply `No new versions since <version>.` and stop.

2. Get the changelog. Download `https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md` to the scratchpad with the shell (not WebFetch, which summarises), then read the sections for the versions in the range. A version with no section in the changelog has no notes; skip it.

3. Filter the entries. Exclude a change when either holds:
   - It is not related to the user's development workflow.
   - It is not related to the user's development environment.

   Judge both from evidence, not assumption: the platform, shell and surface of this session, the user's global `~/.claude/CLAUDE.md` and `~/.claude/settings.json`, and the skills, agents, hooks, plugins and MCP servers the user has installed. A change to an operating system, terminal, IDE, cloud provider, authentication method or feature the user does not use is excluded. When the evidence does not settle it, include the change.

4. Write the release notes with the template below. Write nothing else: no preamble, no commentary, no list of what was excluded.
   - One line per change, in your own short wording. Merge entries that describe the same change across versions.
   - Omit a section that has no entries.
   - `<new versions range>` is `<first new version> – <current version>`, or a single version when the range holds one.

5. Write the current version to `last-version.txt` in this skill's directory. Do this only after the release notes are written, so a failed run reports the same range again.

## Template

```
**Release Notes (<new versions range>)**

**New Features:**
- <Short feature description>
- ...

**Improvements:**
- <Short improvement description>
- ...

**Bug Fixes:**
- <Short bugfix description>
- ...
```
