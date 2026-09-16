#requires -Version 5.1

<#
.SYNOPSIS
    Finds an installed Onimusha: Way of the Sword (OWOTS) game directory.

.DESCRIPTION
    Discovery is deliberately bounded.  It reads SteamPath/InstallPath values
    from the Steam registry keys, the Steam libraryfolders.vdf files below those
    roots, and the appmanifest_*.acf files directly below each discovered
    steamapps directory.  It never recursively scans a drive or starts a
    program.  A HintPath is inspected directly when supplied.

    The command writes one JSON document to stdout.  A selected game is only
    returned when exactly one valid candidate exists.  Multiple valid
    installations produce an ambiguous result and no silent selection.

    FixtureRoot is an intentionally small test seam.  It replaces registry and
    common-location discovery with path lists in a fixture directory; it is
    not needed by players and does not read the host registry in that mode.

.PARAMETER HintPath
    An explicit game directory, or the OnimushaWotS.exe inside that directory.

.PARAMETER ToolRoot
    Optional converter release directory (or its OWOTS-ModConverter.exe).
    The command verifies OWOTS-ModConverter.exe and the side-by-side
    OWOTS_STM_Release.list without launching the executable.

.PARAMETER FixtureRoot
    Test-only discovery root.  If present, read optional
    registry-steam-paths.txt and common-steam-paths.txt files from this
    directory instead of querying the host registry/environment locations.

.OUTPUTS
    JSON on stdout.  Exit codes: 0 = one valid game (and valid ToolRoot when
    requested), 2 = no valid game, 3 = more than one valid game, 4 = invalid
    ToolRoot, 5 = discovery error.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$HintPath,

    [string]$ToolRoot,

    [string]$FixtureRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    $script:Utf8NoBom = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
    [Console]::OutputEncoding = $script:Utf8NoBom
    $OutputEncoding = $script:Utf8NoBom
}
catch {
    # JSON remains valid if an older host does not expose a writable console.
}

$script:TargetExecutable = 'OnimushaWotS.exe'
$script:TargetInstallDir = 'OnimushaWotS'
$script:TargetAppId = '2638890'
$script:TargetNameKey = 'onimushawayofthesword'
$script:SteamRoots = @{}
$script:LibraryRoots = @{}
$script:GameRoots = @{}
$script:Warnings = New-Object 'System.Collections.Generic.List[object]'
$script:Errors = New-Object 'System.Collections.Generic.List[object]'

function Add-DiscoveryWarning {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Path
    )

    $item = [ordered]@{
        code    = $Code
        message = $Message
    }
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $item['path'] = $Path
    }
    [void]$script:Warnings.Add($item)
}

function Add-DiscoveryError {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [string]$Path
    )

    $item = [ordered]@{
        code    = $Code
        message = $Message
    }
    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        $item['path'] = $Path
    }
    [void]$script:Errors.Add($item)
}

function ConvertTo-FullPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $candidate = $Path.Trim()
    if (($candidate.Length -ge 2) -and
        (($candidate[0] -eq '"') -and ($candidate[$candidate.Length - 1] -eq '"'))) {
        $candidate = $candidate.Substring(1, $candidate.Length - 2)
    }

    try {
        $resolved = Resolve-Path -LiteralPath $candidate -ErrorAction Stop
        return [System.IO.Path]::GetFullPath($resolved.Path)
    }
    catch {
        try {
            # GetFullPath is used for a not-yet-created test/game path too.  It
            # never interprets the value as PowerShell syntax.
            return [System.IO.Path]::GetFullPath($candidate)
        }
        catch {
            return $null
        }
    }
}

function Get-PathKey {
    param([Parameter(Mandatory = $true)][string]$Path)

    $value = $Path
    while (($value.Length -gt 3) -and
        ($value.EndsWith('\') -or $value.EndsWith('/'))) {
        $value = $value.Substring(0, $value.Length - 1)
    }
    return $value.ToUpperInvariant()
}

function Add-SteamRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Source,
        [string]$Detail
    )

    $full = ConvertTo-FullPath $Path
    if ([string]::IsNullOrWhiteSpace($full)) {
        Add-DiscoveryWarning -Code 'invalid_steam_path' -Message 'A Steam path could not be normalized.' -Path $Path
        return
    }

    $key = Get-PathKey $full
    if (-not $script:SteamRoots.ContainsKey($key)) {
        $script:SteamRoots[$key] = [ordered]@{
            path     = $full
            evidence = @()
        }
    }

    $evidence = [ordered]@{
        kind   = $Kind
        source = $Source
    }
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $evidence['detail'] = $Detail
    }
    $script:SteamRoots[$key].evidence += ,$evidence
}

function Add-LibraryRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Source,
        [string]$Detail
    )

    $full = ConvertTo-FullPath $Path
    if ([string]::IsNullOrWhiteSpace($full)) {
        Add-DiscoveryWarning -Code 'invalid_library_path' -Message 'A Steam library path could not be normalized.' -Path $Path
        return
    }

    $key = Get-PathKey $full
    if (-not $script:LibraryRoots.ContainsKey($key)) {
        $script:LibraryRoots[$key] = [ordered]@{
            path     = $full
            evidence = @()
        }
    }

    $evidence = [ordered]@{
        kind   = $Kind
        source = $Source
    }
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        $evidence['detail'] = $Detail
    }
    $script:LibraryRoots[$key].evidence += ,$evidence
}

function Add-GameRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Evidence
    )

    $full = ConvertTo-FullPath $Path
    if ([string]::IsNullOrWhiteSpace($full)) {
        Add-DiscoveryWarning -Code 'invalid_game_path' -Message 'A candidate game path could not be normalized.' -Path $Path
        return
    }

    $key = Get-PathKey $full
    if (-not $script:GameRoots.ContainsKey($key)) {
        $script:GameRoots[$key] = [ordered]@{
            path     = $full
            evidence = @()
        }
    }
    $script:GameRoots[$key].evidence += ,$Evidence
}

function Get-RegistrySteamRoots {
    # Values are read as strings and immediately treated as literal paths.  No
    # registry value is ever executed or passed to a command interpreter.
    $probes = @(
        [ordered]@{ hive = 'CurrentUser';  view = 'Default';    subKey = 'Software\Valve\Steam' },
        [ordered]@{ hive = 'LocalMachine'; view = 'Registry64'; subKey = 'SOFTWARE\Valve\Steam' },
        [ordered]@{ hive = 'LocalMachine'; view = 'Registry64'; subKey = 'SOFTWARE\WOW6432Node\Valve\Steam' },
        [ordered]@{ hive = 'LocalMachine'; view = 'Registry32'; subKey = 'SOFTWARE\Valve\Steam' },
        [ordered]@{ hive = 'LocalMachine'; view = 'Registry32'; subKey = 'SOFTWARE\WOW6432Node\Valve\Steam' }
    )

    foreach ($probe in $probes) {
        $base = $null
        $key = $null
        try {
            $hive = [System.Enum]::Parse([Microsoft.Win32.RegistryHive], [string]$probe.hive)
            $view = [System.Enum]::Parse([Microsoft.Win32.RegistryView], [string]$probe.view)
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, $view)
            $key = $base.OpenSubKey([string]$probe.subKey, $false)
            if ($null -eq $key) {
                continue
            }

            foreach ($valueName in @('SteamPath', 'InstallPath')) {
                $raw = $key.GetValue($valueName, $null)
                if ($null -eq $raw) {
                    continue
                }
                $path = [string]$raw
                if ([string]::IsNullOrWhiteSpace($path)) {
                    continue
                }
                if ($path -match '(?i)[\\/]steam\.exe$') {
                    $path = [System.IO.Path]::GetDirectoryName($path)
                }
                Add-SteamRoot -Path $path -Kind 'registry' -Source ("{0}:{1}:{2}" -f $probe.hive, $probe.view, $probe.subKey) -Detail $valueName
            }
        }
        catch {
            # Missing hives are normal on some Windows installations.  Keep a
            # bounded diagnostic rather than failing the entire discovery.
            Add-DiscoveryWarning -Code 'registry_probe_failed' -Message $_.Exception.Message -Path ("{0}:{1}:{2}" -f $probe.hive, $probe.view, $probe.subKey)
        }
        finally {
            if ($null -ne $key) {
                $key.Dispose()
            }
            if ($null -ne $base) {
                $base.Dispose()
            }
        }
    }
}

function Get-CommonSteamRoots {
    $locations = New-Object 'System.Collections.Generic.List[string]'

    $programFilesX86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    $programFiles = [Environment]::GetEnvironmentVariable('ProgramFiles')
    $localAppData = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
    $userProfile = [Environment]::GetEnvironmentVariable('USERPROFILE')
    $systemDrive = [Environment]::GetEnvironmentVariable('SystemDrive')

    foreach ($base in @($programFilesX86, $programFiles, $localAppData, $userProfile)) {
        if (-not [string]::IsNullOrWhiteSpace($base)) {
            [void]$locations.Add((Join-Path $base 'Steam'))
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($systemDrive)) {
        [void]$locations.Add((Join-Path $systemDrive 'Steam'))
    }
    # A small root-level check catches portable Steam installs without walking
    # the drive.  GetLogicalDrives only enumerates drive roots.
    try {
        foreach ($drive in [Environment]::GetLogicalDrives()) {
            [void]$locations.Add((Join-Path $drive 'Steam'))
        }
    }
    catch {
        Add-DiscoveryWarning -Code 'logical_drive_probe_failed' -Message $_.Exception.Message
    }

    $seen = @{}
    foreach ($location in $locations) {
        $full = ConvertTo-FullPath $location
        if ([string]::IsNullOrWhiteSpace($full)) {
            continue
        }
        $key = Get-PathKey $full
        if ($seen.ContainsKey($key)) {
            continue
        }
        $seen[$key] = $true
        if (Test-Path -LiteralPath $full -PathType Container) {
            Add-SteamRoot -Path $full -Kind 'commonLocation' -Source 'known Steam location'
        }
    }
}

function Get-EnvironmentSteamRoots {
    foreach ($name in @('SteamPath', 'STEAM_PATH')) {
        $raw = [Environment]::GetEnvironmentVariable($name)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            continue
        }
        $path = [string]$raw
        if ($path -match '(?i)[\\/]steam\.exe$') {
            $path = [System.IO.Path]::GetDirectoryName($path)
        }
        Add-SteamRoot -Path $path -Kind 'environment' -Source $name
    }
}

function Convert-VdfEscape {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Raw)

    $builder = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Raw.Length; $i++) {
        $character = $Raw[$i]
        if (($character -eq '\') -and (($i + 1) -lt $Raw.Length)) {
            $next = $Raw[$i + 1]
            $i++
            switch ($next) {
                '"' { [void]$builder.Append('"') }
                '\' { [void]$builder.Append('\') }
                'n'  { [void]$builder.Append("`n") }
                'r'  { [void]$builder.Append("`r") }
                't'  { [void]$builder.Append("`t") }
                default {
                    # Steam normally escapes only quotes and backslashes.  A
                    # different escape is preserved literally instead of being
                    # interpreted as code or silently changing a path.
                    [void]$builder.Append('\')
                    [void]$builder.Append($next)
                }
            }
        }
        else {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString()
}

function Get-VdfTokens {
    param([Parameter(Mandatory = $true)][string]$Text)

    $tokens = New-Object 'System.Collections.Generic.List[object]'
    $i = 0
    while ($i -lt $Text.Length) {
        $character = $Text[$i]
        if ([char]::IsWhiteSpace($character)) {
            $i++
            continue
        }
        if (($character -eq '/') -and (($i + 1) -lt $Text.Length) -and ($Text[$i + 1] -eq '/')) {
            $i += 2
            while (($i -lt $Text.Length) -and ($Text[$i] -ne "`n")) {
                $i++
            }
            continue
        }
        if (($character -eq '{') -or ($character -eq '}')) {
            [void]$tokens.Add([ordered]@{ kind = [string]$character; value = [string]$character })
            $i++
            continue
        }
        if ($character -eq '"') {
            $i++
            $raw = New-Object System.Text.StringBuilder
            $closed = $false
            while ($i -lt $Text.Length) {
                $current = $Text[$i]
                if ($current -eq '"') {
                    $i++
                    $closed = $true
                    break
                }
                if (($current -eq '\') -and (($i + 1) -lt $Text.Length)) {
                    [void]$raw.Append($current)
                    [void]$raw.Append($Text[$i + 1])
                    $i += 2
                    continue
                }
                [void]$raw.Append($current)
                $i++
            }
            if (-not $closed) {
                throw 'unterminated quoted VDF string'
            }
            [void]$tokens.Add([ordered]@{ kind = 'string'; value = (Convert-VdfEscape $raw.ToString()) })
            continue
        }

        $start = $i
        while ($i -lt $Text.Length) {
            $current = $Text[$i]
            if ([char]::IsWhiteSpace($current) -or ($current -eq '{') -or ($current -eq '}')) {
                break
            }
            $i++
        }
        if ($i -eq $start) {
            $i++
            continue
        }
        [void]$tokens.Add([ordered]@{ kind = 'bare'; value = $Text.Substring($start, $i - $start) })
    }
    return $tokens
}

function Read-VdfObject {
    param(
        [Parameter(Mandatory = $true)][object]$Tokens,
        [Parameter(Mandatory = $true)][ref]$Index
    )

    $node = [ordered]@{}
    while ($Index.Value -lt $Tokens.Count) {
        $token = $Tokens[$Index.Value]
        if ($token.kind -eq '}') {
            $Index.Value++
            return $node
        }
        if (($token.kind -eq '{') -or ($token.kind -eq 'string' -and [string]::IsNullOrWhiteSpace([string]$token.value))) {
            throw 'invalid VDF object key'
        }
        $key = [string]$token.value
        $Index.Value++
        if ($Index.Value -ge $Tokens.Count) {
            throw ("missing VDF value for key '{0}'" -f $key)
        }
        $next = $Tokens[$Index.Value]
        if ($next.kind -eq '{') {
            $Index.Value++
            $node[$key] = Read-VdfObject -Tokens $Tokens -Index $Index
        }
        elseif (($next.kind -eq 'string') -or ($next.kind -eq 'bare')) {
            $node[$key] = [string]$next.value
            $Index.Value++
        }
        else {
            throw ("invalid VDF value for key '{0}'" -f $key)
        }
    }
    return $node
}

function Read-VdfFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    $text = [System.IO.File]::ReadAllText($Path)
    $tokens = Get-VdfTokens $text
    if ($tokens.Count -eq 0) {
        throw 'empty VDF file'
    }
    $index = 0
    $root = [ordered]@{}
    while ($index -lt $tokens.Count) {
        $token = $tokens[$index]
        if (($token.kind -eq '{') -or ($token.kind -eq '}')) {
            throw 'invalid VDF top-level token'
        }
        $key = [string]$token.value
        $index++
        if ($index -ge $tokens.Count) {
            throw ("missing VDF top-level value for key '{0}'" -f $key)
        }
        $next = $tokens[$index]
        if ($next.kind -eq '{') {
            $index++
            $root[$key] = Read-VdfObject -Tokens $tokens -Index ([ref]$index)
        }
        elseif (($next.kind -eq 'string') -or ($next.kind -eq 'bare')) {
            $root[$key] = [string]$next.value
            $index++
        }
        else {
            throw ("invalid VDF top-level value for key '{0}'" -f $key)
        }
    }
    return $root
}

function Get-VdfValue {
    param(
        [AllowNull()][object]$Node,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $Node) {
        return $null
    }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) {
            if ([string]$key -ieq $Name) {
                return $Node[$key]
            }
        }
    }
    return $null
}

function Get-VdfPathValues {
    param([AllowNull()][object]$Node)

    if ($null -eq $Node) {
        return
    }
    if ($Node -is [System.Collections.IDictionary]) {
        foreach ($key in $Node.Keys) {
            $value = $Node[$key]
            if ([string]$key -ieq 'path' -and ($value -is [string])) {
                [ordered]@{ path = [string]$value; key = [string]$key }
            }
            if ($value -is [System.Collections.IDictionary]) {
                Get-VdfPathValues $value
            }
        }
    }
}

function Read-FixturePathList {
    param(
        [Parameter(Mandatory = $true)][string]$Fixture,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    $path = Join-Path $Fixture $FileName
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return @()
    }
    $lines = Get-Content -LiteralPath $path -ErrorAction Stop
    $values = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $lines) {
        $value = ([string]$line).Trim()
        if (($value.Length -eq 0) -or $value.StartsWith('#')) {
            continue
        }
        [void]$values.Add($value)
    }
    return $values
}

function Test-TargetManifest {
    param(
        [string]$AppId,
        [string]$Name,
        [string]$InstallDir
    )

    $reasons = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($AppId) -and ($AppId -eq $script:TargetAppId)) {
        [void]$reasons.Add('appid')
    }
    if (-not [string]::IsNullOrWhiteSpace($InstallDir) -and ($InstallDir -ieq $script:TargetInstallDir)) {
        [void]$reasons.Add('installdir')
    }
    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $nameKey = (($Name.ToLowerInvariant()) -replace '[^a-z0-9]', '')
        if ($nameKey -eq $script:TargetNameKey) {
            [void]$reasons.Add('name')
        }
    }
    return $reasons
}

function Add-ManifestCandidates {
    param(
        [Parameter(Mandatory = $true)][string]$LibraryPath,
        [Parameter(Mandatory = $true)][object]$LibraryEvidence
    )

    $steamApps = Join-Path $LibraryPath 'steamapps'
    if (-not (Test-Path -LiteralPath $steamApps -PathType Container)) {
        return
    }

    $manifestFiles = @(Get-ChildItem -LiteralPath $steamApps -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -imatch '^appmanifest_[0-9]+\.acf$' })
    foreach ($manifest in $manifestFiles) {
        try {
            $document = Read-VdfFile -Path $manifest.FullName
            $state = Get-VdfValue -Node $document -Name 'AppState'
            if ($null -eq $state) {
                $state = $document
            }
            $appId = [string](Get-VdfValue -Node $state -Name 'appid')
            $name = [string](Get-VdfValue -Node $state -Name 'name')
            $installDir = [string](Get-VdfValue -Node $state -Name 'installdir')
            $matchReasons = @(Test-TargetManifest -AppId $appId -Name $name -InstallDir $installDir)
            if ($matchReasons.Count -eq 0) {
                continue
            }
            if ([string]::IsNullOrWhiteSpace($installDir)) {
                Add-DiscoveryWarning -Code 'target_manifest_missing_installdir' -Message 'A target appmanifest has no installdir.' -Path $manifest.FullName
                continue
            }
            if ([System.IO.Path]::IsPathRooted($installDir) -or
                ($installDir -match '(^|[\\/])\.\.([\\/]|$)')) {
                Add-DiscoveryWarning -Code 'unsafe_manifest_installdir' -Message 'A target appmanifest installdir is absolute or escapes steamapps\common.' -Path $manifest.FullName
                continue
            }

            $common = Join-Path $LibraryPath 'steamapps\common'
            $gamePath = Join-Path $common $installDir
            $evidence = [ordered]@{
                kind        = 'appmanifest'
                source      = $manifest.FullName
                libraryPath = $LibraryPath
                appid       = $appId
                name        = $name
                installdir  = $installDir
                matchedBy   = $matchReasons
            }
            Add-GameRoot -Path $gamePath -Evidence $evidence
        }
        catch {
            Add-DiscoveryWarning -Code 'appmanifest_parse_failed' -Message $_.Exception.Message -Path $manifest.FullName
        }
    }
}

function Get-PEPrefix {
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = [ordered]@{
        readable = $false
        mz       = $false
    }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $bytes = New-Object byte[] 2
        $read = $stream.Read($bytes, 0, 2)
        $result.readable = ($read -eq 2)
        $result.mz = $result.readable -and ($bytes[0] -eq 0x4d) -and ($bytes[1] -eq 0x5a)
    }
    catch {
        $result['error'] = $_.Exception.Message
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
    return $result
}

function Get-PakPrefix {
    param([Parameter(Mandatory = $true)][string]$Path)

    $result = [ordered]@{
        readable = $false
        magic    = $null
        kpka     = $false
    }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $bytes = New-Object byte[] 4
        $read = $stream.Read($bytes, 0, 4)
        $result.readable = ($read -eq 4)
        if ($result.readable) {
            $result.magic = ([Text.Encoding]::ASCII.GetString($bytes))
            $result.kpka = ($result.magic -eq 'KPKA')
        }
    }
    catch {
        $result['error'] = $_.Exception.Message
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
    return $result
}

function Validate-GameRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Evidence
    )

    $rootExists = Test-Path -LiteralPath $Path -PathType Container
    $exeCandidates = @()
    $pakCandidates = @()
    if ($rootExists) {
        $files = @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue)
        $exeCandidates = @($files | Where-Object { $_.Name -ieq $script:TargetExecutable })
        $pakCandidates = @($files | Where-Object { $_.Name -imatch '^re_chunk.*\.pak$' })
    }

    $exeEvidence = [ordered]@{
        expectedName = $script:TargetExecutable
        found        = ($exeCandidates.Count -gt 0)
        count        = $exeCandidates.Count
        files        = @()
    }
    $exeValid = $false
    foreach ($exe in $exeCandidates) {
        $prefix = Get-PEPrefix -Path $exe.FullName
        $exeEvidence.files += ,[ordered]@{
            path       = $exe.FullName
            length     = [int64]$exe.Length
            readable   = [bool]$prefix.readable
            mz         = [bool]$prefix.mz
            valid      = ([bool]$prefix.mz -and ($exe.Length -gt 1))
        }
        if ($prefix.mz -and ($exe.Length -gt 1)) {
            $exeValid = $true
        }
    }

    $pakEvidence = [ordered]@{
        pattern           = 're_chunk*.pak'
        found             = ($pakCandidates.Count -gt 0)
        count             = $pakCandidates.Count
        nonEmptyCount     = 0
        kpkaCount         = 0
        files             = @()
    }
    foreach ($pak in $pakCandidates) {
        $prefix = Get-PakPrefix -Path $pak.FullName
        $nonEmpty = ($pak.Length -gt 0)
        if ($nonEmpty) {
            $pakEvidence.nonEmptyCount++
        }
        if ($prefix.kpka) {
            $pakEvidence.kpkaCount++
        }
        $pakEvidence.files += ,[ordered]@{
            path     = $pak.FullName
            length   = [int64]$pak.Length
            readable = [bool]$prefix.readable
            magic    = $prefix.magic
            kpka     = [bool]$prefix.kpka
            valid    = ($nonEmpty -and [bool]$prefix.kpka)
        }
    }

    $reasons = New-Object 'System.Collections.Generic.List[string]'
    if (-not $rootExists) {
        [void]$reasons.Add('game_root_missing')
    }
    if (-not $exeValid) {
        [void]$reasons.Add('OnimushaWotS.exe_missing_or_invalid_PE')
    }
    if ($pakEvidence.kpkaCount -eq 0) {
        [void]$reasons.Add('re_chunk_pak_missing_or_not_KPKA')
    }

    return [ordered]@{
        path       = $Path
        valid      = ($rootExists -and $exeValid -and ($pakEvidence.kpkaCount -gt 0))
        evidence   = @($Evidence)
        validation = [ordered]@{
            directoryExists = $rootExists
            executable      = $exeEvidence
            pak             = $pakEvidence
        }
        rejectionReasons = @($reasons | ForEach-Object { $_ })
    }
}

function Validate-ToolRoot {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [ordered]@{
            requested = $false
            valid     = $true
            path      = $null
            executable = [ordered]@{ expectedName = 'OWOTS-ModConverter.exe'; found = $false; required = $false }
            hashList   = [ordered]@{ expectedName = 'OWOTS_STM_Release.list'; found = $false; required = $false }
        }
    }

    $full = ConvertTo-FullPath $Path
    $root = $full
    if (-not [string]::IsNullOrWhiteSpace($root) -and ($root -imatch '\.exe$')) {
        $root = [System.IO.Path]::GetDirectoryName($root)
    }
    $result = [ordered]@{
        requested = $true
        valid     = $false
        path      = $root
        executable = [ordered]@{
            expectedName = 'OWOTS-ModConverter.exe'
            path         = $null
            found        = $false
            readable     = $false
            mz           = $false
        }
        hashList = [ordered]@{
            expectedName = 'OWOTS_STM_Release.list'
            path         = $null
            found        = $false
            nonEmpty     = $false
        }
        rejectionReasons = @()
    }
    $reasons = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrWhiteSpace($root) -or (-not (Test-Path -LiteralPath $root -PathType Container))) {
        [void]$reasons.Add('tool_root_missing')
    }
    else {
        $exePath = Join-Path $root 'OWOTS-ModConverter.exe'
        $listPath = Join-Path $root 'OWOTS_STM_Release.list'
        $result.executable.path = $exePath
        $result.hashList.path = $listPath
        if (Test-Path -LiteralPath $exePath -PathType Leaf) {
            $result.executable.found = $true
            $prefix = Get-PEPrefix -Path $exePath
            $result.executable.readable = [bool]$prefix.readable
            $result.executable.mz = [bool]$prefix.mz
        }
        if (Test-Path -LiteralPath $listPath -PathType Leaf) {
            $result.hashList.found = $true
            $result.hashList.nonEmpty = ((Get-Item -LiteralPath $listPath).Length -gt 0)
        }
        if (-not ($result.executable.found -and $result.executable.mz)) {
            [void]$reasons.Add('OWOTS-ModConverter.exe_missing_or_invalid_PE')
        }
        if (-not ($result.hashList.found -and $result.hashList.nonEmpty)) {
            [void]$reasons.Add('OWOTS_STM_Release.list_missing_or_empty')
        }
    }
    $result.rejectionReasons = @($reasons | ForEach-Object { $_ })
    $result.valid = ($reasons.Count -eq 0)
    return $result
}

function Add-HintCandidate {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return
    }
    $full = ConvertTo-FullPath $Path
    if ([string]::IsNullOrWhiteSpace($full)) {
        Add-DiscoveryWarning -Code 'invalid_hint_path' -Message 'HintPath could not be normalized.' -Path $Path
        return
    }
    if ($full -imatch '\.exe$') {
        $full = [System.IO.Path]::GetDirectoryName($full)
    }
    $evidence = [ordered]@{
        kind   = 'hintPath'
        source = 'user'
        input  = $Path
    }
    Add-GameRoot -Path $full -Evidence $evidence
}

function Add-LibrariesFromSteamRoots {
    foreach ($record in @($script:SteamRoots.Values)) {
        $steamRoot = [string]$record.path
        $defaultSteamApps = Join-Path $steamRoot 'steamapps'
        if (Test-Path -LiteralPath $defaultSteamApps -PathType Container) {
            Add-LibraryRoot -Path $steamRoot -Kind 'steamRoot' -Source $steamRoot
        }

        $vdfPath = Join-Path $defaultSteamApps 'libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $vdfPath -PathType Leaf)) {
            continue
        }
        try {
            $document = Read-VdfFile -Path $vdfPath
            $pathValues = @(Get-VdfPathValues -Node $document)
            foreach ($item in $pathValues) {
                if (-not [string]::IsNullOrWhiteSpace([string]$item.path)) {
                    Add-LibraryRoot -Path ([string]$item.path) -Kind 'libraryfolders.vdf' -Source $vdfPath -Detail 'path'
                }
            }
        }
        catch {
            Add-DiscoveryWarning -Code 'libraryfolders_parse_failed' -Message $_.Exception.Message -Path $vdfPath
        }
    }
}

function Add-ManifestCandidatesFromLibraries {
    foreach ($record in @($script:LibraryRoots.Values)) {
        $libraryPath = [string]$record.path
        $steamApps = Join-Path $libraryPath 'steamapps'
        if (-not (Test-Path -LiteralPath $steamApps -PathType Container)) {
            continue
        }
        Add-ManifestCandidates -LibraryPath $libraryPath -LibraryEvidence $record.evidence
    }
}

$fatal = $false
try {
    Add-HintCandidate -Path $HintPath

    if (-not [string]::IsNullOrWhiteSpace($FixtureRoot)) {
        $fixture = ConvertTo-FullPath $FixtureRoot
        if ([string]::IsNullOrWhiteSpace($fixture) -or (-not (Test-Path -LiteralPath $fixture -PathType Container))) {
            Add-DiscoveryError -Code 'fixture_root_missing' -Message 'FixtureRoot must be an existing directory.' -Path $FixtureRoot
            $fatal = $true
        }
        else {
            foreach ($path in @(Read-FixturePathList -Fixture $fixture -FileName 'registry-steam-paths.txt')) {
                Add-SteamRoot -Path $path -Kind 'fixtureRegistry' -Source (Join-Path $fixture 'registry-steam-paths.txt')
            }
            foreach ($path in @(Read-FixturePathList -Fixture $fixture -FileName 'common-steam-paths.txt')) {
                Add-SteamRoot -Path $path -Kind 'fixtureCommonLocation' -Source (Join-Path $fixture 'common-steam-paths.txt')
            }
        }
    }
    else {
        Get-RegistrySteamRoots
        Get-EnvironmentSteamRoots
        Get-CommonSteamRoots
    }

    if (-not $fatal) {
        Add-LibrariesFromSteamRoots
        Add-ManifestCandidatesFromLibraries
    }
}
catch {
    Add-DiscoveryError -Code 'discovery_failed' -Message $_.Exception.Message
    $fatal = $true
}

$candidates = New-Object 'System.Collections.Generic.List[object]'
foreach ($record in @($script:GameRoots.Values)) {
    try {
        [void]$candidates.Add((Validate-GameRoot -Path ([string]$record.path) -Evidence $record.evidence))
    }
    catch {
        [void]$candidates.Add([ordered]@{
            path             = [string]$record.path
            valid            = $false
            evidence         = @($record.evidence)
            validation       = $null
            rejectionReasons = @('candidate_validation_failed')
        })
        Add-DiscoveryWarning -Code 'candidate_validation_failed' -Message $_.Exception.Message -Path ([string]$record.path)
    }
}

$toolValidation = Validate-ToolRoot -Path $ToolRoot
$validCandidates = @($candidates | Where-Object { $_.valid -eq $true })
$ambiguous = ($validCandidates.Count -gt 1)
$selected = $null
$requestHintPath = $null
$requestToolRoot = $null
if (-not [string]::IsNullOrWhiteSpace($HintPath)) {
    $requestHintPath = $HintPath
}
if (-not [string]::IsNullOrWhiteSpace($ToolRoot)) {
    $requestToolRoot = $ToolRoot
}
$status = 'no_valid_game'
$exitCode = 2
if ($fatal) {
    $status = 'discovery_error'
    $exitCode = 5
}
elseif (-not $toolValidation.valid) {
    $status = 'tool_invalid'
    $exitCode = 4
}
elseif ($ambiguous) {
    $status = 'ambiguous'
    $exitCode = 3
}
elseif ($validCandidates.Count -eq 1) {
    $status = 'selected'
    $exitCode = 0
    $selected = $validCandidates[0]
}

$result = [ordered]@{
    schemaVersion = 1
    tool          = 'Find-OWOTSGame'
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    status        = $status
    exitCode      = $exitCode
    target        = [ordered]@{
        executable = $script:TargetExecutable
        appid      = $script:TargetAppId
        installdir = $script:TargetInstallDir
        title      = 'Onimusha: Way of the Sword'
    }
    request       = [ordered]@{
        hintPath    = $requestHintPath
        toolRoot    = $requestToolRoot
        fixtureMode = (-not [string]::IsNullOrWhiteSpace($FixtureRoot))
    }
    discovery     = [ordered]@{
        steamRoots   = @($script:SteamRoots.Values)
        libraryRoots = @($script:LibraryRoots.Values)
        scope        = @(
            'Steam registry SteamPath/InstallPath',
            'SteamPath environment value',
            'Steam libraryfolders.vdf path values',
            'steamapps appmanifest_*.acf installdir values',
            'known Steam locations',
            'explicit HintPath'
        )
        recursiveDriveScan = $false
        programsStarted    = $false
    }
    candidates    = @($candidates | ForEach-Object { $_ })
    validCandidateCount = $validCandidates.Count
    ambiguity    = [ordered]@{
        isAmbiguous    = $ambiguous
        validCandidates = @($validCandidates | ForEach-Object { $_.path })
        selectionRule  = 'select only when exactly one valid candidate exists'
    }
    selected      = $selected
    toolValidation = $toolValidation
    warnings      = @($script:Warnings | ForEach-Object { $_ })
    errors        = @($script:Errors | ForEach-Object { $_ })
}

Write-Output ($result | ConvertTo-Json -Depth 12)
exit $exitCode
