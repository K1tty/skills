---
name: update-skills
description: Install, update, add, remove, or prune the user-level skills declared in this skill's config.json.
disable-model-invocation: true
argument-hint: [add <url> | remove <name>]
allowed-tools: Bash(pwsh:*) PowerShell(pwsh:*) Read Edit
---

# Update Skills

Keeps the user-level skills in `~/.claude/skills` in sync with the sources declared in
`config.json`, which sits next to this file.

## Config format

`config.json` is a JSON array of GitHub folder URLs, each pointing at a skill's directory — the
folder holding its `SKILL.md`. The **destination folder name is the URL's last path segment**, so an
installed skill always keeps its upstream name and there is no name to keep in sync:

```json
[
  "https://github.com/mattpocock/skills/tree/main/skills/productivity/grilling",
  "https://github.com/mattpocock/skills/tree/main/skills/productivity/grill-me"
]
```

The ref segment may be a branch, a tag, or a commit sha. Only skills listed here — plus, under
`-Remove` or `-Prune`, ones this script installed earlier — are ever touched. The file is rewritten
by `-Add` and `-Remove`, keeping its existing line endings.

`installed.json` beside the config is the lock file: per skill, the source URL, the commit it came
from, a fingerprint of the installed contents, and the install timestamp. It is written by the
script; do not hand-edit it. Delete it to force a full re-check.

## Running it

```powershell
pwsh -NoProfile -File "${CLAUDE_SKILL_DIR}/scripts/Update-Skills.ps1"
```

Switches:

- `-Add <url>` — append a URL to the config, then install it in the same run.
- `-Remove <name|url>` — drop it from the config, and prune the folder if this script installed it.
- `-Only grilling,grill-me` — process just those skills.
- `-Prune` — also remove skills this script installed that are no longer in the config.
- `-Force` — overwrite or prune folders that carry local edits.
- `-WhatIf` — report what would change without writing anything.
- `-ConfigPath` / `-LockPath` / `-SkillsRoot` — override the defaults.

`-Add` and `-Remove` both take a comma-separated list, and both edit `config.json` themselves — the
config is the script's to write, so leave it alone and pass the switch.

The script exits non-zero if any entry failed, and prints one row per entry:

| Status | Meaning |
| --- | --- |
| ✅ `Installed` | Folder did not exist; fetched fresh. |
| ✅ `Updated` | Contents differed upstream; folder replaced. |
| ✅ `Up-to-date` | Already at the resolved commit, or byte-identical to it; nothing written. |
| ✅ `Pruned` | Delisted from the config and removed. |
| ✅ `Removed` | Delisted from the config; no installed copy was managed here. |
| ⚠️ `Modified` | Folder was edited after install; skipped. Needs `-Force`. |
| 🔍 `Would install` / `Would update` / `Would prune` | `-WhatIf` only. |
| ❌ `Failed` | See the detail lines printed under the table. |

The closing line is ✅ when everything succeeded, ⚠️ when a skill was skipped as locally modified,
and ❌ with a non-zero exit when anything failed.

## How to drive this skill

The skill takes an optional request in plain language. Map it onto switches, then run once:

| Request | Switch |
| --- | --- |
| "add `<url>`" | `-Add <url>` |
| "remove `<name>`", "drop `<name>`" | `-Remove <name>` |
| named skills, no add/remove | `-Only <names>` |
| nothing | no switch — sync the whole config |

A request naming a skill to add without a URL needs the URL first: ask for it, or find the folder in
the upstream repo already in `config.json` and confirm the URL you found before adding it.

Then:

1. Run the script and show the result table.
2. A ⚠️ `Modified` row means the user edited that skill by hand. Say which skill it is and ask
   before re-running with `-Force`, since forcing discards their edits.
3. For a ❌ `Failed` row, read the detail line printed beneath the table and fix the cause — usually
   a wrong URL, a ref that no longer exists, or a folder that has no `SKILL.md`.
4. Report the outcome with the same ✅ / ⚠️ / ❌ the script used, so the summary matches its output.
5. Claude Code watches `~/.claude/skills` and picks up added, changed, and removed skills within the
   current session on its own — a new skill is usable immediately.

## Things to keep in mind

- Installs are staged beside the destination and swapped in by rename, so an interrupted run leaves
  the previous version intact rather than a missing or half-written skill.
- A run costs one `git ls-remote` per repository. Skills already at the resolved commit and
  untouched on disk are settled from the lock file with no checkout at all; only the rest are
  fetched, as one shallow blobless sparse checkout per repository and ref.
- If a destination is a junction or symlink, the link is removed and replaced with a real folder —
  the link target is not written through.
- `update-skills` cannot manage itself; such an entry is rejected. Two URLs ending in the same
  folder name are rejected as a collision.
- Live detection covers `SKILL.md` text. If an installed folder is plugin-shaped — it carries
  `hooks/`, `.mcp.json`, `agents/`, or `output-styles/` — those parts need `/reload-plugins`, which
  only the user can run.
