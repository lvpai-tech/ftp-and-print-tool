param([Parameter(Mandatory = $true)][string]$Executable)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 7) { throw '请使用 PowerShell 7' }
if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw '找不到客户端' }
$Executable = (Resolve-Path -LiteralPath $Executable).Path

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WorkstationSmokeWindow {
  [DllImport("user32.dll")]
  public static extern bool IsWindowVisible(IntPtr window);
  [DllImport("user32.dll")]
  public static extern bool IsIconic(IntPtr window);
  [DllImport("user32.dll")]
  public static extern bool PostMessage(IntPtr window, uint message,
      UIntPtr wParam, IntPtr lParam);
}
'@

function Wait-ForCondition([scriptblock]$Condition, [string]$Failure) {
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    }
    throw $Failure
}

$processes = [Collections.Generic.List[Diagnostics.Process]]::new()
function Start-TestClient([string]$ConfigPath) {
    $info = [Diagnostics.ProcessStartInfo]::new($Executable)
    $info.WorkingDirectory = Split-Path -Parent $Executable
    $info.UseShellExecute = $false
    # 未配置的打印服务只会创建测试锁，不访问业务服务或打印机。
    $info.Environment['PRINT_AGENT_CONFIG'] = $ConfigPath
    $process = [Diagnostics.Process]::Start($info)
    $processes.Add($process)
    return $process
}

$fixture = [IO.Directory]::CreateTempSubdirectory('zhenji-single-instance-')
$config = Join-Path $fixture.FullName 'config.json'
$lock = Join-Path $fixture.FullName '.runtime/print-desktop.lock'
try {
    $primary = Start-TestClient $config
    Wait-ForCondition {
        $primary.Refresh()
        $primary.MainWindowHandle -ne [IntPtr]::Zero -and
            (Test-Path -LiteralPath $lock -PathType Leaf)
    } '首次启动未出现窗口或未启动测试打印服务'
    $window = $primary.MainWindowHandle
    $printOwner = Get-Content -LiteralPath $lock -TotalCount 1 -Encoding utf8
    if (-not [WorkstationSmokeWindow]::PostMessage($window, 0x0010, [UIntPtr]::Zero, [IntPtr]::Zero)) {
        throw '无法向工作台发送关闭窗口消息'
    }
    Wait-ForCondition { -not [WorkstationSmokeWindow]::IsWindowVisible($window) } '关闭窗口后未隐藏到托盘'

    $second = Start-TestClient $config
    $third = Start-TestClient $config
    if (-not $second.WaitForExit(10000) -or -not $third.WaitForExit(10000)) {
        throw '重复启动后额外的客户端进程未退出'
    }
    if ($second.ExitCode -ne 0 -or $third.ExitCode -ne 0) { throw '重复启动未成功交给原窗口' }
    Wait-ForCondition { [WorkstationSmokeWindow]::IsWindowVisible($window) } '原窗口未从托盘恢复'
    if ($primary.HasExited -or (Get-Content -LiteralPath $lock -TotalCount 1 -Encoding utf8) -ne $printOwner) {
        throw '原客户端或原打印服务被替换'
    }
    # WM_SYSCOMMAND / SC_MINIMIZE
    if (-not [WorkstationSmokeWindow]::PostMessage($window, 0x0112, [UIntPtr]::new(0xF020), [IntPtr]::Zero)) {
        throw '无法向工作台发送最小化消息'
    }
    Wait-ForCondition { [WorkstationSmokeWindow]::IsIconic($window) } '工作台没有进入最小化状态'
    $reopen = Start-TestClient $config
    if (-not $reopen.WaitForExit(10000) -or $reopen.ExitCode -ne 0) { throw '最小化后重复启动没有正常退出' }
    Wait-ForCondition { -not [WorkstationSmokeWindow]::IsIconic($window) } '原窗口未从最小化恢复'

    $primary.Kill()
    if (-not $primary.WaitForExit(10000)) { throw '无法结束受控客户端' }
    Wait-ForCondition { -not (Test-Path -LiteralPath $lock -PathType Leaf) } '受控打印服务未在窗口进程退出后释放锁'
    $restart = Start-TestClient $config
    Wait-ForCondition {
        $restart.Refresh()
        $restart.MainWindowHandle -ne [IntPtr]::Zero -and
            (Test-Path -LiteralPath $lock -PathType Leaf)
    } '原进程结束后无法重新启动工作台'
    Write-Output '通过：重复启动恢复托盘中和最小化的原窗口，打印服务保持原进程，退出后可重新启动。'
} finally {
    foreach ($process in $processes) {
        if (-not $process.HasExited) { $process.Kill() }
        $process.WaitForExit()
        $process.Dispose()
    }
}
