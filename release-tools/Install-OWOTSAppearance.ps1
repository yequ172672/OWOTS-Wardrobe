[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GameDirectory,

    [switch]$Force,

    [switch]$NoBackup,

    # Allows the parent directory used by an isolated dry run to omit the game executable.
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
        throw "清单包含无效的相对路径：$Path"
    }
    $normalized = $Path.Replace('/', '\')
    if ($normalized -match '[:*?"<>|]' -or
        $normalized -match '(^|\\)\.\.($|\\)' -or
        $normalized -match '(^|\\)\.($|\\)') {
        throw "清单路径越界或包含不允许的字符：$Path"
    }
    return $normalized
}

function Assert-NoReparsePath([string]$Root, [string]$RelativePath) {
    $rootInfo = Get-Item -LiteralPath $Root
    if (($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "拒绝使用 reparse point 游戏目录：$Root"
    }
    $normalized = if ($RelativePath) { Get-SafeRelativePath $RelativePath } else { '' }
    $parts = if ($normalized) { $normalized.Split('\') } else { @() }
    $current = $Root
    foreach ($part in $parts) {
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            $info = Get-Item -LiteralPath $current
            if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "拒绝经过 reparse point 的目标路径：$RelativePath"
            }
        }
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $candidateFull = [IO.Path]::GetFullPath($current)
    if ($normalized -and -not $candidateFull.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "目标路径逃出游戏目录：$RelativePath"
    }
}

function Write-TransactionState($Transaction, [string]$Path, [string]$State, [string]$Failure = $null) {
    $Transaction.state = $State
    $updated = (Get-Date).ToUniversalTime().ToString('o')
    if ($Transaction.PSObject.Properties['updatedUtc']) { $Transaction.updatedUtc = $updated }
    else { $Transaction | Add-Member -NotePropertyName updatedUtc -NotePropertyValue $updated }
    if ($Failure) {
        if ($Transaction.PSObject.Properties['failure']) { $Transaction.failure = $Failure }
        else { $Transaction | Add-Member -NotePropertyName failure -NotePropertyValue $Failure }
    }
    $Transaction | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "找不到发行清单：$manifestPath"
}
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1) {
    throw "不支持的发行清单版本：$($manifest.schemaVersion)"
}

$gamePath = [IO.Path]::GetFullPath($GameDirectory.TrimEnd('\', '/'))
if (-not (Test-Path -LiteralPath $gamePath -PathType Container)) {
    throw "游戏目录不存在：$gamePath"
}
$gameExe = Join-Path $gamePath 'OnimushaWotS.exe'
if (-not (Test-Path -LiteralPath $gameExe -PathType Leaf) -and -not $AllowNonGame) {
    throw "未找到 OnimushaWotS.exe。若这是隔离测试目录，请加 -AllowNonGame。"
}
Assert-NoReparsePath $gamePath ''

# A file can be replaced while the game is running. Refuse the operation before
# creating a backup if the process path is the selected game executable. If the
# process exists but Windows will not disclose its path, fail closed as well.
$gameExeFull = [IO.Path]::GetFullPath($gameExe)
foreach ($process in @(Get-Process -Name 'OnimushaWotS' -ErrorAction SilentlyContinue)) {
    $processPath = $null
    try { $processPath = $process.Path } catch { }
    if (-not $processPath) {
        throw '检测到 OnimushaWotS 进程但无法读取其路径；请退出游戏后再安装。'
    }
    if ([IO.Path]::GetFullPath($processPath).Equals($gameExeFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "游戏正在运行：$processPath。请退出游戏后再安装。"
    }
}

$installItems = @($manifest.files | Where-Object { $_.installPath })
if ($installItems.Count -eq 0) { throw '发行清单没有可安装文件。' }

$items = @()
$seenInstallPaths = @{}
$conflicts = @()
foreach ($entry in $installItems) {
    $packageRelative = Get-SafeRelativePath ([string]$entry.path)
    $installRelative = Get-SafeRelativePath ([string]$entry.installPath)
    $installKey = $installRelative.ToLowerInvariant()
    if ($seenInstallPaths.ContainsKey($installKey)) {
        throw "发行清单存在重复 installPath：$installRelative"
    }
    $seenInstallPaths[$installKey] = $true
    $sourcePath = Join-Path $packageRoot $packageRelative
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "发行包缺少文件：$packageRelative"
    }
    $sourceHash = Get-Sha256 $sourcePath
    $expectedHash = ([string]$entry.sha256).ToLowerInvariant()
    if ($sourceHash -ne $expectedHash) {
        throw "发行包文件哈希不匹配：$packageRelative"
    }
    $targetPath = Join-Path $gamePath ($installRelative.Replace('/', '\'))
    Assert-NoReparsePath $gamePath $installRelative
    $exists = Test-Path -LiteralPath $targetPath -PathType Leaf
    $currentHash = if ($exists) { Get-Sha256 $targetPath } else { $null }
    $same = $exists -and $currentHash -eq $expectedHash
    if ($exists -and -not $same) { $conflicts += $installRelative }
    $items += [pscustomobject]@{
        Entry = $entry
        PackageRelative = $packageRelative.Replace('\', '/')
        InstallRelative = $installRelative.Replace('\', '/')
        SourcePath = $sourcePath
        TargetPath = $targetPath
        Exists = $exists
        CurrentHash = $currentHash
        Same = $same
    }
}

if ($conflicts.Count -gt 0 -and -not $Force) {
    Write-Host '发现以下文件已有不同内容，安装已停止：' -ForegroundColor Yellow
    $conflicts | ForEach-Object { Write-Host "  $_" }
    Write-Host '确认退出游戏后重新执行并加 -Force；-Force 会先备份这些文件。' -ForegroundColor Yellow
    exit 1
}
if ($conflicts.Count -gt 0 -and $NoBackup) {
    throw '存在需要替换的文件时不能使用 -NoBackup。请移除 -NoBackup 以保留回滚副本。'
}

$changedItems = @($items | Where-Object { -not $_.Same })
$backupPath = $null
$transactionPath = $null
$records = @()
$transaction = $null
if ($changedItems.Count -gt 0) {
    $backupBase = Join-Path $gamePath '.owots-appearance-backups'
    if (Test-Path -LiteralPath $backupBase) { Assert-NoReparsePath $gamePath '.owots-appearance-backups' }
    else { New-Item -ItemType Directory -Path $backupBase -Force | Out-Null }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssfffZ')
    $backupPath = Join-Path $backupBase $stamp
    $suffix = 0
    while (Test-Path -LiteralPath $backupPath) {
        $suffix++
        $backupPath = Join-Path $backupBase ("$stamp-$suffix")
    }
    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
    Assert-NoReparsePath $gamePath ('.owots-appearance-backups\' + (Split-Path -Leaf $backupPath))

    foreach ($item in $items) {
        $record = [pscustomobject]@{
            path = $item.PackageRelative
            installPath = $item.InstallRelative
            expectedSha256 = ([string]$item.Entry.sha256).ToLowerInvariant()
            hadOriginal = [bool]$item.Exists
            originalSha256 = if ($item.CurrentHash) { $item.CurrentHash.ToLowerInvariant() } else { $null }
            backupRelativePath = if ($item.Exists -and -not $item.Same) { $item.InstallRelative } else { $null }
            action = if ($item.Same) { 'unchanged' } elseif ($item.Exists) { 'replaced' } else { 'created' }
        }
        $records += $record
    }

    # Back up every file before publishing a pending transaction. If a backup
    # cannot be made, no target file has been touched yet.
    foreach ($record in @($records | Where-Object { $_.action -eq 'replaced' })) {
        $item = $items | Where-Object { $_.InstallRelative -eq $record.installPath } | Select-Object -First 1
        $backupFile = Join-Path $backupPath ($record.backupRelativePath.Replace('/', '\'))
        $backupParent = Split-Path -Parent $backupFile
        if (-not (Test-Path -LiteralPath $backupParent -PathType Container)) { New-Item -ItemType Directory -Path $backupParent -Force | Out-Null }
        Copy-Item -LiteralPath $item.TargetPath -Destination $backupFile -Force
        if ((Get-Sha256 $backupFile) -ne $record.originalSha256) { throw "备份校验失败：$($record.installPath)" }
    }
    $transactionPath = Join-Path $backupPath 'backup-manifest.json'
    $transaction = [pscustomobject]@{
        schemaVersion = 1
        packageVersion = [string]$manifest.packageVersion
        installedUtc = (Get-Date).ToUniversalTime().ToString('o')
        packageManifestSha256 = Get-Sha256 $manifestPath
        state = 'pending'
        records = $records
    }
    $transaction | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $transactionPath -Encoding UTF8
}

try {
    foreach ($item in $changedItems) {
        $targetParent = Split-Path -Parent $item.TargetPath
        if (-not (Test-Path -LiteralPath $targetParent -PathType Container)) {
            New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        }
        Assert-NoReparsePath $gamePath $item.InstallRelative
        Copy-Item -LiteralPath $item.SourcePath -Destination $item.TargetPath -Force
        Write-Host "已安装 $($item.InstallRelative)" -ForegroundColor Green
    }
    foreach ($item in $changedItems) {
        if (-not (Test-Path -LiteralPath $item.TargetPath -PathType Leaf) -or
            (Get-Sha256 $item.TargetPath) -ne ([string]$item.Entry.sha256).ToLowerInvariant()) {
            throw "安装后哈希校验失败：$($item.InstallRelative)"
        }
    }
    if ($transaction) {
        Write-TransactionState $transaction $transactionPath 'committed'
        Write-Host "原文件/事务备份：$backupPath" -ForegroundColor Cyan
    }
} catch {
    $failure = $_.Exception.Message
    $rollbackErrors = @()
    foreach ($record in @($records | Where-Object { $_.action -ne 'unchanged' })) {
        $item = $items | Where-Object { $_.InstallRelative -eq $record.installPath } | Select-Object -First 1
        try {
            if ($record.action -eq 'replaced') {
                $backupFile = Join-Path $backupPath ($record.backupRelativePath.Replace('/', '\'))
                if (-not (Test-Path -LiteralPath $backupFile -PathType Leaf)) { throw '旧文件备份不存在' }
                Copy-Item -LiteralPath $backupFile -Destination $item.TargetPath -Force
                if ((Get-Sha256 $item.TargetPath) -ne $record.originalSha256) { throw '旧文件恢复哈希不匹配' }
            } elseif ($record.action -eq 'created' -and (Test-Path -LiteralPath $item.TargetPath -PathType Leaf)) {
                $targetHash = Get-Sha256 $item.TargetPath
                if ($targetHash -eq $record.expectedSha256) { Remove-Item -LiteralPath $item.TargetPath -Force }
                else { throw '新文件内容已变化，拒绝自动删除' }
            }
        } catch { $rollbackErrors += "$($record.installPath)：$($_.Exception.Message)" }
    }
    if ($transaction) {
        $state = if ($rollbackErrors.Count -eq 0) { 'rolled_back' } else { 'rollback_incomplete' }
        try { Write-TransactionState $transaction $transactionPath $state $failure } catch { }
    }
    Write-Host "安装失败：$failure" -ForegroundColor Red
    if ($rollbackErrors.Count -gt 0) {
        Write-Host '自动回滚未完全成功，请保留以下备份并人工检查：' -ForegroundColor Red
        $rollbackErrors | ForEach-Object { Write-Host "  $_" }
        if ($backupPath) { Write-Host "备份目录：$backupPath" }
    } else {
        Write-Host '已恢复到安装前状态。' -ForegroundColor Yellow
    }
    exit 1
}

foreach ($item in @($items | Where-Object { $_.Same })) {
    Write-Host "已存在且一致 $($item.InstallRelative)" -ForegroundColor DarkGray
}
Write-Host '衣橱测试包安装完成。请启动游戏，让 REFramework.NET 首次生成 SDK。' -ForegroundColor Green
if ($backupPath) { Write-Host "卸载时可使用 -BackupPath `"$backupPath`" 精确回滚。" }
