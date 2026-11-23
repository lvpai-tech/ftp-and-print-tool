if ($PSVersionTable.PSVersion.Major -lt 5) { exit 10 }
$ErrorActionPreference = 'Stop'
$installer = $env:LVPAI_UPDATE_INSTALLER
$executable = $env:LVPAI_UPDATE_EXECUTABLE
$mode = $env:LVPAI_UPDATE_MODE
$installDirectory = Split-Path -LiteralPath $executable
$registrationKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{0865ABC5-AAA9-4E6B-AC85-05C88093CB02}_is1'

try {
    if ($mode -eq 'install') {
        $appProcess = Get-Process -Id ([int]$env:LVPAI_UPDATE_PID) -ErrorAction SilentlyContinue
        if ($appProcess -and $appProcess.Path -eq $executable -and -not $appProcess.WaitForExit(60000)) {
            throw '工作台未能退出，更新已停止。'
        }
    }
    $registration = Get-ItemProperty -LiteralPath $registrationKey -Name InstallLocation -ErrorAction SilentlyContinue
    if (-not $registration.InstallLocation -or
        [IO.Path]::GetFullPath($registration.InstallLocation).TrimEnd('\') -ne $installDirectory) {
        if ($mode -eq 'verify') { exit 11 }
        throw '没有找到当前工作台的安装记录。'
    }
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf) -or
        (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne $env:LVPAI_UPDATE_SHA256) {
        throw '安装包校验失败。'
    }
    $current = Get-AuthenticodeSignature -LiteralPath $executable
    $package = Get-AuthenticodeSignature -LiteralPath $installer
    if ($current.Status -ne 'Valid') {
        if ($mode -eq 'verify') { exit 11 }
        throw '当前工作台的签名无效。'
    }
    if ($package.Status -ne 'Valid' -or
        $package.SignerCertificate.Thumbprint -ne $current.SignerCertificate.Thumbprint) {
        throw '新版安装包的签名无效或与当前安装使用的证书不同。'
    }
    if ($mode -eq 'verify') { exit 0 }
    if ($mode -ne 'install') { exit 10 }

    $log = Join-Path ([IO.Path]::GetTempPath()) ('zhenji-update-' + [Guid]::NewGuid() + '.log')
    $flags = '/VERYSILENT /SUPPRESSMSGBOXES /SP- /NORESTART /RESTARTEXITCODE=3010 /LOG="' + $log + '"'
    $setup = Start-Process -FilePath $installer -ArgumentList $flags -WindowStyle Hidden -Wait -PassThru
    if ($setup.ExitCode -eq 3010) { throw '安装完成，请重启 Windows 后打开新版工作台。' }
    if ($setup.ExitCode -ne 0) { throw "安装失败（$($setup.ExitCode)）。日志：$log" }
    Start-Process -FilePath $executable -WorkingDirectory $installDirectory
    exit 0
} catch {
    if ($mode -eq 'install') {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '帧集快拍更新')
    }
    exit 10
}
