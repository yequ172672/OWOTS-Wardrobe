[CmdletBinding()]
param(
    [string]$GameDirectory
)

$ErrorActionPreference = 'Stop'
$packageRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifestPath = Join-Path $packageRoot 'release-manifest.json'

function Get-Sha256([string]$Path) {
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-SafeRelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path)) { throw "无效的清单路径：$Path" }
    $normalized = $Path.Replace('/', '\')
    if ($normalized -match '[:*?"<>|]' -or $normalized -match '(^|\\)\.\.($|\\)' -or $normalized -match '(^|\\)\.($|\\)') { throw "清单路径越界或包含不允许的字符：$Path" }
    return $normalized
}

function Assert-NoReparsePath([string]$Root, [string]$RelativePath) {
    $rootInfo = Get-Item -LiteralPath $Root
    if (($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "拒绝使用 reparse point 目录：$Root" }
    $normalized = if ($RelativePath) { Get-SafeRelativePath $RelativePath } else { '' }
    $current = $Root
    if ($normalized) {
        foreach ($part in $normalized.Split('\')) {
            $current = Join-Path $current $part
            if (Test-Path -LiteralPath $current) {
                $info = Get-Item -LiteralPath $current
                if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "拒绝经过 reparse point 的路径：$RelativePath" }
            }
        }
    }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    if ($normalized -and -not ([IO.Path]::GetFullPath($current)).StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw "路径逃出根目录：$RelativePath" }
}

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "找不到发行清单：$manifestPath" }
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1) { throw "不支持的发行清单版本：$($manifest.schemaVersion)" }

$failed = $false
Write-Host "校验包：$($manifest.packageVersion)" -ForegroundColor Cyan
foreach ($entry in @($manifest.files)) {
    $relative = Get-SafeRelativePath ([string]$entry.path)
    $path = Join-Path $packageRoot $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host "[失败] 缺少 $($entry.path)" -ForegroundColor Red
        $failed = $true
        continue
    }
    $info = Get-Item -LiteralPath $path
    $hash = Get-Sha256 $path
    $expected = ([string]$entry.sha256).ToLowerInvariant()
    if ($info.Length -ne [int64]$entry.bytes -or $hash -ne $expected) {
        Write-Host "[失败] $($entry.path)  bytes=$($info.Length) hash=$hash" -ForegroundColor Red
        $failed = $true
    } else {
        Write-Host "[通过] $($entry.path)" -ForegroundColor DarkGreen
    }
}

if ($GameDirectory) {
    $gamePath = [IO.Path]::GetFullPath($GameDirectory.TrimEnd('\', '/'))
    if (-not (Test-Path -LiteralPath $gamePath -PathType Container)) {
        Write-Host "[失败] 游戏目录不存在：$gamePath" -ForegroundColor Red
        exit 1
    }
    Assert-NoReparsePath $gamePath ''
    Write-Host "校验已安装文件：$gamePath" -ForegroundColor Cyan
    $seenInstallPaths = @{}
    foreach ($entry in @($manifest.files | Where-Object { $_.installPath })) {
        $relative = Get-SafeRelativePath ([string]$entry.installPath)
        $key = $relative.ToLowerInvariant()
        if ($seenInstallPaths.ContainsKey($key)) { throw "发行清单存在重复 installPath：$relative" }
        $seenInstallPaths[$key] = $true
        Assert-NoReparsePath $gamePath $relative
        $path = Join-Path $gamePath $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-Host "[缺失] $($entry.installPath)" -ForegroundColor Yellow
            $failed = $true
            continue
        }
        $hash = Get-Sha256 $path
        if ($hash -ne ([string]$entry.sha256).ToLowerInvariant()) {
            Write-Host "[不一致] $($entry.installPath)  hash=$hash" -ForegroundColor Red
            $failed = $true
        } else {
            Write-Host "[通过] $($entry.installPath)" -ForegroundColor DarkGreen
        }
    }
}

if ($failed) {
    Write-Host '校验未通过。' -ForegroundColor Red
    exit 1
}
Write-Host '校验通过。' -ForegroundColor Green
exit 0
