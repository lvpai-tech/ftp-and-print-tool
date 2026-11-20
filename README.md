# 旅派照片 FTP 客户端

独立 Flutter 应用，共用 Windows / macOS / iOS 的 Dart 上传队列；苹果端包含原生目录授权代码，待 Mac 编译及真机验收。

公开仓可用 GitHub Actions 打 **未签名** macOS 内测包：仓库 Actions 页手动运行 `Build macOS`，下载 Artifact `lvpai-ftp-macos-unsigned`。正式对外分发仍须按 [RELEASING.md](RELEASING.md) 签名与公证。

拷到 Mac 后的完整运行、签名和测试步骤见 [APPLE_TESTING.md](APPLE_TESTING.md)。

## 设计与维护

主界面上方为机位摘要与「手动上传模式 / 自动上传模式」切换；FTP 配置收在右侧抽屉，
未保存配置时显示空状态引导。连接/上传必须使用实际 FTP 服务，不内置服务器地址、样例照片或假成功。

源码边界：

| 文件 | 职责 |
| --- | --- |
| `lib/main.dart` | 启动入口 |
| `lib/app.dart` | 应用主题及页面入口 |
| `lib/ui/transfer_page.dart` | 表单、选图、队列交互与进度展示 |
| `lib/profile_store.dart` | 系统安全存储，界面不处理存储格式 |
| `lib/transfer.dart` | 配置模型和真实 FTP 传输 |
| `lib/ui/auto_upload_panel.dart` | 自动模式设置、状态与任务列表 |
| `lib/ui/manual_batch_panel.dart` | 手动建议分组、照片增减、结束照核对和逐批确认上传 |
| `lib/manual_batch/` | 条码识别、不可变副本、持久化批次及最后提交清单 |
| `lib/auto_upload/folder_uploader.dart` | 稳定检测、扫描补偿、任务调度与重试 |
| `lib/auto_upload/journal.dart` | 队列追加日志、恢复与独占锁 |
| `lib/auto_upload/folder_access.dart` | 平台目录授权通道，苹果端使用原生安全书签 |
| `lib/release/update_service.dart` | 平台与通道清单校验、下载及完整性核验 |
| `lib/ui/update_button.dart` | 手动检查更新、下载进度与打开安装包 |
| `site/`、`tool/package_release.py` | 独立静态下载页与本地打包工具 |
| `windows/`、`macos/`、`ios/` | 各平台原生工程与权限 |

保持同一份 Dart 业务源码，不引入浏览器运行时、在线字体或图片素材库。自动模式沿用原流程；
手动模式监听只在本机建议分组，可增减照片，点击上传后固定成员，失败重试原批次。
手动批次需要配套Java接收逻辑；FTP传输成功不等于归卡成功，必须检查服务端回执。
详细协议及隔离规则见父仓 `creative-travel-shoot` 文档 `docs/project/FTP手动批次上传-20261119.md`。

体积基线（Windows x64 release 0.3.0+3，2026-11-18）：ZIP为12,285,224字节，约11.7 MiB。
完整包包含EXE、Flutter引擎、插件DLL和data；SDK、编译器、源码、测试与业务照片不打进发布包。
这是该版本构建实测，并非后续版本的体积保证。

## 两台电脑接续开发

统一 Flutter **3.50.0 / Dart 3.14.0**，`.fvmrc`记录版本；使用FVM时先`fvm install`，
再将下述`flutter`替换成`fvm flutter`。不用FVM则自行安装同版本Flutter，不默认升级依赖。
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

## 手动模式

- 配置一台 FTP 服务器，测试登录与目标目录，保存到系统安全存储。
- 多选 JPEG / PNG 原图、顺序上传、进度展示、失败重试、当前文件结束后停止。
- 被动 FTP / 二进制传输；服务器确认完成且远端 SIZE 与本地一致后标成功。
- 上传前查询同名文件，发现同名则拒绝；失败不自动覆盖重传。失败留下的部分文件需要人工核对；当前不支持断点续传、并行写入同名文件的原子防覆盖。
- 明文 FTP，仅适用于可信网络；FTPS、SFTP、直接连接相机及系统后台服务不属于当前实现。
- 测试连接只验证登录与切换目录，不声称验证写权限。

## 自动监听

先让相机 WiFi SD 卡配套软件将照片保存到电脑文件夹，再在应用切换「自动监听」，
选择这个文件夹，确认服务器后点击「开始监听」。应用监听本地落盘，不接管 SD 卡无线传输协议。

- 默认包含子文件夹，首次开始只处理之后新增或变化的 JPEG / PNG；勾选「同时扫描已有照片」可补传历史图。
- 文件大小和修改时间连续稳定 3 秒后，复制到应用私有待传区，检查图片头尾、解码及 SHA-256，再入队。
- 文件事件加每 2 秒补扫，按顺序批量传输；界面区分等待写入、待传、成功和失败。
- 自动创建远端相对子目录。先上传任务专属 `.part` 文件，下载校验 SHA-256，再改为正式文件名并复核。
  同路径同内容可恢复成功，同名不同内容明确报错。校验需要远端读权限，会额外下载照片两次，增加流量及耗时。
- 网络失败最多自动尝试 3 次，之后保留失败任务供手动重试；停止会等待当前文件结束，原照片不删除。
- 来源和目标对应的任务日志在系统应用支持目录 `auto-upload/`，每次状态变化刷盘；
  重启后再次开始监听会恢复未完成任务，并补扫关闭期间新增照片。首次忽略的旧照片记录保留。
  日志不含 FTP 密码，但包含本地文件路径；待传副本占用磁盘，成功后清理。
- 桌面端最小化后继续工作，退出应用停止；iOS切到后台/锁屏停止派发新任务，系统可能中断当前传输，
  回到前台需再次点击开始监听补扫和恢复；暂未实现托盘、开机启动和睡眠唤醒专项处理。

请为此客户端使用专属远程目录。标准 FTP 的改名无法保证多个独立写入方之间的原子防覆盖，
队列锁仅防止本机同队列双实例。源文件若内容变化却保持大小及修改时间不变，不保证能发现。
当前保留全部历史任务日志，尚无历史清理/压缩界面，长期海量任务需后续补充。

Windows 已完成隔离 FTP 自动流程验证，真实相机及 WiFi SD 卡尚未联调。
macOS以系统选择器授权并保存只读安全书签；失效或撤权时明确报错并要求重新选择。
iPad自动监听已启用，仅限前台和有权限读取的本机目录。可选择系统目录，或使用「本机收图文件夹」，
通过「文件 → 我的iPad → 旅派 FTP → CameraInbox」存图。相机软件必须支持写入该目录，
不能读取其他应用的私有沙盒，不能像桌面端一样常驻后台。云盘目录未适配云端下载/文件协调，请先下载到本机。

## Windows 开发

使用上文固定的 Flutter 3.50.0 和 Visual Studio 的 Desktop development with C++ 工作负载。
在本目录执行：

```powershell
$env:PUB_HOSTED_URL='https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn'
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter run -d windows
flutter build windows --release
```

本仓本机 SDK（不入库）为 `../.local/flutter-sdk/bin/flutter.bat`。
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
本轮仅本地实现与打包，下载页和安装包尚未发布线上；Mac/iOS 原生编译、签名及真机验收仍需 Mac。


## 上传前照片标准化

自动监听及手动批次均在写入稳定后复制到私有队列，然后在后台隔离任务中标准化。
JPEG中的MPF多图索引（包括扩展名仍为JPG的文件）会被移除，只上传第一张主JPEG；
显式MPO文件上传扩展名为.jpg。不会重压缩像素，EXIF拍摄时间/方向及ICC段原样保留，
不烘焙方向、不伪造缺失的拍摄时间。相机源文件不修改。
普通JPEG/PNG保持原字节；损坏JPEG主图明确报错，不用附图替代。实际解码沿用入队校验。
转换发生在计算待传摘要和大小之前，手动清单与重试校验均以转换后的固定副本为准。
MPO改为.jpg后若与远端已有同名不同内容冲突，沿用显式冲突保护，禁止覆盖。
本轮支持JPEG/PNG及MPO主图；未增加HEIF、RAW或TIFF解码，不代表苹果真机已验证。
生产历史照片不随客户端升级自动转换或重试。
