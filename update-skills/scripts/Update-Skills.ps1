<#
.SYNOPSIS
Installs or updates user-level Claude Code skills declared in config.json.

.DESCRIPTION
config.json is a JSON array of GitHub folder URLs, each pointing at a skill's directory (the folder
holding its SKILL.md). The destination folder name is the URL's last path segment, so the installed
skill always keeps its upstream name:

    [
      "https://github.com/mattpocock/skills/tree/main/skills/productivity/grilling"
    ]

Each run resolves every URL's commit via `git ls-remote` and compares it against installed.json, the
lock file recorded beside the config. Skills already at that commit and untouched on disk are left
alone without any checkout at all; only the rest are fetched, as one shallow blobless sparse
checkout per repository and ref. Installs are staged and swapped into place, so a failure mid-copy
never leaves a skill missing or half-written.

Folders carrying local edits (their contents no longer match the fingerprint recorded at install
time) are reported as Modified and skipped, so hand-edits are never silently discarded. -Force
overwrites them.

.PARAMETER ConfigPath
Path to the config file. Defaults to config.json beside this script's parent folder.

.PARAMETER LockPath
Path to the lock file recording what was installed. Defaults to installed.json beside the config.

.PARAMETER SkillsRoot
Destination root for installed skills. Defaults to the folder containing this skill.

.PARAMETER Only
Process just these skill names instead of every entry.

.PARAMETER Add
GitHub folder URLs to append to the config before syncing. Each is installed by the same run.

.PARAMETER Remove
Skill names (or full URLs) to drop from the config before syncing. Each removed skill is also
pruned from disk if this script installed it.

.PARAMETER Prune
Also remove skills that this script installed previously but that are no longer in the config.

.PARAMETER Force
Overwrite (or prune) skills whose folders carry local edits.

.EXAMPLE
pwsh Update-Skills.ps1

.EXAMPLE
pwsh Update-Skills.ps1 -Add https://github.com/mattpocock/skills/tree/main/skills/engineering/tdd

.EXAMPLE
pwsh Update-Skills.ps1 -Remove grill-me

.EXAMPLE
pwsh Update-Skills.ps1 -Only grilling -Force
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string] $ConfigPath,
    [string] $LockPath,
    [string] $SkillsRoot,
    [string[]] $Only,
    [string[]] $Add,
    [string[]] $Remove,
    [switch] $Prune,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The summary is emoji, so the console must be UTF-8 whatever the host's default code page is.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:SkillRoot = Split-Path -Parent $PSScriptRoot

if (-not $ConfigPath)
{
    $ConfigPath = Join-Path $script:SkillRoot 'config.json'
}

if (-not $LockPath)
{
    $LockPath = Join-Path (Split-Path -Parent $ConfigPath) 'installed.json'
}

if (-not $SkillsRoot)
{
    $SkillsRoot = Split-Path -Parent $script:SkillRoot
}

$script:RemoteRefCache = @{}


function Assert-GitAvailable
{
    if (-not (Get-Command git -ErrorAction SilentlyContinue))
    {
        throw 'git was not found on PATH. Install git, then re-run.'
    }
}

function Get-StatusIcon
{
    param([Parameter(Mandatory)] [string] $Status)

    switch -Regex ($Status)
    {
        '^Failed$' { return '❌' }
        '^Modified$' { return '⚠️' }
        '^Would ' { return '🔍' }
        default { return '✅' }
    }
}

function New-Result
{
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Status,
        [string] $Commit = '',
        [string] $Detail = ''
    )

    return [PSCustomObject]@{
        Icon = Get-StatusIcon -Status $Status
        Skill = $Name
        Status = $Status
        Commit = $Commit.Length -ge 7 ? $Commit.Substring(0, 7) : $Commit
        Detail = $Detail
    }
}

function Get-SkillNameFromUrl
{
    param([Parameter(Mandatory)] [string] $Url)

    return @($Url.TrimEnd('/') -split '/')[-1]
}

function Test-SameCommit
{
    param([string] $Left, [string] $Right)

    if (-not $Left -or -not $Right)
    {
        return $false
    }

    # A config URL may pin an abbreviated sha while the lock records the full one.
    return $Left.StartsWith($Right, [System.StringComparison]::OrdinalIgnoreCase) -or $Right.StartsWith($Left, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-RemoteRefMap
{
    param([Parameter(Mandatory)] [string] $RepoUrl)

    if ($script:RemoteRefCache.ContainsKey($RepoUrl))
    {
        return $script:RemoteRefCache[$RepoUrl]
    }

    $lines = & git ls-remote --heads --tags -- $RepoUrl 2>&1

    if ($LASTEXITCODE -ne 0)
    {
        throw "Cannot reach repository '$RepoUrl': $lines"
    }

    $map = @{}

    foreach ($line in $lines)
    {
        if ($line -match '^(\S+)\s+refs/(?:heads|tags)/(.+?)(\^\{\})?$')
        {
            $name = $Matches[2]
            $isPeeled = $Matches[3] -ne ''

            # An annotated tag advertises both the tag object and, as name^{}, the commit it points
            # at. The peeled line is the one worth checking out, so let it win.
            if ($isPeeled -or -not $map.ContainsKey($name))
            {
                $map[$name] = $Matches[1]
            }
        }
    }

    $script:RemoteRefCache[$RepoUrl] = $map

    return $map
}

function ConvertFrom-SkillUrl
{
    param([Parameter(Mandatory)] [string] $Url)

    if ($Url -notmatch '^https://github\.com/([^/]+)/([^/]+)/tree/(.+)$')
    {
        throw "Not a GitHub folder URL (expected https://github.com/<owner>/<repo>/tree/<ref>/<path>): '$Url'"
    }

    $owner = $Matches[1]
    $repo = $Matches[2] -replace '\.git$', ''
    $segments = @($Matches[3].TrimEnd('/') -split '/')
    $repoUrl = "https://github.com/$owner/$repo"

    if ($segments.Count -lt 2)
    {
        throw "URL is missing the folder path after the ref: '$Url'"
    }

    # A ref may itself contain slashes (release/v2), so try the longest candidate that the remote
    # actually advertises before falling back to treating the first segment as a commit sha.
    $refs = Get-RemoteRefMap -RepoUrl $repoUrl

    for ($count = $segments.Count - 1; $count -ge 1; $count--)
    {
        $candidate = ($segments[0..($count - 1)] -join '/')

        if ($refs.ContainsKey($candidate))
        {
            $path = ($segments[$count..($segments.Count - 1)] -join '/')

            return [PSCustomObject]@{
                Url = $Url
                RepoUrl = $repoUrl
                Ref = $candidate
                IsCommit = $false
                Commit = $refs[$candidate]
                Path = $path
                Name = $segments[$segments.Count - 1]
            }
        }
    }

    if ($segments[0] -match '^[0-9a-fA-F]{7,40}$')
    {
        $path = ($segments[1..($segments.Count - 1)] -join '/')

        return [PSCustomObject]@{
            Url = $Url
            RepoUrl = $repoUrl
            Ref = $segments[0]
            IsCommit = $true
            Commit = $segments[0]
            Path = $path
            Name = $segments[$segments.Count - 1]
        }
    }

    throw "No branch or tag in $repoUrl matches the ref in '$Url'."
}

function New-RepoWorkspace
{
    param(
        [Parameter(Mandatory)] [PSCustomObject] $Source,
        [Parameter(Mandatory)] [string[]] $Paths,
        [Parameter(Mandatory)] [string] $WorkDir
    )

    if ($Source.IsCommit)
    {
        & git init --quiet -- $WorkDir 2>&1 | Out-Null
        & git -C $WorkDir remote add origin $Source.RepoUrl 2>&1 | Out-Null
        $output = & git -C $WorkDir fetch --depth 1 --filter=blob:none origin $Source.Ref 2>&1

        if ($LASTEXITCODE -ne 0)
        {
            throw "Could not fetch commit '$($Source.Ref)' from $($Source.RepoUrl): $output"
        }

        & git -C $WorkDir sparse-checkout init --cone 2>&1 | Out-Null
        & git -C $WorkDir sparse-checkout set -- @Paths 2>&1 | Out-Null
        $output = & git -C $WorkDir checkout --quiet FETCH_HEAD 2>&1
    }
    else
    {
        $output = & git clone --quiet --depth 1 --filter=blob:none --sparse --branch $Source.Ref -- $Source.RepoUrl $WorkDir 2>&1

        if ($LASTEXITCODE -ne 0)
        {
            throw "Clone of $($Source.RepoUrl) at '$($Source.Ref)' failed: $output"
        }

        $output = & git -C $WorkDir sparse-checkout set -- @Paths 2>&1
    }

    if ($LASTEXITCODE -ne 0)
    {
        throw "Could not check out from $($Source.RepoUrl) at '$($Source.Ref)': $output"
    }

    $head = (& git -C $WorkDir rev-parse HEAD 2>&1).Trim()

    if ($LASTEXITCODE -ne 0)
    {
        throw "Could not resolve HEAD in the checkout of $($Source.RepoUrl)."
    }

    return $head
}

function Remove-Workspace
{
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path))
    {
        return
    }

    if ($IsWindows)
    {
        # Git marks pack files read-only, which blocks a plain recursive delete on Windows.
        Get-ChildItem -LiteralPath $Path -Recurse -Force | ForEach-Object { $_.Attributes = 'Normal' }
    }

    # -WhatIf:$false so a preview run still cleans up its own scratch clone.
    Remove-Item -LiteralPath $Path -Recurse -Force -WhatIf:$false
}

function Get-FolderFingerprint
{
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container))
    {
        return $null
    }

    $root = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $entries = [System.Collections.Generic.List[string]]::new()

    foreach ($file in (Get-ChildItem -LiteralPath $root -Recurse -File -Force))
    {
        $relative = ($file.FullName.Substring($root.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)) -replace '[\\/]', '/'

        if ($relative -eq '.git' -or $relative.StartsWith('.git/'))
        {
            continue
        }

        $entries.Add(('{0}:{1}' -f $relative, (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash))
    }

    $manifest = (($entries | Sort-Object) -join "`n")
    $stream = [System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($manifest))

    try
    {
        return (Get-FileHash -InputStream $stream -Algorithm SHA256).Hash
    }
    finally
    {
        $stream.Dispose()
    }
}

function Test-ReparsePoint
{
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path))
    {
        return $false
    }

    return [bool]((Get-Item -LiteralPath $Path -Force).Attributes -band [System.IO.FileAttributes]::ReparsePoint)
}

function Remove-SkillFolder
{
    param([Parameter(Mandatory)] [string] $Path)

    # A junction or symlink must be unlinked, never recursed into, or the delete follows the link.
    if (Test-ReparsePoint -Path $Path)
    {
        (Get-Item -LiteralPath $Path -Force).Delete()

        return
    }

    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Install-SkillFolder
{
    param(
        [Parameter(Mandatory)] [string] $SourceDir,
        [Parameter(Mandatory)] [string] $Destination
    )

    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $staging = "$Destination.staging-$suffix"
    $retired = "$Destination.retired-$suffix"
    $existed = Test-Path -LiteralPath $Destination

    Copy-Item -LiteralPath $SourceDir -Destination $staging -Recurse -Force

    try
    {
        # Everything below is a rename, so the window where the destination does not exist is as
        # short as the filesystem can make it, and any failure is recoverable.
        if ($existed)
        {
            if (Test-ReparsePoint -Path $Destination)
            {
                Remove-SkillFolder -Path $Destination
            }
            else
            {
                Move-Item -LiteralPath $Destination -Destination $retired
            }
        }

        try
        {
            Move-Item -LiteralPath $staging -Destination $Destination
        }
        catch
        {
            if (Test-Path -LiteralPath $retired)
            {
                Move-Item -LiteralPath $retired -Destination $Destination
            }

            throw
        }
    }
    finally
    {
        foreach ($leftover in @($staging, $retired))
        {
            if (Test-Path -LiteralPath $leftover)
            {
                Remove-Item -LiteralPath $leftover -Recurse -Force
            }
        }
    }
}

function Write-JsonFile
{
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Json
    )

    # Newlines are normalized so a hand-kept config keeps whatever endings it already had.
    $text = ($Json -replace "`r`n", "`n").TrimEnd() + "`n"

    [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
}

function Read-JsonFile
{
    param([Parameter(Mandatory)] [string] $Path)

    $raw = Get-Content -LiteralPath $Path -Raw

    if (-not $raw -or -not $raw.Trim())
    {
        return $null
    }

    return $raw | ConvertFrom-Json -AsHashtable
}


Assert-GitAvailable

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf))
{
    throw "Config not found: $ConfigPath"
}

if (-not (Test-Path -LiteralPath $SkillsRoot -PathType Container))
{
    throw "Skills root not found: $SkillsRoot"
}

$config = Read-JsonFile -Path $ConfigPath

if ($config -is [System.Collections.IDictionary])
{
    throw "$ConfigPath uses the old name-to-url object format. It is now a JSON array of URLs; the folder name comes from each URL's last segment."
}

$urls = @($config)

$results = [System.Collections.Generic.List[object]]::new()
$removed = [System.Collections.Generic.List[string]]::new()
$configChanged = $false

# -Remove matches on the folder name parsed straight out of the URL, so delisting still works when
# the source repo or ref has gone away.
foreach ($target in @($Remove | Where-Object { $_ }))
{
    $name = Get-SkillNameFromUrl -Url $target
    $matched = @($urls | Where-Object { $_ -eq $target -or (Get-SkillNameFromUrl -Url $_) -eq $name })

    if (-not $matched)
    {
        $results.Add((New-Result -Name $name -Status 'Failed' -Detail "Not in $ConfigPath, so there is nothing to remove."))

        continue
    }

    $urls = @($urls | Where-Object { $_ -notin $matched })
    $removed.Add($name)
    $configChanged = $true
}

foreach ($target in @($Add | Where-Object { $_ }))
{
    $name = Get-SkillNameFromUrl -Url $target

    if (@($urls | Where-Object { (Get-SkillNameFromUrl -Url $_) -eq $name }))
    {
        $results.Add((New-Result -Name $name -Status 'Failed' -Detail "Already in $ConfigPath."))

        continue
    }

    try
    {
        # Resolve it now so a bad URL is rejected before it lands in the config.
        [void] (ConvertFrom-SkillUrl -Url $target)
    }
    catch
    {
        $results.Add((New-Result -Name $name -Status 'Failed' -Detail $_.Exception.Message))

        continue
    }

    $urls = @($urls) + $target
    $configChanged = $true
}

$configWritten = $false

if ($configChanged -and $PSCmdlet.ShouldProcess($ConfigPath, 'Update the skill list'))
{
    Write-JsonFile -Path $ConfigPath -Json (ConvertTo-Json -InputObject @($urls) -Depth 3)
    $configWritten = $true
}

$lock = @{}

if (Test-Path -LiteralPath $LockPath -PathType Leaf)
{
    $loaded = Read-JsonFile -Path $LockPath

    if ($loaded -is [System.Collections.IDictionary])
    {
        $lock = $loaded
    }
}

$sources = [System.Collections.Generic.List[object]]::new()
$seen = @{}

foreach ($url in $urls)
{
    try
    {
        $source = ConvertFrom-SkillUrl -Url $url

        if ($seen.ContainsKey($source.Name))
        {
            $results.Add((New-Result -Name $source.Name -Status 'Failed' -Detail "Declared twice; the second entry is '$url'."))

            continue
        }

        $seen[$source.Name] = $true

        if ($source.Name -eq (Split-Path -Leaf $script:SkillRoot))
        {
            $results.Add((New-Result -Name $source.Name -Status 'Failed' -Detail 'Refusing to overwrite this skill with itself.'))

            continue
        }

        $sources.Add($source)
    }
    catch
    {
        $results.Add((New-Result -Name ([string]$url) -Status 'Failed' -Detail $_.Exception.Message))
    }
}

if ($Only)
{
    $known = @($sources | ForEach-Object { $_.Name })
    $missing = @($Only | Where-Object { $_ -notin $known })

    if ($missing)
    {
        throw "Not declared in $ConfigPath : $($missing -join ', ')"
    }

    $sources = [System.Collections.Generic.List[object]](@($sources | Where-Object { $_.Name -in $Only }))
}

# Decide what actually needs a checkout. An entry already at the resolved commit, with its folder
# untouched since install, is settled without any network beyond the ls-remote already done.
$pending = [System.Collections.Generic.List[object]]::new()

foreach ($source in $sources)
{
    $destination = Join-Path $SkillsRoot $source.Name
    $entry = $lock.ContainsKey($source.Name) ? $lock[$source.Name] : $null
    $installed = Get-FolderFingerprint -Path $destination

    $isModified = $entry -and $installed -and $entry.ContainsKey('Fingerprint') -and $entry.Fingerprint -ne $installed

    if ($isModified -and -not $Force)
    {
        $results.Add((New-Result -Name $source.Name -Status 'Modified' -Commit ($entry.ContainsKey('Commit') ? [string]$entry.Commit : '') -Detail 'Folder was edited after install; re-run with -Force to overwrite.'))

        continue
    }

    if (-not $isModified -and $installed -and $entry -and $entry.ContainsKey('Url') -and $entry.Url -eq $source.Url -and (Test-SameCommit -Left ([string]$entry.Commit) -Right $source.Commit))
    {
        $results.Add((New-Result -Name $source.Name -Status 'Up-to-date' -Commit ([string]$entry.Commit) -Detail "$($source.Ref)/$($source.Path)"))

        continue
    }

    $pending.Add([PSCustomObject]@{ Source = $source; Destination = $destination; Existed = [bool]$installed })
}

# One checkout per repository and ref, however many skills come out of it.
foreach ($group in ($pending | Group-Object { '{0}#{1}' -f $_.Source.RepoUrl, $_.Source.Ref }))
{
    $items = @($group.Group)
    $workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('update-skills-' + [guid]::NewGuid().ToString('N'))

    try
    {
        $head = New-RepoWorkspace -Source $items[0].Source -Paths @($items | ForEach-Object { $_.Source.Path }) -WorkDir $workDir
    }
    catch
    {
        foreach ($item in $items)
        {
            $results.Add((New-Result -Name $item.Source.Name -Status 'Failed' -Detail $_.Exception.Message))
        }

        Remove-Workspace -Path $workDir

        continue
    }

    try
    {
        foreach ($item in $items)
        {
            $source = $item.Source

            try
            {
                $sourceDir = Join-Path $workDir ($source.Path -replace '/', [System.IO.Path]::DirectorySeparatorChar)

                if (-not (Test-Path -LiteralPath $sourceDir -PathType Container))
                {
                    throw "Path '$($source.Path)' does not exist in $($source.RepoUrl) at '$($source.Ref)'."
                }

                if (-not (Test-Path -LiteralPath (Join-Path $sourceDir 'SKILL.md') -PathType Leaf))
                {
                    throw "Source folder '$($source.Path)' has no SKILL.md, so it is not a skill."
                }

                $fingerprint = Get-FolderFingerprint -Path $sourceDir
                $unchanged = $item.Existed -and $fingerprint -eq (Get-FolderFingerprint -Path $item.Destination)
                $action = $item.Existed ? 'Update skill (replaces the installed folder)' : 'Install skill'

                if (-not $unchanged -and -not $PSCmdlet.ShouldProcess($item.Destination, $action))
                {
                    $results.Add((New-Result -Name $source.Name -Status ($item.Existed ? 'Would update' : 'Would install') -Commit $head -Detail "$($source.Ref)/$($source.Path)"))

                    continue
                }

                if (-not $unchanged)
                {
                    Install-SkillFolder -SourceDir $sourceDir -Destination $item.Destination
                }

                $lock[$source.Name] = @{
                    Url = $source.Url
                    Commit = $head
                    Fingerprint = $fingerprint
                    InstalledAt = (Get-Date).ToUniversalTime().ToString('o')
                }

                $status = $unchanged ? 'Up-to-date' : ($item.Existed ? 'Updated' : 'Installed')
                $results.Add((New-Result -Name $source.Name -Status $status -Commit $head -Detail "$($source.Ref)/$($source.Path)"))
            }
            catch
            {
                $results.Add((New-Result -Name $source.Name -Status 'Failed' -Detail $_.Exception.Message))
            }
        }
    }
    finally
    {
        Remove-Workspace -Path $workDir
    }
}

if ($Prune -or $removed.Count -gt 0)
{
    # Only ever prune what this script recorded installing, never an unrelated folder. Without
    # -Prune the sweep is narrowed to whatever -Remove just delisted.
    $candidates = @($lock.Keys | Where-Object { $_ -notin $seen.Keys } | Where-Object { $Prune -or $_ -in $removed } | Sort-Object)

    foreach ($name in $candidates)
    {
        $destination = Join-Path $SkillsRoot $name
        $entry = $lock[$name]
        $installed = Get-FolderFingerprint -Path $destination

        if (-not $installed)
        {
            $lock.Remove($name)
            $results.Add((New-Result -Name $name -Status 'Pruned' -Detail 'Already absent; dropped from the lock file.'))

            continue
        }

        if ($entry.ContainsKey('Fingerprint') -and $entry.Fingerprint -ne $installed -and -not $Force)
        {
            $results.Add((New-Result -Name $name -Status 'Modified' -Detail 'Delisted but edited after install; re-run with -Force to prune.'))

            continue
        }

        if (-not $PSCmdlet.ShouldProcess($destination, 'Prune skill (no longer in the config)'))
        {
            $results.Add((New-Result -Name $name -Status 'Would prune' -Detail 'No longer in the config.'))

            continue
        }

        Remove-SkillFolder -Path $destination
        $lock.Remove($name)
        $results.Add((New-Result -Name $name -Status 'Pruned' -Detail 'No longer in the config.'))
    }
}

# A delisted skill this script never installed has nothing to prune, so say so rather than go quiet.
foreach ($name in $removed)
{
    if (-not @($results | Where-Object { $_.Skill -eq $name }))
    {
        $results.Add((New-Result -Name $name -Status 'Removed' -Detail 'Dropped from the config; no installed copy was managed by this script.'))
    }
}

if ($PSCmdlet.ShouldProcess($LockPath, 'Write lock file'))
{
    Write-JsonFile -Path $LockPath -Json ($lock | ConvertTo-Json -Depth 5)
}

$ordered = @($results | Sort-Object Skill)
$ordered | Format-Table -AutoSize @{ Name = ' '; Expression = { $_.Icon } }, Skill, Status, Commit | Out-String | Write-Host

# Details are printed in full here because Format-Table clips the column that explains a failure.
foreach ($result in @($ordered | Where-Object { $_.Status -in @('Failed', 'Modified') }))
{
    Write-Host "$($result.Icon) $($result.Skill) — $($result.Detail)"
}

if ($configWritten)
{
    Write-Host "📝 Config updated: $ConfigPath"
}

$failed = @($ordered | Where-Object { $_.Status -eq 'Failed' })
$warned = @($ordered | Where-Object { $_.Status -eq 'Modified' })
$previewed = @($ordered | Where-Object { $_.Status -like 'Would *' })

if ($failed)
{
    Write-Host "`n❌ $($failed.Count) of $($ordered.Count) entr(ies) failed."

    exit 1
}

if ($previewed)
{
    Write-Host "`n🔍 Preview only — $($previewed.Count) of $($ordered.Count) entr(ies) would change, nothing was written."

    exit 0
}

if ($warned)
{
    Write-Host "`n⚠️ $($ordered.Count) entr(ies) processed, $($warned.Count) skipped as locally modified."

    exit 0
}

Write-Host "`n✅ $($ordered.Count) entr(ies) processed against $SkillsRoot."

exit 0
