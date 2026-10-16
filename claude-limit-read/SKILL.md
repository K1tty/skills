---
name: claude-limit-read
description: Live Claude plan usage limits (5-hour and weekly percent used, reset times) from the Anthropic API. Use when the user asks about the usage limit, quota or what is left, or before a long task that may hit the limit.
---

# Limit Read

Run the script in this skill's folder:

```powershell
& "$env:USERPROFILE\.claude\skills\claude-limit-read\Get-Limit.ps1"
```

It prints one line per limit bucket (`five_hour`, `seven_day`, and any per-model weekly bucket) with percent used and the local reset time, then the current local time. The token stays inside the script; never read `.credentials.json` yourself.

Report a table: limit, percent used, reset time (with the time left until a reset within the next 24 hours).

The API is the source of truth. `~/.cache/ccstatusline/usage.json` is a fallback cache that goes stale, and session transcripts hold token counts but no limit.

On a script error, give the error text. A `401` means the stored OAuth token expired: any new Claude Code request refreshes it, so run the script once more before you report the failure.
