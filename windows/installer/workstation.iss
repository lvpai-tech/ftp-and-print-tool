#ifndef Workstation
  #define Workstation "帧集快拍"
#endif
#define WorkstationExe "lvpai_ftp_client.exe"
#define EpsonL8050DriverName "EPSON L8050 Series"
#define EpsonL8050Setup "L8050_x64_380JAUsHomeExportAsiaML_2.exe"
#define EpsonL8050SetupUrl "https://download3.ebz.epson.net/dsc/f/03/00/17/30/28/a850407fb2d4195d0d5436e7e59d88843d5a0351/" + EpsonL8050Setup
#define EpsonL8050SetupSha256 "BA5E19CD2CFA9B0DF42C384CBA911E94A1FEEC80872937E56B6F95178A5B7A2C"

[Setup]
AppId={{0865ABC5-AAA9-4E6B-AC85-05C88093CB02}
AppName={#Workstation}
AppVersion={#AppVersion}
AppPublisher=旅派
VersionInfoProductName={#Workstation}
DefaultDirName={localappdata}\Programs\Lvpai\ZhenjiWorkstation
DefaultGroupName={#Workstation}
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
UsePreviousTasks=no
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#WorkstationExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
AppMutex=Local\ai.lvpai.zhenji.workstation
CloseApplications=no
RestartApplications=no

[Messages]
SetupWindowTitle=安装向导 - %1
ButtonInstall=安装(&I)
ButtonFinish=完成(&F)
ButtonCancel=取消
WizardReady=准备安装
ReadyLabel1=安装向导已准备好安装 [name]。
ReadyLabel2a=点击「安装」继续。
ReadyLabel2b=点击「安装」继续。
WizardInstalling=正在安装
InstallingLabel=正在安装 [name]，请稍候。
FinishedHeadingLabel=安装完成
FinishedLabelNoIcons=[name] 已安装完成。
FinishedLabel=[name] 已安装完成。
ClickFinish=点击「完成」退出安装向导。
SetupAppRunningError={#Workstation}正在运行。请先从系统托盘正常退出工作台，再继续安装。
UninstallAppRunningError={#Workstation}正在运行。请先从系统托盘正常退出工作台，再继续卸载。

[Tasks]
Name: "epsonl8050"; Description: "安装 Epson L8050 官方打印驱动（需要联网及管理员授权）"; Flags: unchecked; Check: NeedsEpsonL8050Driver

[Files]
; Only staged program files. AppData and the user's photo folder are outside the payload.
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#Workstation}"; Filename: "{app}\{#WorkstationExe}"; WorkingDir: "{app}"
Name: "{group}\{#Workstation}（图形兼容模式）"; Filename: "{app}\{#WorkstationExe}"; Parameters: "--graphics-compatibility"; WorkingDir: "{app}"
Name: "{autodesktop}\{#Workstation}"; Filename: "{app}\{#WorkstationExe}"; WorkingDir: "{app}"

[Run]
Filename: "{app}\{#WorkstationExe}"; Description: "打开{#Workstation}"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[Code]
var
  EpsonDownload: TDownloadWizardPage;

function NeedsEpsonL8050Driver: Boolean;
var
  PrintEnvironment: String;
begin
  if IsArm64 then
    PrintEnvironment := 'Windows ARM64'
  else
    PrintEnvironment := 'Windows x64';

  Result := not RegKeyExists(HKLM64,
    'SYSTEM\CurrentControlSet\Control\Print\Environments\' + PrintEnvironment +
    '\Drivers\Version-3\{#EpsonL8050DriverName}');
end;

procedure InitializeWizard;
begin
  EpsonDownload := CreateDownloadPage('Epson L8050 打印驱动',
    '正在从爱普生下载并校验官方驱动。', nil);
  EpsonDownload.ShowBaseNameInsteadOfUrl := True;
end;

procedure InstallEpsonL8050Driver;
var
  SetupPath: String;
  ResultCode: Integer;
begin
  EpsonDownload.Clear;
  EpsonDownload.Add('{#EpsonL8050SetupUrl}', '{#EpsonL8050Setup}', '{#EpsonL8050SetupSha256}');
  EpsonDownload.Show;
  try
    EpsonDownload.Download;
  finally
    EpsonDownload.Hide;
  end;

  SetupPath := ExpandConstant('{tmp}\{#EpsonL8050Setup}');
  if not ShellExec('runas', SetupPath, '', ExpandConstant('{tmp}'),
      SW_SHOWNORMAL, ewWaitUntilTerminated, ResultCode) then
    RaiseException('无法启动爱普生安装程序。' + #13#10 + SysErrorMessage(ResultCode));

  if NeedsEpsonL8050Driver then
    RaiseException(Format('Windows 尚未登记 Epson L8050 专用驱动（安装程序退出码 %d）。请完成爱普生安装向导后，再到工作台选择打印机。', [ResultCode]));

  Log('Windows registered the Epson L8050 printer driver.');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep <> ssPostInstall then
    Exit;
  if WizardSilent or not WizardIsTaskSelected('epsonl8050') or not NeedsEpsonL8050Driver then
    Exit;

  try
    InstallEpsonL8050Driver;
  except
    Log('Epson L8050 driver setup did not finish: ' + GetExceptionMessage);
    MsgBox('工作台已安装，Epson L8050 驱动安装未确认完成。' + #13#10 +
      GetExceptionMessage, mbError, MB_OK);
  end;
end;
