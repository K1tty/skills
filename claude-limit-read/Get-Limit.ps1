<#
.SYNOPSIS
Prints the current Claude plan usage limits from the Anthropic usage API.

.DESCRIPTION
Reads the Claude Code OAuth access token from ~/.claude/.credentials.json and sends it only to api.anthropic.com.
The token is never printed. Output is one line per limit: name, percent used, local reset time.
#>

$ErrorActionPreference = 'Stop'

$Credentials = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$Token = (Get-Content -Raw $Credentials | ConvertFrom-Json).claudeAiOauth.accessToken
if (-not $Token)
{
	throw "No claudeAiOauth.accessToken in $Credentials"
}

$Headers = @{ Authorization = "Bearer $Token"; 'anthropic-beta' = 'oauth-2025-04-20' }
$Usage = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers $Headers -TimeoutSec 10
Remove-Variable Token, Headers

foreach ($Property in $Usage.PSObject.Properties | Where-Object Name -Match '^(five_hour|seven_day.*)$')
{
	$Bucket = $Property.Value
	if ($null -eq $Bucket -or $null -eq $Bucket.PSObject.Properties['utilization'] -or $null -eq $Bucket.utilization)
	{
		continue
	}

	$Reset = if ($Bucket.resets_at) { ([datetimeoffset]$Bucket.resets_at).ToLocalTime().ToString('ddd yyyy-MM-dd HH:mm') } else { '-' }
	'{0}: {1:0.#}% used, resets {2}' -f $Property.Name, [double]$Bucket.utilization, $Reset
}

"extra_usage enabled: $($Usage.extra_usage.is_enabled)"
"now: $((Get-Date).ToString('ddd yyyy-MM-dd HH:mm'))"
