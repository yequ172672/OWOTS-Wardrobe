[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Archive,
    [Parameter(Mandatory=$true)][string]$Destination,
    [long]$MaxTotalBytes = 8589934592,
    [long]$MaxFileBytes = 536870912,
    [int]$MaxEntries = 50000
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
            $item = Get-Item -LiteralPath $walk -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Linked path is not accepted: $walk"
            }
        }
        $parent = [IO.Directory]::GetParent($walk)
        if ($null -eq $parent) { break }
        $walk = $parent.FullName
    }
}

$archivePath = [IO.Path]::GetFullPath($Archive)
$outputPath = [IO.Path]::GetFullPath($Destination).TrimEnd('\','/')
Assert-NoReparse $archivePath
Assert-NoReparse $outputPath
if (-not [IO.File]::Exists($archivePath)) { throw 'Input archive does not exist' }
if ([IO.Path]::GetExtension($archivePath) -ine '.zip') { throw 'This helper accepts ZIP only; use a trusted installed extractor for RAR/7z' }
if (Test-Path -LiteralPath $outputPath) { throw 'Destination must not exist' }
if ($MaxTotalBytes -le 0 -or $MaxFileBytes -le 0 -or $MaxEntries -le 0) { throw 'Limits must be positive' }
$zip = [IO.Compression.ZipFile]::OpenRead($archivePath)
$plan = [Collections.Generic.List[object]]::new()
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$total = 0L
try {
    if ($zip.Entries.Count -gt $MaxEntries) { throw 'Archive entry limit exceeded' }
    foreach ($entry in $zip.Entries) {
        $name = $entry.FullName.Replace('\','/')
        $isDirectory = $name.EndsWith('/')
        $relative = $name.TrimEnd('/')
        if (-not $relative -or $name.StartsWith('/') -or $name -match '[\x00-\x1f:*?"<>|]') { throw "Unsafe archive path: $name" }
        foreach ($part in $relative.Split('/')) {
            if (-not $part -or $part -eq '.' -or $part -eq '..' -or $part -match '[. ]$' -or
                $part -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') { throw "Unsafe Windows path: $name" }
        }
        $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
        if ($unixType -notin @(0, 0x8000, 0x4000) -or ($entry.ExternalAttributes -band 0x400) -ne 0) {
            throw "Link or unsupported entry type: $name"
        }
        if (-not $seen.Add($relative)) { throw "Duplicate archive path: $name" }
        if ($entry.Length -lt 0 -or $entry.Length -gt $MaxFileBytes) { throw "File size limit exceeded: $name" }
        $total += $entry.Length
        if ($total -gt $MaxTotalBytes) { throw 'Archive expanded size limit exceeded' }
        $target = [IO.Path]::GetFullPath((Join-Path $outputPath $relative.Replace('/','\')))
        if (-not $target.StartsWith($outputPath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Path escaped output directory' }
        $plan.Add([pscustomobject]@{ Entry=$entry; Relative=$relative; Target=$target; Directory=$isDirectory })
    }
    # Reject a file which would have to become another entry's parent.
    $fileNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $plan) { if (-not $row.Directory) { [void]$fileNames.Add($row.Relative) } }
    foreach ($row in $plan) {
        $segments = $row.Relative.Split('/')
        for ($index = 1; $index -lt $segments.Length; $index++) {
            if ($fileNames.Contains(($segments[0..($index-1)] -join '/'))) { throw 'Archive file/directory collision' }
        }
    }
    [void][IO.Directory]::CreateDirectory($outputPath)
    foreach ($row in $plan) {
        if ($row.Directory) { [void][IO.Directory]::CreateDirectory($row.Target); continue }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($row.Target))
        $inputStream = $row.Entry.Open()
        $outputStream = [IO.File]::Open($row.Target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $buffer = New-Object byte[] 1048576
            $written = 0L
            while (($count = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $written += $count
                if ($written -gt $row.Entry.Length -or $written -gt $MaxFileBytes) { throw 'Decoded entry exceeds declared size' }
                $outputStream.Write($buffer, 0, $count)
            }
            if ($written -ne $row.Entry.Length) { throw 'Decoded entry length mismatch' }
        } finally { $outputStream.Dispose(); $inputStream.Dispose() }
    }
} finally { $zip.Dispose() }

$dynamic = @($plan | Where-Object { -not $_.Directory -and $_.Relative -match '(?i)\.(lua|dll|exe|ps1|cmd|bat|py|js)$' } | ForEach-Object { $_.Relative })
$paks = @($plan | Where-Object { -not $_.Directory -and $_.Relative -match '(?i)\.pak$' } | ForEach-Object { $_.Target })
$roots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($row in $plan) {
    if ($row.Relative -match '^(?i)(.*?)(?:natives)/stm/') {
        $prefix = $Matches[1].TrimEnd('/')
        if ($prefix) { [void]$roots.Add((Join-Path $outputPath $prefix)) } else { [void]$roots.Add($outputPath) }
    }
}
[pscustomobject]@{
    status='extracted'; archive=$archivePath; destination=$outputPath; entries=$plan.Count;
    expandedBytes=$total; sha256=(File-Sha256 $archivePath);
    looseRoots=@($roots); pakFiles=$paks; dynamicFiles=$dynamic;
    note='Inspect the entire inventory before choosing a root; no MOD script was executed.'
} | ConvertTo-Json -Depth 6
