#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Normalize server patches: convert "new file" patches that target a class
    which also exists in the vanilla decompiled sources into "modification"
    patches.

.DESCRIPTION
    Why: paperweight's McDev.importMcDev() collects every path referenced by a
    patch's "+++ b/src/main/java/..." line and copies the VANILLA file in when
    the target does not exist yet. So a "new file" patch for a vanilla class
    results in "both added" during `git am`.

    Because `rebuildPatches` runs `git format-patch base..HEAD`, a file that is
    new to the tree (but exists in vanilla) is emitted as a full new-file patch.
    This script rewrites such a patch as a modification (vanilla -> new content)
    so that the import supplies the pre-image and the patch applies cleanly.

    After the first successful apply, `base` contains the file, so later
    `rebuildPatches` runs already emit modification patches and this script
    becomes a no-op for them.

    Patches whose target is NOT in the vanilla sources (real new classes such as
    org/purpurmc/..., gg/pufferfish/...) are left untouched.

.PARAMETER RepoRoot
    Repository root (directory containing patches/ and Purpur-Server/).

.PARAMETER PatchDir
    Patch directory relative to RepoRoot.

.EXAMPLE
    ./scripts/pw-normalize-patches.ps1
#>
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$PatchDir = 'patches/server',
    [string]$ServerDir = 'Purpur-Server'
)

$ErrorActionPreference = 'Stop'
$patchPath = Join-Path $RepoRoot $PatchDir
$serverPath = Join-Path $RepoRoot $ServerDir
$cacheRoot = Join-Path $serverPath '.gradle/caches/paperweight/mc-dev-sources'
$tmpRoot = Join-Path $RepoRoot '.dsh-normalize'

if (-not (Test-Path $patchPath)) { throw "patch dir not found: $patchPath" }

function Get-VanillaContent([string]$repoRel) {
    $rel = $repoRel -replace '^src/main/java/', ''
    $cacheFile = Join-Path $cacheRoot ($rel -replace '/', '\')
    if (Test-Path $cacheFile) { return , @{ Text = ([System.IO.File]::ReadAllText($cacheFile) -replace "`r`n", "`n"); Source = 'cache' } }

    $tmp = Join-Path $tmpRoot 'base.tmp'
    New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
    cmd /c "git -C `"$serverPath`" cat-file blob base:$repoRel > `"$tmp`" 2>nul"
    if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt 0) {
        $text = ([System.IO.File]::ReadAllText($tmp) -replace "`r`n", "`n")
        Remove-Item $tmp -Force
        return , @{ Text = $text; Source = 'base' }
    }

    # authoritative source: the decompiled sources jar used by importMcDev
    $fromJar = Get-ContentFromJar $rel
    if ($null -ne $fromJar) { return , @{ Text = $fromJar; Source = 'decompile jar' } }
    return $null
}

$script:jarCache = @{}
function Get-ContentFromJar([string]$rel) {
    if ($script:jarCache.Count -eq 0) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
        $roots = @(
            (Join-Path $serverPath '.gradle\caches\paperweight'),
            (Join-Path $RepoRoot '.gradle\caches\paperweight')
        )
        $jars = @()
        foreach ($r in $roots) {
            if (Test-Path $r) {
                $jars += Get-ChildItem $r -Recurse -Filter '*.jar' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Length -gt 1MB } | Select-Object -ExpandProperty FullName
            }
        }
        $script:jarCache['jars'] = $jars | Select-Object -Unique
    }

    foreach ($jar in $script:jarCache['jars']) {
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($jar)
            try {
                $entry = $zip.GetEntry($rel)
                if ($null -eq $entry) { continue }
                $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
                $text = $reader.ReadToEnd()
                $reader.Close()
                return ($text -replace "`r`n", "`n")
            } finally { $zip.Dispose() }
        } catch { }
    }
    return $null
}

function New-DiffBlock([string]$path, [string]$vanilla, [string]$newContent) {
    New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
    $a = Join-Path $tmpRoot 'a.java'
    $b = Join-Path $tmpRoot 'b.java'
    [System.IO.File]::WriteAllText($a, $vanilla)
    [System.IO.File]::WriteAllText($b, $newContent)

    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $raw = & git -c core.autocrlf=false -c core.safecrlf=false diff --no-index --no-color --full-index --unified=3 -- $a $b 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = $old
    if ($code -ne 1) { throw "git diff --no-index failed ($code) for $path" }

    $out = New-Object System.Collections.Generic.List[string]
    foreach ($item in $raw) {
        $line = "$item"
        if ($line -match '^(diff --git |index |--- |\+\+\+ |@@ |[+\- ]|\\ No newline)') {
            if ($line -match '^diff --git ') { $out.Add("diff --git a/$path b/$path") }
            elseif ($line -match '^--- ') { $out.Add("--- a/$path") }
            elseif ($line -match '^\+\+\+ ') { $out.Add("+++ b/$path") }
            else { $out.Add($line) }
        }
    }
    return , $out
}

$converted = 0
$dropped = 0
$skipped = 0

Get-ChildItem $patchPath -Filter '*.patch' | ForEach-Object {
    $file = $_
    $lines = [System.IO.File]::ReadAllLines($file.FullName)
    if ($lines.Count -eq 0) { return }

    # split into preamble and one block per "diff --git"
    $blockStarts = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^diff --git ') { $blockStarts.Add($i) }
    }
    if ($blockStarts.Count -eq 0) { return }

    $preambleEnd = $blockStarts[0]
    $newLines = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $preambleEnd; $i++) { $newLines.Add($lines[$i]) }

    $changed = $false
    for ($b = 0; $b -lt $blockStarts.Count; $b++) {
        $start = $blockStarts[$b]
        $end = if ($b + 1 -lt $blockStarts.Count) { $blockStarts[$b + 1] } else { $lines.Count }
        $block = $lines[$start..($end - 1)]

        $isNewFile = $false
        $targetPath = $null
        foreach ($l in $block) {
            if ($l -match '^new file mode') { $isNewFile = $true }
            if ($l -match '^\+\+\+ b/(.+)$') { $targetPath = $matches[1] }
        }

        if (-not $isNewFile -or -not $targetPath -or -not $targetPath.StartsWith('src/main/java/')) {
            foreach ($l in $block) { $newLines.Add($l) }
            continue
        }

        $vanillaInfo = Get-VanillaContent $targetPath
        if ($null -eq $vanillaInfo) {
            if ($targetPath.StartsWith('src/main/java/net/minecraft/')) {
                Write-Host ("  [skip] {0}: no vanilla source found, left as new-file (may conflict)" -f $targetPath)
                $skipped++
            }
            foreach ($l in $block) { $newLines.Add($l) }
            continue
        }

        # reconstruct the file content from the added lines
        $content = New-Object System.Collections.Generic.List[string]
        $inHunk = $false
        foreach ($l in $block) {
            if ($l -match '^@@ ') { $inHunk = $true; continue }
            if (-not $inHunk) { continue }
            if ($l.StartsWith('+')) { $content.Add($l.Substring(1)) }
            elseif ($l -eq '\ No newline at end of file') { continue }
        }
        $newText = ($content -join "`n")
        if ($newText -eq $vanillaInfo.Text) {
            Write-Host ("  [drop] {0}: identical to vanilla, patch block removed" -f $targetPath)
            $dropped++
            $changed = $true
            continue
        }

        $diffBlock = New-DiffBlock $targetPath $vanillaInfo.Text $newText
        foreach ($l in $diffBlock) { $newLines.Add($l) }
        Write-Host ("  [conv] {0} (vanilla from {1})" -f $targetPath, $vanillaInfo.Source)
        $converted++
        $changed = $true
    }

    if ($changed) {
        $outText = ($newLines -join "`n") + "`n"
        $hasDiff = $false
        foreach ($l in $newLines) { if ($l -match '^diff --git ') { $hasDiff = $true; break } }
        if (-not $hasDiff) {
            Remove-Item $file.FullName -Force
            Write-Host ("  [del]  {0}: no diff left" -f $file.Name)
        } else {
            [System.IO.File]::WriteAllText($file.FullName, $outText)
        }
    }
}

Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("normalized: converted={0} dropped={1} skipped={2}" -f $converted, $dropped, $skipped)
