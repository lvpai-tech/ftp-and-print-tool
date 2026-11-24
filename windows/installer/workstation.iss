#define Workstation "帧集快拍"
#define WorkstationExe "lvpai_ftp_client.exe"

[Setup]
AppId={{0865ABC5-AAA9-4E6B-AC85-05C88093CB02}
AppName={#Workstation}
AppVersion={#AppVersion}
AppPublisher=旅派
DefaultDirName={localappdata}\Programs\Lvpai\ZhenjiWorkstation
DefaultGroupName={#Workstation}
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
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
SetupAppRunningError=帧集快拍正在运行。请先从系统托盘正常退出工作台，再继续安装。
UninstallAppRunningError=帧集快拍正在运行。请先从系统托盘正常退出工作台，再继续卸载。

[Files]
; Only staged program files. AppData and the user's photo folder are outside the payload.
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#Workstation}"; Filename: "{app}\{#WorkstationExe}"; WorkingDir: "{app}"
Name: "{group}\{#Workstation}（图形兼容模式）"; Filename: "{app}\{#WorkstationExe}"; Parameters: "--graphics-compatibility"; WorkingDir: "{app}"
Name: "{autodesktop}\{#Workstation}"; Filename: "{app}\{#WorkstationExe}"; WorkingDir: "{app}"

[Run]
Filename: "{app}\{#WorkstationExe}"; Description: "打开帧集快拍"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent
