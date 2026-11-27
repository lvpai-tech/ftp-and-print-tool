#Requires -Version 7.0
<#
.SYNOPSIS
从源码启动 Windows 工作台，保留 Flutter 热重载终端。

.EXAMPLE
.\run-windows.ps1

.EXAMPLE
pwsh -NoProfile -ExecutionPolicy Bypass -File .\run-windows.ps1

.EXAMPLE
.\run-windows.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Flutter
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw '请在 Windows 上运行此脚本。' }

if (-not $Flutter) {
    $command = Get-Command flutter.bat -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $Flutter = if ($command) { $command.Source } else {
        Join-Path $env:USERPROFILE 'develop/flutter/bin/flutter.bat'
    }
}
if (-not (Test-Path -LiteralPath $Flutter -PathType Leaf)) {
    throw '找不到 Flutter。请将 Flutter 加入 PATH，或用 -Flutter 指定 flutter.bat。'
}
$Flutter = (Resolve-Path -LiteralPath $Flutter).Path

$node = Get-Command node.exe -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $node) { throw '找不到 Node.js。请安装 Node.js 22 并将其加入 PATH。' }

$runtime = Join-Path $PSScriptRoot 'print-runtime'
if (-not (Test-Path -LiteralPath (Join-Path $runtime 'src/flutter-bridge.cjs') -PathType Leaf)) {
    throw "找不到打印内核入口，请检查项目文件：$runtime"
}

$epsonDriver = 'EPSON L8050 Series'
try {
    $drivers = @(Get-PrinterDriver -ErrorAction Stop)
    if ($drivers.Name -contains $epsonDriver) {
        $queues = @(Get-Printer -ErrorAction Stop | Where-Object DriverName -EQ $epsonDriver)
        if ($queues.Count) {
            Write-Host "Epson L8050 专用驱动已安装。已添加队列：$($queues.Name -join '、')"
        }
        else {
            Write-Host 'Epson L8050 专用驱动已安装。请先在 Windows「打印机和扫描仪」添加打印机，再回工作台刷新列表。'
        }
    }
    else {
        Write-Host '系统未登记 Epson L8050 专用驱动。使用 L8050 时，可通过工作台 Setup.exe 安装官方驱动。'
    }
}
catch {
    Write-Warning "无法读取 Windows 打印机状态，仍可启动工作台。$($_.Exception.Message)"
}

if (-not $PSCmdlet.ShouldProcess($PSScriptRoot, "运行 $Flutter run -d windows --debug")) { return }

$previousRuntime = $env:LVPAI_PRINT_RUNTIME
$previousNode = $env:LVPAI_PRINT_NODE
Push-Location -LiteralPath $PSScriptRoot
try {
    $env:LVPAI_PRINT_RUNTIME = $runtime
    $env:LVPAI_PRINT_NODE = $node.Source
    Write-Host 'Flutter 调试键：r 热重载，R 热重启，q 退出。'
    & $Flutter run -d windows --debug
    if ($LASTEXITCODE -ne 0) {
        throw "Flutter 启动命令失败，退出码 $LASTEXITCODE。请查看上面的日志。"
    }
}
finally {
    $env:LVPAI_PRINT_RUNTIME = $previousRuntime
    $env:LVPAI_PRINT_NODE = $previousNode
    Pop-Location
}
