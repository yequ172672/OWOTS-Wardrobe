[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GameDirectory,

    [string]$BackupPath,

    # Allows an isolated dry run directory to omit the game executable.
    [switch]$AllowNonGame
)

$ErrorActionPreference = 'Stop'
$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifestPath = Join-Path $packageRoot 'release-manifest.json'

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-SafeRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path)) {
        throw "路径必须是相对路径：$Path"
    }
    $normalized = $Path.Replace('/', '\')
    if ($normalized -match '[:*?"<>|]' -or
        $normalized -match '(^|\\)\.\.($|\\)' -or
        $normalized -match '(^|\\)\.($|\\)') {
        throw "路径越界或包含不允许的字符：$Path"
    }
    return $normalized
}

function Assert-NoReparsePath([string]$Root, [string]$RelativePath) {
    $rootInfo = Get-Item -LiteralPath $Root
    if (($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "拒绝使用 reparse point 目录：$Root"
    }
    $normalized = if ($RelativePath) { Get-SafeRelativePath $RelativePath } else { '' }
    $current = $Root
    if ($normalized) {
        foreach ($part in $normalized.Split('\')) {
            $current = Join-Path $current $part
            if (Test-Path -LiteralPath $current) {
                $info = Get-Item -LiteralPath $current
                if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                    throw "拒绝经过 reparse point 的路径：$RelativePath"
                }
            }
        }
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $candidateFull = [IO.Path]::GetFullPath($current)
    if ($normalized -and -not $candidateFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "路径逃出根目录：$RelativePath"
    }
}

function Assert-GameStopped([string]$GamePath) {
    $exeFull = [IO.Path]::GetFullPath((Join-Path $GamePath 'OnimushaWotS.exe'))
    foreach ($process in @(Get-Process -Name 'OnimushaWotS' -ErrorAction SilentlyContinue)) {
        $processPath = $null
        try { $processPath = $process.Path } catch { }
        if (-not $processPath) { throw '检测到 OnimushaWotS 进程但无法读取其路径；请退出游戏后再卸载。' }
        if ([IO.Path]::GetFullPath($processPath).Equals($exeFull, [StringComparison]::OrdinalIgnoreCase)) {
            throw "游戏正在运行：$processPath。请退出游戏后再卸载。"
        }
    }
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "找不到发行清单：$manifestPath" }
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1) { throw "不支持的发行清单版本：$($manifest.schemaVersion)" }
$gamePath = [IO.Path]::GetFullPath($GameDirectory.TrimEnd('\', '/'))
if (-not (Test-Path -LiteralPath $gamePath -PathType Container)) { throw "游戏目录不存在：$gamePath" }
$gameExe = Join-Path $gamePath 'OnimushaWotS.exe'
if (-not (Test-Path -LiteralPath $gameExe -PathType Leaf) -and -not $AllowNonGame) {
    throw '未找到 OnimushaWotS.exe。若这是隔离测试目录，请加 -AllowNonGame。'
}
Assert-NoReparsePath $gamePath ''
Assert-GameStopped $gamePath

$backupBase = Join-Path $gamePath '.owots-appearance-backups'
$selectedBackup = $null
$backupManifest = $null
if ($BackupPath) {
    $selectedBackup = [IO.Path]::GetFullPath($BackupPath.TrimEnd('\', '/'))
    $baseFull = [IO.Path]::GetFullPath($backupBase).TrimEnd('\') + '\'
    if (-not $selectedBackup.StartsWith($baseFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw '-BackupPath 必须位于游戏目录下的 .owots-appearance-backups 内。'
    }
    $selectedRelative = $selectedBackup.Substring($baseFull.Length)
    Assert-NoReparsePath $gamePath ('.owots-appearance-backups\' + $selectedRelative)
    $backupManifestPath = Join-Path $selectedBackup 'backup-manifest.json'
    if (-not (Test-Path -LiteralPath $backupManifestPath -PathType Leaf)) { throw "备份目录缺少 backup-manifest.json：$selectedBackup" }
    $backupManifest = Get-Content -Raw -LiteralPath $backupManifestPath | ConvertFrom-Json
} else {
    if (Test-Path -LiteralPath $backupBase -PathType Container) {
        Assert-NoReparsePath $gamePath '.owots-appearance-backups'
        foreach ($candidate in @(Get-ChildItem -LiteralPath $backupBase -Directory | Sort-Object LastWriteTime -Descending)) {
            # A backup child can itself be a junction even when the backup root
            # is ordinary. Reject it before reading backup-manifest.json.
            Assert-NoReparsePath $gamePath ('.owots-appearance-backups\' + $candidate.Name)
            $candidateManifestPath = Join-Path $candidate.FullName 'backup-manifest.json'
            if (-not (Test-Path -LiteralPath $candidateManifestPath -PathType Leaf)) { continue }
            try { $candidateManifest = Get-Content -Raw -LiteralPath $candidateManifestPath | ConvertFrom-Json } catch { continue }
            if ([string]$candidateManifest.state -in @('committed', 'pending')) {
                $selectedBackup = $candidate.FullName
                $backupManifest = $candidateManifest
                break
            }
        }
    }
}
if (-not $backupManifest) { throw '找不到本包的安装备份。为避免误删，请指定有效的 -BackupPath。' }
if ($backupManifest.schemaVersion -ne 1) { throw "不支持的备份清单版本：$($backupManifest.schemaVersion)" }
if ([string]$backupManifest.packageVersion -ne [string]$manifest.packageVersion) {
    throw "备份属于其他发行包版本：$($backupManifest.packageVersion)"
}

$records = @($backupManifest.records)
$seenInstallPaths = @{}
$operations = @()
$warnings = @()

# Full preflight: validate every restore source before changing any target. This
# prevents a missing/corrupt backup from leaving the installation half removed.
foreach ($record in $records) {
    $relative = Get-SafeRelativePath ([string]$record.installPath)
    $key = $relative.ToLowerInvariant()
    if ($seenInstallPaths.ContainsKey($key)) { throw "备份清单存在重复目标：$relative" }
    $seenInstallPaths[$key] = $true
    Assert-NoReparsePath $gamePath $relative
    $target = Join-Path $gamePath $relative
    $action = [string]$record.action
    if (-not $action) {
        $action = if ([bool]$record.hadOriginal -and -not $record.backupRelativePath) { 'unchanged' } else { 'replaced' }
    }
    if ($action -eq 'unchanged') { continue }
    if ($action -notin @('created', 'replaced')) { throw "备份清单包含未知操作：$action" }
    if ($action -eq 'replaced') {
        $backupRelative = Get-SafeRelativePath ([string]$record.backupRelativePath)
        Assert-NoReparsePath $selectedBackup $backupRelative
        $backupFile = Join-Path $selectedBackup $backupRelative
        if (-not (Test-Path -LiteralPath $backupFile -PathType Leaf)) { throw "旧文件备份不存在：$relative" }
        $originalHash = ([string]$record.originalSha256).ToLowerInvariant()
        if (-not $originalHash -or (Get-Sha256 $backupFile) -ne $originalHash) {
            throw "旧文件备份哈希不匹配：$relative；未进行任何卸载操作。"
        }
    }
    $operations += [pscustomobject]@{ Action = $action; Record = $record; Target = $target; BackupFile = if ($action -eq 'replaced') { Join-Path $selectedBackup $backupRelative } else { $null } }
}

foreach ($operation in $operations) {
    $record = $operation.Record
    $target = $operation.Target
    $expected = ([string]$record.expectedSha256).ToLowerInvariant()
    $exists = Test-Path -LiteralPath $target -PathType Leaf
    $currentHash = if ($exists) { Get-Sha256 $target } else { $null }
    if ($exists -and $currentHash -ne $expected) {
        $warnings += "$($record.installPath)：当前文件已变化，保留原文件"
        Write-Host "已保留被修改的 $($record.installPath)" -ForegroundColor Yellow
        continue
    }
    try {
        if ($operation.Action -eq 'created') {
            if ($exists) {
                Remove-Item -LiteralPath $target -Force
                Write-Host "已移除 $($record.installPath)" -ForegroundColor Green
            }
            continue
        }

        # Copy to a temporary sibling and verify it before replacing the target.
        # A failed copy therefore leaves the package file intact.
        $temp = "$target.owots-restore-$([Guid]::NewGuid().ToString('N')).tmp"
        Copy-Item -LiteralPath $operation.BackupFile -Destination $temp -Force
        if ((Get-Sha256 $temp) -ne ([string]$record.originalSha256).ToLowerInvariant()) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
            throw '临时恢复文件哈希不匹配'
        }
        Move-Item -LiteralPath $temp -Destination $target -Force
        if ((Get-Sha256 $target) -ne ([string]$record.originalSha256).ToLowerInvariant()) {
            throw '恢复后哈希不匹配'
        }
        Write-Host "已恢复 $($record.installPath)" -ForegroundColor Cyan
    } catch {
        $warnings += "$($record.installPath)：$($_.Exception.Message)"
        Write-Host "未能处理 $($record.installPath)：$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

if ($warnings.Count -gt 0) {
    Write-Host '卸载完成，但有文件被保留或无法恢复；备份仍保留：' -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Host "  $_" }
    Write-Host $selectedBackup
    exit 1
}
Write-Host "衣橱测试包已卸载。备份仍保留在：$selectedBackup" -ForegroundColor Green
