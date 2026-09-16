[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConvertedRoot,
    [Parameter(Mandatory=$true)][string]$Archive,
    [string]$ReviewedExperimentalReason
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function File-Sha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
    finally { $hasher.Dispose(); $stream.Dispose() }
}

function Assert-NoReparse([string]$Path) {
    $walk = [IO.Path]::GetFullPath($Path)
    while ($walk) {
        if (Test-Path -LiteralPath $walk) {
            if (((Get-Item -LiteralPath $walk -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked path: $walk" }
        }
        $parent = [IO.Directory]::GetParent($walk)
        if ($null -eq $parent) { break }
        $walk = $parent.FullName
    }
}
function Require-Resource([string]$Logical, [string]$Extension, [string]$Version) {
    if (-not $Logical -or $Logical -notmatch ('(?i)\.' + $Extension + '$') -or $Logical -match '[\x00-\x1f:@*?"<>|\\]' -or
        $Logical.StartsWith('/') -or @($Logical.Split('/') | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) { throw "Invalid resource path: $Logical" }
    $path = [IO.Path]::GetFullPath((Join-Path $rootPath ('natives/stm/' + $Logical + '.' + $Version)))
    if (-not $path.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase) -or -not [IO.File]::Exists($path)) { throw "Manifest resource missing: $Logical" }
    Assert-NoReparse $path
}

$rootPath = [IO.Path]::GetFullPath($ConvertedRoot).TrimEnd('\','/')
$archivePath = [IO.Path]::GetFullPath($Archive)
Assert-NoReparse $rootPath
Assert-NoReparse $archivePath
if (-not [IO.Directory]::Exists($rootPath)) { throw 'Converted directory is missing' }
if ([IO.Path]::GetExtension($archivePath) -ine '.zip' -or (Test-Path -LiteralPath $archivePath)) { throw 'Archive must be a new .zip path' }
if ($archivePath.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Archive must be outside converted directory' }
$reportPath = Join-Path $rootPath 'conversion-report.json'
$report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($report.status -ne 'converted' -or @($report.issues | Where-Object severity -eq 'error').Count) { throw 'Conversion report is not successful' }
$experimentalCodes = @('UNCONSUMED_MOD_RESOURCE','GAME_ASSET_UNVERIFIED','DYNAMIC_BEHAVIOR_UNSUPPORTED','CRC_MISMATCH')
$experimentalIssues = @($report.issues | Where-Object { $_.code -in $experimentalCodes })
if ($experimentalIssues.Count -and (-not $ReviewedExperimentalReason -or $ReviewedExperimentalReason.Trim().Length -lt 20)) {
    throw 'Experimental/partial conversion requires an explicit, evidence-based ReviewedExperimentalReason and an experimental deliverable scope'
}

$files = [Collections.Generic.List[IO.FileInfo]]::new()
if (Test-Path -LiteralPath (Join-Path $rootPath 'AI-EXPERIMENTAL-PACKAGING.md')) {
    throw 'Reserved packaging note already exists; retain the original conversion output and review its provenance'
}
$directories = [Collections.Generic.Queue[string]]::new()
$directories.Enqueue($rootPath)
while ($directories.Count) {
    $directory = $directories.Dequeue()
    foreach ($item in Get-ChildItem -LiteralPath $directory -Force) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Linked package entry: $($item.FullName)" }
        if ($item.PSIsContainer) { $directories.Enqueue($item.FullName) }
        else {
            if ($item.Extension -match '^(?i)\.(lua|dll|exe|ps1|cmd|bat|py|js|pak)$') { throw 'Static pack helper does not publish scripts, binaries or source PAKs' }
            $files.Add($item)
        }
    }
}
$manifests = @($files | Where-Object Name -eq 'manifest.json')
if (-not $manifests.Count) { throw 'No wardrobe manifest exists' }
$ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$entries = [Collections.Generic.List[object]]::new()
$allowedParts = @{body=@('BODY','BODY_SUB','HEAD','HAIR'); cloak=@('CLOAK'); gauntlet=@('GAUNTLET'); weapon=@('WEAPON','SHEATH','WEAPON_SUB','SHEATH_SUB','BOW')}
foreach ($file in $manifests) {
    $manifest = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 2 -or $manifest.category -cnotin @('body','cloak','gauntlet','weapon') -or
        $manifest.id -cnotmatch '^[a-z0-9][a-z0-9._-]{0,127}$' -or -not $manifest.name) { throw 'Invalid manifest schema/category/id/name' }
    if (Test-Path -LiteralPath (Join-Path $file.DirectoryName 'modinfo.ini')) { throw 'Adjacent modinfo.ini can override manifest rules; use an independently verified special packaging workflow' }
    if (-not $ids.Add($manifest.id)) { throw 'Duplicate wardrobe ID' }
    if (-not @($manifest.parts).Count) { throw 'Manifest parts are empty' }
    $parts = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($part in $manifest.parts) {
        if ($part.part -cnotin $allowedParts[$manifest.category]) { throw 'Manifest part does not belong to its category' }
        if (-not $parts.Add($part.part)) { throw 'Duplicate manifest part' }
        Require-Resource $part.catalog 'user' '3'
        Require-Resource $part.prefab 'pfb' '18'
    }
    foreach ($hidden in @($manifest.rules.hideParts)) {
        if ($hidden -cnotin @('BODY','BODY_SUB','HEAD','HAIR','CLOAK','GAUNTLET','WEAPON','SHEATH','WEAPON_SUB','SHEATH_SUB','BOW') -or $parts.Contains($hidden)) { throw 'Invalid hidden/provided part combination' }
    }
    foreach ($category in @($manifest.rules.incompatibleCategories)) {
        if ($category -cnotin @('body','cloak','gauntlet','weapon') -or $category -ceq $manifest.category) { throw 'Invalid incompatible category' }
    }
    $entries.Add([pscustomobject]@{id=$manifest.id; category=$manifest.category; parts=@($parts)})
}
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($archivePath))
$zipStream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$zip = [IO.Compression.ZipArchive]::new($zipStream, [IO.Compression.ZipArchiveMode]::Create, $false)
try {
    if ($experimentalIssues.Count) {
        $note = $zip.CreateEntry('AI-EXPERIMENTAL-PACKAGING.md')
        $writer = [IO.StreamWriter]::new($note.Open(), [Text.UTF8Encoding]::new($false))
        try { $writer.Write("# Experimental static test package`n`n$ReviewedExperimentalReason`n`nReview conversion-report.json; game visuals and dynamic equivalence are not established.`n") }
        finally { $writer.Dispose() }
    }
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($rootPath.Length + 1).Replace('\','/')
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $file.FullName, $relative, [IO.Compression.CompressionLevel]::Optimal)
    }
} finally { $zip.Dispose(); $zipStream.Dispose() }
[pscustomobject]@{status=$(if ($experimentalIssues.Count) {'packaged_experimental'} else {'packaged'}); archive=$archivePath; bytes=(Get-Item -LiteralPath $archivePath).Length;
    sha256=(File-Sha256 $archivePath);
    entries=@($entries); fileCount=$files.Count; gameVisualTested=$false} | ConvertTo-Json -Depth 6
