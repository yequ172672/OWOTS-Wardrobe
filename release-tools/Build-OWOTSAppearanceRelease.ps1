[CmdletBinding()]
param(
    [string]$OutputRoot = '',

    [string]$GameDirectory = 'D:\gametest\steamapps\common\OnimushaWotS',

    [string]$NativeDll = '',

    [string]$ManagedRuntimeDll = '',

    [switch]$SkipNativeBuild,

    [switch]$RemoveStaging
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot '..'))
if (-not $OutputRoot) { $OutputRoot = Join-Path $workspaceRoot '_validation\releases\20260916' }
$outputPath = [IO.Path]::GetFullPath($OutputRoot)
$packageName = 'OWOTS-Appearance-Test-20260916'
$staging = Join-Path $outputPath $packageName
$zipPath = Join-Path $outputPath "$packageName.zip"
$gamePath = [IO.Path]::GetFullPath($GameDirectory.TrimEnd('\', '/'))
if (-not $NativeDll) { $NativeDll = Join-Path $workspaceRoot 'REFramework-cn\build\bin\REFramework\dinput8.dll' }
$nativePath = [IO.Path]::GetFullPath($NativeDll)

function Get-Sha256([string]$Path) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Ensure-File([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "找不到$Description：$Path" }
}
function Assert-NoReparseAncestors([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $info = Get-Item -LiteralPath $current
            if (($info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "拒绝使用 reparse point 输出路径：$current"
            }
            $parent = $info.Parent
            $next = if ($parent) { $parent.FullName } else { $null }
        } else {
            $next = Split-Path -Parent $current
        }
        if (-not $next -or $next -eq $current) { break }
        $current = $next
    }
}
function Copy-Payload([string]$Source, [string]$RelativePath, [string]$InstallPath, [System.Collections.Generic.List[object]]$List) {
    Ensure-File $Source '输入文件'
    $destination = Join-Path $staging ($RelativePath.Replace('/', '\'))
    $parent = Split-Path -Parent $destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    Copy-Item -LiteralPath $Source -Destination $destination -Force
    $info = Get-Item -LiteralPath $destination
    [void]$List.Add([pscustomobject]@{
        path = $RelativePath.Replace('\', '/')
        installPath = if ($InstallPath) { $InstallPath.Replace('\', '/') } else { $null }
        bytes = [int64]$info.Length
        sha256 = Get-Sha256 $destination
    })
}

if (-not (Test-Path -LiteralPath $gamePath -PathType Container)) { throw "游戏依赖目录不存在：$gamePath" }
Ensure-File $nativePath 'native Release DLL'
if (-not $SkipNativeBuild) {
    $nativeRepo = Join-Path $workspaceRoot 'REFramework-cn'
    if (Test-Path -LiteralPath (Join-Path $nativeRepo 'build') -PathType Container) {
        Write-Host '构建 REFramework native Release...' -ForegroundColor Cyan
        & cmake --build (Join-Path $nativeRepo 'build') --config Release --target REFramework --parallel 4
        if ($LASTEXITCODE -ne 0) { throw "native Release 构建失败，退出码 $LASTEXITCODE" }
    }
    Ensure-File $nativePath 'native Release DLL'
}

# OutputRoot is explicit and the staging directory is its single fixed child.
# Resolve/check both before any replacement so a junction cannot redirect cleanup.
Assert-NoReparseAncestors $outputPath
if (-not (Test-Path -LiteralPath $outputPath -PathType Container)) {
    $outputParent = Split-Path -Parent $outputPath
    if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) { New-Item -ItemType Directory -Path $outputParent -Force | Out-Null }
    New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
}
$outputPrefix = $outputPath.TrimEnd('\') + '\'
$stagingFull = [IO.Path]::GetFullPath($staging)
if (-not $stagingFull.StartsWith($outputPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw '发行 staging 路径不在 OutputRoot 内。'
}
if (Test-Path -LiteralPath $staging) { Assert-NoReparseAncestors $staging; Remove-Item -LiteralPath $staging -Recurse -Force }
if (Test-Path -LiteralPath $zipPath) { Assert-NoReparseAncestors $zipPath; Remove-Item -LiteralPath $zipPath -Force }
New-Item -ItemType Directory -Path $staging -Force | Out-Null
$payload = [System.Collections.Generic.List[object]]::new()

# The native file is built from the custom REFramework checkout. Managed files are
# copied from the known working REFramework.NET runtime used by the acceptance run.
Copy-Payload $nativePath 'dinput8.dll' 'dinput8.dll' $payload
$runtimeFiles = @(
    @{ Source = 'reframework\plugins\Ijwhost.dll'; Relative = 'reframework/plugins/Ijwhost.dll'; Install = 'reframework/plugins/Ijwhost.dll' },
    @{ Source = 'reframework\plugins\REFramework.NET.dll'; Relative = 'reframework/plugins/REFramework.NET.dll'; Install = 'reframework/plugins/REFramework.NET.dll' },
    @{ Source = 'reframework\plugins\REFramework.NET.runtimeconfig.json'; Relative = 'reframework/plugins/REFramework.NET.runtimeconfig.json'; Install = 'reframework/plugins/REFramework.NET.runtimeconfig.json' },
    @{ Source = 'reframework\plugins\managed\dependencies\AssemblyGenerator.dll'; Relative = 'reframework/plugins/managed/dependencies/AssemblyGenerator.dll'; Install = 'reframework/plugins/managed/dependencies/AssemblyGenerator.dll' },
    @{ Source = 'reframework\plugins\managed\dependencies\Hexa.NET.ImGui.dll'; Relative = 'reframework/plugins/managed/dependencies/Hexa.NET.ImGui.dll'; Install = 'reframework/plugins/managed/dependencies/Hexa.NET.ImGui.dll' },
    @{ Source = 'reframework\plugins\managed\dependencies\HexaGen.Runtime.dll'; Relative = 'reframework/plugins/managed/dependencies/HexaGen.Runtime.dll'; Install = 'reframework/plugins/managed/dependencies/HexaGen.Runtime.dll' },
    @{ Source = 'reframework\plugins\managed\dependencies\Microsoft.CodeAnalysis.dll'; Relative = 'reframework/plugins/managed/dependencies/Microsoft.CodeAnalysis.dll'; Install = 'reframework/plugins/managed/dependencies/Microsoft.CodeAnalysis.dll' },
    @{ Source = 'reframework\plugins\managed\dependencies\Microsoft.CodeAnalysis.CSharp.dll'; Relative = 'reframework/plugins/managed/dependencies/Microsoft.CodeAnalysis.CSharp.dll'; Install = 'reframework/plugins/managed/dependencies/Microsoft.CodeAnalysis.CSharp.dll' },
    @{ Source = 'reframework\plugins\managed\dependencies\REFCoreDeps.dll'; Relative = 'reframework/plugins/managed/dependencies/REFCoreDeps.dll'; Install = 'reframework/plugins/managed/dependencies/REFCoreDeps.dll' }
)
foreach ($file in $runtimeFiles) {
    $runtimeSource = if ($ManagedRuntimeDll -and $file.Relative -eq 'reframework/plugins/REFramework.NET.dll') {
        [IO.Path]::GetFullPath($ManagedRuntimeDll)
    } else { Join-Path $gamePath $file.Source }
    Copy-Payload $runtimeSource $file.Relative $file.Install $payload
}

# Built-in native costume thumbnails, shipped as a built-in MOD resource set so the
# wardrobe can show the game's own icons for its built-in entries.
$builtinIcons = Join-Path $repoRoot 'reframework\builtin-icons'
if (-not (Test-Path -LiteralPath $builtinIcons -PathType Container)) { throw '找不到内置图标目录 reframework\builtin-icons' }
foreach ($icon in Get-ChildItem -LiteralPath $builtinIcons -Filter '*.png' -File) {
    $relative = 'reframework/data/owots_appearance_lab/builtin-icons/' + $icon.Name
    Copy-Payload $icon.FullName $relative $relative $payload
}

$builder = Join-Path $repoRoot 'appearance-core\build_lab.py'
Ensure-File $builder '衣橱 bundle 构建脚本'
$bundleInput = Join-Path $staging '.OWOTSAppearanceLab.generated.cs'
$pythonCommand = Get-Command python -ErrorAction SilentlyContinue
if (-not $pythonCommand) { throw '找不到 Python；需要 Python 3 生成衣橱 bundle。' }
& $pythonCommand.Source $builder --output $bundleInput
if ($LASTEXITCODE -ne 0) { throw "衣橱 bundle 构建失败，退出码 $LASTEXITCODE" }
Copy-Payload $bundleInput 'reframework/plugins/source/OWOTSAppearanceLab.cs' 'reframework/plugins/source/OWOTSAppearanceLab.cs' $payload
Remove-Item -LiteralPath $bundleInput -Force

# The independent skeleton is now built into the wardrobe plugin itself; only
# the inert retirement marker ships so an earlier per-MOD Lua writer stays inert.
foreach ($scriptName in @('yorha_2b_skeleton_adapter.lua')) {
    $scriptRelative = 'reframework/autorun/' + $scriptName
    Copy-Payload (Join-Path $repoRoot $scriptRelative) $scriptRelative $scriptRelative $payload
}
# Player package contents: only the runtime files, the bilingual README, the project
# license and the required third-party notices/sub-licenses. The installer/verify
# scripts and the developer documents stay in the repository and are NOT shipped.
$notice = Join-Path $PSScriptRoot 'THIRD-PARTY-NOTICES.md'
$hexaLicense = Join-Path $PSScriptRoot 'LICENSE-Hexa.NET.txt'
$roslynLicense = Join-Path $PSScriptRoot 'LICENSE-Microsoft-CodeAnalysis.txt'
Ensure-File $notice '第三方说明'
Ensure-File $hexaLicense 'Hexa.NET 许可证'
Ensure-File $roslynLicense 'Roslyn 许可证'
Copy-Payload (Join-Path $repoRoot 'README.md') 'README.md' $null $payload
Copy-Payload (Join-Path $repoRoot 'README-zh-CN.md') 'README-zh-CN.md' $null $payload
Copy-Payload (Join-Path $repoRoot 'LICENSE') 'LICENSE' $null $payload
Copy-Payload $notice 'THIRD-PARTY-NOTICES.md' $null $payload
Copy-Payload $hexaLicense 'LICENSE-Hexa.NET.txt' $null $payload
Copy-Payload $roslynLicense 'LICENSE-Microsoft-CodeAnalysis.txt' $null $payload
Copy-Payload (Join-Path $workspaceRoot 'REFramework-cn\LICENSE') 'LICENSE-REFramework.txt' $null $payload

$nativeCommit = (& git -C (Join-Path $workspaceRoot 'REFramework-cn') rev-parse HEAD).Trim()
$managedCommit = (& git -C $repoRoot rev-parse HEAD).Trim()
$nativeDirtyFiles = @(& git -C (Join-Path $workspaceRoot 'REFramework-cn') status --short -- src csharp-api CMakeLists.txt cmake.toml)
$managedDirtyFiles = @(& git -C $repoRoot status --short)
$manifest = [pscustomobject]@{
    schemaVersion = 1
    packageVersion = '2026.09.16-hotreload-test.1'
    createdUtc = (Get-Date).ToUniversalTime().ToString('o')
    game = 'OnimushaWotS'
    source = [pscustomobject]@{
        nativeRepository = 'https://github.com/yequ172672/REFramework-cn'
        nativeCommit = $nativeCommit
        managedRepository = 'https://github.com/yequ172672/OWOTS-Wardrobe'
        managedCommit = $managedCommit
        nativeDirtyFiles = $nativeDirtyFiles
        managedDirtyFiles = $managedDirtyFiles
        generatedBundleSha256 = ($payload | Where-Object { $_.path -eq 'reframework/plugins/source/OWOTSAppearanceLab.cs' }).sha256
        nativeBuild = 'cmake --build build --config Release --target REFramework --parallel 4'
    }
    files = $payload
    excluded = @(
        'OnimushaWotS.exe and official game files',
        'reframework/plugins/managed/generated/* (game-specific SDK; generated on first launch)',
        'reframework/data/owots_appearance_lab/mods/* (private test MOD assets)',
        'reframework/data/owots_appearance_lab/saves/*',
        're2_framework_log.txt, crash dumps and other logs',
        'MCP server binaries and development/build directories'
    )
}
$manifestPath = Join-Path $staging 'release-manifest.json'
$manifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$sumLines = @()
foreach ($file in Get-ChildItem -File -Recurse -LiteralPath $staging | Sort-Object FullName) {
    $relative = $file.FullName.Substring($staging.Length + 1).Replace('\', '/')
    if ($relative -eq 'SHA256SUMS.txt') { continue }
    $sumLines += "$(Get-Sha256 $file.FullName)  $relative"
}
Set-Content -LiteralPath (Join-Path $staging 'SHA256SUMS.txt') -Value $sumLines -Encoding ASCII

Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -CompressionLevel Optimal
$zipInfo = Get-Item -LiteralPath $zipPath
$zipHash = Get-Sha256 $zipPath
$summary = [pscustomobject]@{
    packageVersion = $manifest.packageVersion
    packageDirectory = $staging
    zip = $zipPath
    zipBytes = [int64]$zipInfo.Length
    zipSha256 = $zipHash
    runtimeBundleSha256 = $manifest.source.generatedBundleSha256
    nativeSha256 = ($payload | Where-Object { $_.path -eq 'dinput8.dll' }).sha256
    fileCount = $payload.Count + 2
    excluded = $manifest.excluded
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outputPath "$packageName-summary.json") -Encoding UTF8
Set-Content -LiteralPath (Join-Path $outputPath "$packageName.zip.sha256") -Value "$zipHash  $packageName.zip" -Encoding ASCII

if ($RemoveStaging) {
    # The ZIP is already complete. Re-check the fixed child before optional cleanup.
    Assert-NoReparseAncestors $staging
    Remove-Item -LiteralPath $staging -Recurse -Force
    Write-Host "已清理 staging 目录：$staging" -ForegroundColor DarkGray
} else {
    Write-Host "已保留 staging 目录供审计：$staging" -ForegroundColor DarkGray
}
Write-Host "发行包已生成：$zipPath" -ForegroundColor Green
Write-Host "ZIP SHA256：$zipHash" -ForegroundColor Cyan
