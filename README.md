# 帧集快拍客户端

独立 Flutter 应用，共用 Windows / macOS / iOS 的 Dart 上传队列；苹果端包含原生目录授权代码，待 Mac 编译及真机验收。

公开仓可用 GitHub Actions 打 **macOS 个人跨机包**：仓库 Actions 页手动运行 `Build macOS`，下载 Artifact `lvpai-ftp-macos-personal`。解压后双击「打开旅派客户端.command」；其他 Mac 首次需右键打开或「仍要打开」。包内含临时签名的 `.app`、随包 `print-runtime`（Node + 打印内核）与说明。正式对外分发仍须按 [RELEASING.md](RELEASING.md) 签名与公证，不能把本个人包当公证安装包。

Windows 和 macOS 打印使用本仓的 [Node 打印内核](print-runtime/README.md)。

拷到 Mac 后的完整运行、签名和测试步骤见 [APPLE_TESTING.md](APPLE_TESTING.md)。

## 设计与维护

Windows 和 macOS 工作台首页提供「上传照片」与「打印照片」。上传默认连接 `https://hilvpai.com`。「上传照片」打开本机机位列表，可逐个申请和绑定机位。运营审核后，由申请电脑自动领取并激活该机位的上传凭据。持有机位 ID 和机位密钥时也可手动绑定。

源码边界：

| 文件 | 职责 |
| --- | --- |
| `lib/main.dart` | 启动入口 |
| `lib/app.dart` | 应用主题及页面入口 |
| `lib/ui/transfer_page.dart` | 机位列表、申请及上传详情入口 |
| `lib/profile_store.dart` | 系统安全存储，界面不处理存储格式 |
| `lib/auto_upload/station_upload.dart` | 单机位收图目录、启停、导入与旧目录切换 |
| `lib/auto_upload/cos_upload.dart` | 申请上传会话、直传 COS、确认上传及查询归集状态 |
| `lib/ui/auto_upload_panel.dart` | 自动模式设置、状态与任务列表 |
| `lib/auto_upload/folder_uploader.dart` | 稳定检测、扫描补偿、任务调度与重试 |
| `lib/auto_upload/journal.dart` | 队列追加日志、恢复与独占锁 |
| `lib/auto_upload/folder_access.dart` | 平台目录授权通道，苹果端使用原生安全书签 |
| `lib/release/update_service.dart` | 平台与通道清单校验、下载及完整性核验 |
| `lib/ui/update_button.dart` | 手动检查更新、下载进度与打开安装包 |
| `site/`、`tool/package_release.py` | 独立静态下载页与本地打包工具 |
| `windows/`、`macos/`、`ios/` | 各平台原生工程与权限 |

工作台通过运营 API 获取机位专属上传授权，将原片直传 COS，再查询服务端入库与归卡状态。生产已停用 FTP 收图，仓库保留旧版 FTP 传输和手动批次源码及隔离测试。

体积基线（Windows x64 release 0.3.0+3，2026-11-18）：ZIP为12,285,224字节，约11.7 MiB。
完整包包含EXE、Flutter引擎、插件DLL和data；SDK、编译器、源码、测试与业务照片不打进发布包。
这是该版本构建实测，并非后续版本的体积保证。

## 桌面打印工作台

在打印页「景区密钥档案 → 添加景区」输入从旅派运营后台获取的工作台打印密钥，再激活对应档案。每个档案只拉取该密钥授权的景区任务，各景区共用打印机路由。打印中或自动打印开启时无法切换。

打印页通过 `print-runtime/src/flutter-bridge.cjs` 启动打印内核。开发联调和测试见[打印内核说明](print-runtime/README.md)，打包见[发布手册](RELEASING.md)。景区档案名称应取自该档案密钥的服务端鉴权结果，验证两把景区密钥时分别检查显示名称与待打印列表。

## 两台电脑接续开发

CI 和 `.fvmrc` 固定 Flutter **3.50.0 / Dart 3.14.0**。复现该版本时先运行 `fvm install`，再将下述 `flutter` 替换成 `fvm flutter`。Windows 本地开发已用用户级 Flutter 3.50.1 验证。
`pubspec.lock`和三个原生工程均需进Git；`.dart_tool`、SDK和build目录在每台机器重新生成。
不要把Windows的build、缓存或本机SDK复制到Mac。可复制整个源码目录（排除缓存），或使用本轮提供的独立源码包。

Mac需要安装Xcode及命令行工具，并按`flutter doctor -v`补齐当前依赖要求。
拉取同一份仓库后：

```sh
flutter --version
flutter doctor -v
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter run -d macos
flutter build macos --release
```

已为macOS Debug/Profile及Release补充外连网络、用户选择文件只读、安全书签及Keychain配置。
Mac首次运行仍需核验签名、Keychain保存后重启恢复、中文文件名和多图上传；Windows不能代替这些验收。
签名团队、证书和账号由各机器配置，不提交个人签名凭据，不关闭App Sandbox来绕过权限问题。
不要变更Bundle ID来解决签名，否则可能无法读取原应用的Keychain配置。

iPad沿用`ios/`工程，已增加Keychain权限、局域网用途说明、系统目录选择和本机CameraInbox目录、
书签恢复及前后台监听停止逻辑；仍需在Mac上配置签名，编译并完成真机验收。

## 自动监听

绑定机位后，工作台创建固定收图目录并开始监听。点击该机位的「复制路径」，把该路径设为相机软件的导出目标。手动补片可使用「导入照片」或在桌面端把照片拖入机位详情。多台摄影电脑可由现场管理员将各机位的收图目录单独设为局域网共享，并授权对应账号投递。

- 托管目录包含子文件夹，恢复时补扫其中尚未接收的照片。保留已传账本和存量结束照基线。
- 文件大小和修改时间连续稳定 3 秒后，复制到应用私有待传区，检查图片头尾、解码及 SHA-256，再入队。
- 文件事件加每 2 秒补扫。照片首次被发现时保存队列位置，写完并通过解码检查后上传。若补扫发现多张照片且无法确定顺序，上传页会请你选择下一张。
- 上传任务使用服务端签发的 COS PUT 地址。机位之间并发，每个机位前一张确认已入库后才上传下一张。全机最多 3 个 COS 上传会话同时传输。队首原片还在写入、被移走或传输失败时，机位详情会标出该文件。将原片放回，或按提示重试后继续。
- 网络失败最多自动尝试 3 次，之后保留失败任务供手动重试；停止会等待当前文件结束，原照片不删除。
- 来源和目标对应的任务日志在系统应用支持目录 `auto-upload/`，每次状态变化刷盘；
  重启后自动恢复启用的监听和未完成任务。存量机位可点击「恢复旧目录监听」，沿用原日志和待传副本。需要补传原目录已忽略的照片时，可在启动前选择「补扫旧目录已有照片」。在两个拍摄批次之间停止向旧目录投递，待旧队列处理完毕后点击「切换到托管目录」。
  日志不含机位密钥，但包含本地文件路径；待传副本占用磁盘，成功后清理。
- 桌面端可在托盘继续监听，退出前须停止监听及活动任务。iOS 回到前台时恢复启用的监听。

Windows 已在蓝月谷 A99 用合成照片复验 COS 直传和后台归卡。现场实拍、移动端和 macOS 真机仍待验收。
macOS 和 iPad 恢复旧目录时继续使用原安全书签，授权失败会在对应机位显示。
iPad 机位的托管目录在「文件 → 我的 iPad → 帧集快拍 → CameraInbox」下，通过机位详情复制路径核对。相机软件需支持写入该目录。仅支持前台监听，云盘照片请先下载到本机。

## Windows 开发

使用 PowerShell 7、Flutter、已加入 `PATH` 的 Node.js 22 和 Visual Studio 的 Desktop development with C++ 工作负载。先从系统托盘退出已运行的工作台，再在本目录启动源码调试。

```powershell
.\run-windows.ps1
```

脚本从 `PATH` 或 `%USERPROFILE%\develop\flutter` 查找 Flutter，也可用 `-Flutter` 指定 `flutter.bat`。保存 Dart 修改后，在运行终端按 `r` 热重载，修改入口或初始化逻辑后按 `R` 热重启。修改 Windows 原生代码、依赖或 Node 打印内核后，按 `q` 退出并重跑命令。

上传使用系统安全存储中的机位档案。联调其他环境时，通过 Flutter 的 `--dart-define=LVPAI_WORKSTATION_API_BASE=<HTTPS 网关地址>` 指定该环境的 HTTPS 网关根地址，再用对应环境签发的机位凭据配置。旧档案的网关地址与当前网关一致时可直接使用，切换网关后需填写当前网关的机位凭据。打印运营 API 默认是 `https://hilvpai.com/api/operation`，可在启动前用 `PRINT_AGENT_BASE` 显式选择；打印页需激活对应景区密钥档案。

Windows 本地 Debug 构建已通过用户级 Flutter 3.50.1 验证。需要复现 CI 时使用上文的 FVM 配置。严格校验依赖锁文件时运行 `flutter pub get --enforce-lockfile`；下载工具链和依赖的镜像配置见上文的接续开发步骤。
2026-11-18 已通过管理员命令补齐 **C++ CMake tools for Windows**、
**Desktop development with C++** 工作负载及 **C++ ATL**（安全存储插件编译所需）。
Windows release 构建通过，EXE 为 `build/windows/x64/runner/Release/lvpai_ftp_client.exe`。
0.3.0 测试通道便携包为 `build/releases/test/windows-x64/lvpai-ftp-0.3.0-3-windows-x64.zip`，解压后运行 EXE。
发布需打包整个 `build/windows/x64/runner/Release/`，不能只复制 exe。
macOS / iPad 的构建、签名及真机验证需在 Mac 上完成；当前未验证苹果端。

## Git 边界

保留 lib、test、pubspec.yaml、pubspec.lock、analysis_options.yaml 及原生 runner 工程。
忽略 SDK、依赖缓存、生成代码、构建输出、临时图片、本地配置和凭据；不忽略锁文件。
业务照片和 FTP 账号不得写进代码、测试报告或仓库。

## 测试

默认运行表单、响应式布局及本地队列测试。真实 FTP 集成测试通过 `FTP_TEST_PORT` 启用，
只允许连接 127.0.0.1；使用隔离临时服务器的 `test-user/test-password` 账号，需支持 MLSD 和 SIZE。
它验证真实连接、上传字节完整性、重复拒绝、错误密码、无效目录；不是生产服务器验收。

可在任一开发机器启动持久维护的隔离测试工具：

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r tool/requirements-test.txt
.venv/bin/python tool/ftp_test_server.py
```

Windows用`python -m venv .venv`，随后用`.venv/Scripts/python.exe`替代上述Python路径。
服务器输出随机端口，仅监听127.0.0.1，关闭时删除临时测试上传文件。
另开终端，Mac执行`FTP_TEST_PORT=输出端口 flutter test`；
Windows先执行`$env:FTP_TEST_PORT='输出端口'`再执行`flutter test`。
账号只用于隔离测试，请勿将其用于真实服务器。

2026-11-18，0.3.0+3：`flutter analyze` 无问题，配置隔离FTP后全部17项测试通过。
覆盖375/768/1280布局、日志恢复/损坏拒绝/独占锁、真实FTP传输、慢写与重启补扫、冲突保护、
有限重试与中断恢复、受控苹果目录授权通道，以及更新清单/下载校验和失败清理。
证据为父仓 `.local/ftp-release-{analyze,all-tests}.log`，不入Git。
苹果目录通道测试不代替原生Swift编译、系统选择器/Keychain和真机验收；真实相机/WiFiSD也尚未验收。

## 发布与更新（0.3.0）

复用现有安卓版本管理的 COS/CDN 上传和管理权限，新增 Windows、Mac 两种架构及 iPad/iOS 产品。
桌面端提供「检查更新」，下载后验证大小和 SHA-256，再由用户打开安装包；iOS 仅打开正式 Apple 安装入口。
下载页是 `site/` 内的纯静态文件，无浏览器运行时或服务端随客户端打包。
发布操作、Mac 签名和版本路径见 [RELEASING.md](RELEASING.md)，苹果测试见 [APPLE_TESTING.md](APPLE_TESTING.md)。

Windows 0.3.0+3 测试 ZIP 为 12,285,224 字节（约 11.7 MiB），尚未签署 Windows 代码签名。
新增更新功能后静态检查通过，17 项客户端测试通过（含回环 FTP 真实传输）；
管理发布/清单 5 项受控测试和下载页桌面/手机浏览器测试通过。
上述记录是 2026-11-18 的本地构建结果。发布渠道与签名要求见[发布手册](RELEASING.md)。


## 上传前照片标准化

自动监听在文件写入稳定后复制到私有队列，再在后台隔离任务中标准化。

- 普通 JPEG、PNG 保留原字节。
- MPO 和内部包含 MPF 索引的 JPG，按索引取代表图。没有代表图标记时使用唯一的基线主图。缩略图不入队。上传副本移除主图内的 MPF 索引，保留 JPEG 压缩像素、EXIF 和 ICC。
- `.heic`、`.heif` 和 `.hif` 通过系统解码器转为 JPEG。方向应用到输出画面，已有的 EXIF 拍摄时间、时区偏移和亚秒字段随副本上传。Windows 依赖可用的 HEIF/HEVC 系统解码器。解码失败时队列显示错误。
- `.cr3`、`.cr2`、`.arw`、`.nef`、`.raf`、`.rw2`、`.orf`、`.pef` 和 `.dng` 由随包 LibRaw 显影为 JPEG，保留相机记录的拍摄时间到秒。同目录、同文件名主体且原始拍摄时间相同的 RAW 和 JPEG，在 COS 队列保留先入队的一份。
- 单页 TIFF（`.tif`、`.tiff`）、静态 WebP 和静态 AVIF 转为 8 位 JPEG。转换会应用方向，现有 EXIF 拍摄时间、时区偏移和亚秒字段随副本上传，透明区域铺白。
- 相机源文件保留。转换后再计算待传文件的摘要和大小。队列重试使用已生成的副本，历史归卡照片保留已有结果。

RAW 兼容性按相机型号和压缩模式验证。随包 LibRaw 的部分有损、浮点 HDR DNG 变体可能无法显影，队列会显示源文件错误。目标相机、HEIF HDR 与苹果设备待实机验收。[RawKit 格式与构建说明](https://pub.dev/packages/rawkit)
