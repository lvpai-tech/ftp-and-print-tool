param(
    [Parameter(Mandatory = $true)][string]$Flutter,
    [string]$BuildDrive = 'P:',
    [string]$NodeLicense = ''
)
# 生成独立发布目录；不修改已安装代理、不上传、不触发打印。
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw '请使用 PowerShell 7' }
if (-not (Test-Path -LiteralPath $Flutter -PathType Leaf)) { throw 'Flutter SDK 路径无效' }
$Flutter = (Resolve-Path -LiteralPath $Flutter).Path
if ($NodeLicense) { $NodeLicense = (Resolve-Path -LiteralPath $NodeLicense).Path }
$projectRoot = Split-Path $PSScriptRoot -Parent
if ($projectRoot.Length -gt 80) {
    if ($BuildDrive -notmatch '^[D-Z]:$') { throw 'BuildDrive 必须为 D: 到 Z: 的盘符' }
    $projectParent = Split-Path $projectRoot -Parent
    $shortProject = Join-Path "$BuildDrive\" (Split-Path $projectRoot -Leaf)
    $mapping = (& subst.exe | Where-Object { $_.StartsWith("$BuildDrive\: => ", [StringComparison]::OrdinalIgnoreCase) } | Out-String).Trim()
    $expected = "$BuildDrive\: => $projectParent"
    if ($mapping -and $mapping -ne $expected) { throw "$BuildDrive 已有其他映射，请指定空闲 BuildDrive" }
    if (-not $mapping) {
        if (Test-Path -LiteralPath "$BuildDrive\") { throw "$BuildDrive 已被占用" }
        & subst.exe $BuildDrive $projectParent
        if ($LASTEXITCODE -ne 0) { throw '创建短路径失败' }
    }
    $cache = Join-Path $projectRoot 'build/windows/x64/CMakeCache.txt'
    if ((Test-Path -LiteralPath $cache) -and (Get-Content -LiteralPath $cache -Raw) -notlike "*${BuildDrive}/*") {
        $buildRoot = Join-Path $projectRoot 'build'
        $backupRoot = Join-Path $projectRoot ('.local/print-flutter/build-before-short-path-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Split-Path $backupRoot -Parent) | Out-Null
        # 仅移动本工作区自己的构建缓存，不操作用户安装目录。
        if (-not ([IO.Path]::GetFullPath($buildRoot)).StartsWith($projectRoot + [IO.Path]::DirectorySeparatorChar)) { throw '构建路径越界' }
        Move-Item -LiteralPath $buildRoot -Destination $backupRoot
    }
    Write-Output "使用短路径 $BuildDrive（构建后保留映射供增量构建，完成后可 subst $BuildDrive /D）"
    & (Join-Path $shortProject 'tool/build-workstation.ps1') -Flutter $Flutter -BuildDrive $BuildDrive -NodeLicense $NodeLicense
    return
}
Push-Location $projectRoot
try {
    & $Flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Flutter Windows 构建失败' }
    $releaseRoot = Join-Path $projectRoot 'build/windows/x64/runner/Release'
    if (-not (Test-Path -LiteralPath $releaseRoot -PathType Container)) { throw '缺少构建产物' }
    $runtimeRoot = Join-Path $releaseRoot 'print-runtime'
    $nodePath = (Get-Command node -CommandType Application | Select-Object -First 1).Source
    $bundleArgs = @((Join-Path $PSScriptRoot 'bundle_print_runtime.py'), '--destination', $runtimeRoot, '--node', $nodePath)
    if ($NodeLicense) { $bundleArgs += @('--node-license', $NodeLicense) }
    & python @bundleArgs
    if ($LASTEXITCODE -ne 0) { throw '打印内核打包失败' }
    $manifestPath = Join-Path $projectRoot 'build/windows-manifest.json'
    Get-ChildItem -LiteralPath $releaseRoot -File -Recurse | ForEach-Object {
        [PSCustomObject]@{ path = [IO.Path]::GetRelativePath($releaseRoot, $_.FullName); sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $manifestPath -Encoding utf8
    Write-Output "统一客户端 Windows 目录：$releaseRoot"
    Write-Output "资源清单：$manifestPath"
} finally { Pop-Location }
