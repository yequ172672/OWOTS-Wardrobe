<#
.SYNOPSIS
  Offline compile check for the bundled wardrobe plugin.
.DESCRIPTION
  Generates the single-source bundle with appearance-core/build_lab.py and compiles it
  against the game's installed REFramework.NET assemblies. It never launches the game,
  never writes into the game directory and never replaces an installed plugin.
.PARAMETER GameRoot
  Onimusha WotS install directory that contains the reframework folder.
.PARAMETER WorkDir
  Scratch directory for the generated bundle and compile project.
.PARAMETER KeepWorkDir
  Keep the generated bundle.cs and project for inspection.
#>
param(
    [string]$GameRoot = 'D:\gametest\steamapps\common\OnimushaWotS',
    [string]$WorkDir = (Join-Path $env:TEMP 'owots-lab-compile'),
    [switch]$KeepWorkDir
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$refDir = Join-Path $GameRoot 'reframework\plugins'
$generatedDir = Join-Path $refDir 'managed\generated'
$depsDir = Join-Path $refDir 'managed\dependencies'
$references = @(
    (Join-Path $refDir 'REFramework.NET.dll'),
    (Join-Path $generatedDir 'REFramework.NET.application.dll'),
    (Join-Path $generatedDir 'REFramework.NET.viacore.dll'),
    (Join-Path $depsDir 'Hexa.NET.ImGui.dll'),
    (Join-Path $depsDir 'HexaGen.Runtime.dll'),
    (Join-Path $depsDir 'REFCoreDeps.dll')
)
foreach ($reference in $references) {
    if (-not (Test-Path -LiteralPath $reference)) { throw "Missing REFramework assembly: $reference" }
}
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$bundle = Join-Path $WorkDir 'bundle.cs'
& python (Join-Path $repo 'appearance-core\build_lab.py') --output $bundle
if ($LASTEXITCODE -ne 0) { throw 'build_lab.py failed' }
$project = Join-Path $WorkDir 'LabCompile.csproj'
$lines = @(
    '<Project Sdk="Microsoft.NET.Sdk">',
    '  <PropertyGroup>',
    '    <TargetFramework>net10.0</TargetFramework>',
    '    <OutputType>Library</OutputType>',
    '    <AssemblyName>OWOTSAppearanceLab.CompileCheck</AssemblyName>',
    '    <Nullable>enable</Nullable>',
    '    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>',
    '    <LangVersion>latest</LangVersion>',
    '    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>',
    '    <NoWarn>CS0169;CS0414;CS0649;CS8981</NoWarn>',
    '    <ImplicitUsings>disable</ImplicitUsings>',
    '  </PropertyGroup>',
    '  <ItemGroup>',
    '    <Compile Include="bundle.cs" />'
)
foreach ($reference in $references) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($reference)
    $lines += "    <Reference Include=""$name""><HintPath>$reference</HintPath></Reference>"
}
$lines += @('  </ItemGroup>', '</Project>')
Set-Content -LiteralPath $project -Value $lines -Encoding UTF8
& dotnet build $project -v q --nologo
if ($LASTEXITCODE -ne 0) { throw 'Offline compile check failed' }
Write-Output "Offline compile check passed: $bundle"
if (-not $KeepWorkDir) { Remove-Item -LiteralPath $WorkDir -Recurse -Force }
