# Mac / iPad 接续开发与验收

本目录可独立开发，无需启动旅派 Java、小程序或数据库。共用 Flutter 3.50.0 / Dart 3.14.0，
保留 pubspec.lock。源码包不包含 SDK、缓存、账号或 Windows 编译结果。
本轮在 Windows 完成 Dart 检查与隔离 FTP 测试，尚未用 Xcode 编译；原生授权与签名需按下面步骤实际验收。
当前版本为 0.3.0+3，新增检查更新及纯静态下载页；签名、打包和发布步骤见 [RELEASING.md](RELEASING.md)。

## Mac 准备

安装完整 Xcode 并打开一次接受许可，完成命令行工具设置，安装同版本 Flutter。
具体 Xcode/系统兼容要求以此版本 `flutter doctor -v` 的输出为准，不直接升级项目依赖。
可使用 FVM：项目已有 .fvmrc；运行 fvm install 后把下文 flutter 换成 fvm flutter。

解压源码包，在含 pubspec.yaml 的 ftp-client 目录执行：

```sh
flutter --version
flutter doctor -v
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
flutter pub get --enforce-lockfile
flutter analyze
flutter test
flutter run -d macos
```

默认 flutter test 不配置 FTP_TEST_PORT 时会跳过真实网络用例，不能把它作为完整 FTP 验收。
当前锁文件记录了 pub.flutter-io.cn 源，以上环境变量让Mac保持相同依赖来源；仅影响当前终端。
首次构建会下载苹果端引擎/依赖，若 doctor 提示缺少 Xcode 组件或 CocoaPods，先按提示补齐。
不复制 Windows 的 .dart_tool、build、ephemeral 或本机 SDK 到 Mac。

## Mac 测试

1. 准备独立测试 FTP 目录，填写主机、端口、用户名、密码和远程目录，保存并测试连接。
2. 手动模式选择多张 JPG / PNG，上传后到服务器下载，确认照片可打开且字节一致。
3. 自动模式通过系统选择器选择一个本机文件夹，点击开始监听后复制新照片；稳定约3秒后入队。
4. 测试子目录、中文文件名、一次10张、断网重试、停止再开始；本地原图应保留。
5. 停止监听后退出应用；在收图目录新增照片，重开并开始监听，确认书签授权恢复和离线照片补传。
6. 移动目录后重试，若系统书签无法恢复，应提示失败并重新选择，不能显示虚假成功。
7. 保存FTP配置后重开，核验Keychain恢复；若签名/Keychain报错，在Xcode核对Signing & Capabilities。

Debug通过后还须测Release，因为两套沙盒权限分别生效：

```sh
flutter build macos --release
open build/macos/Build/Products/Release
```

运行目录中的完整 .app；不要只复制内部可执行文件。不关闭App Sandbox或申请全磁盘访问绕过目录授权。
Mac原生工程入口：macos/Runner.xcworkspace。签名团队与证书由本机配置，不提交个人凭据。

个人跨机（不申请 Developer ID）可用仓库脚本打临时签名包，含打印内核与「打开旅派客户端.command」：

```sh
flutter build macos --release --dart-define=LVPAI_UPDATE_ENV=test
./tool/package_macos_personal.sh
```

产物在 `dist/lvpai-ftp-macos-personal.zip`。其他 Mac 首次需右键打开；正式对外分发仍按 [RELEASING.md](RELEASING.md)。

## iOS / iPad

先用模拟器检查界面和编译：

```sh
flutter build ios --simulator
open -a Simulator
flutter devices
```

从 flutter devices 输出选取 iPad 模拟器 ID，执行 `flutter run -d <设备ID>`。
真机连接、解锁、信任 Mac，按系统要求开启开发者模式；在 Xcode 打开：

```sh
open ios/Runner.xcworkspace
```

选 Runner target，在 Signing & Capabilities 中选择自己的 Team，启用自动签名，再选择 iPad 运行。
若默认Bundle ID无法由团队签名，可在首次安装前设定团队自己的唯一ID；之后保持稳定，改ID会创建另一应用/Keychain身份。
项目已关联 Runner/Runner.entitlements 的Keychain配置。无需填写虚假的后台音频/定位权限。
构建真机未签名产物可用 `flutter build ios --release --no-codesign`，该产物不能直接安装，安装仍需签名。

iPad手动上传可从系统「文件」选择多张 JPG / PNG；相册照片可先在「照片」分享菜单存储到「文件」。
当前不支持HEIC/RAW，不自动把它们伪装成JPEG。首次连接局域网FTP时允许「本地网络」权限；
拒绝后需在系统设置中恢复。真机FTP主机填写服务器的局域网地址，127.0.0.1代表iPad自身。

自动模式有两种来源：

- 「选择监听文件夹」：系统文件选择器授予目录访问，原生层保存书签；只使用已下载到本机的目录。
- 「使用本机收图文件夹」：创建 Documents/CameraInbox，出现在「文件 → 我的 iPad → 帧集快拍」中；
  应用支持文件共享，亦可从Mac Finder导入。其他相机软件须支持通过系统文件功能写入此目录。

测试步骤：先开始一次监听建立基线，切到「文件」复制新照片（此时监听会停止），返回应用再点击开始监听，
应补扫并上传；若先放入照片再首次开始，则勾选「同时扫描已有照片」。
再测锁屏/切后台、重开App、拒绝目录授权、取消选择器、撤销本地网络权限和存储不足的提示。
切后台会停止新任务，系统可能在当前文件结束前挂起应用；恢复后通过持久队列/远端内容核验处理未完成任务。
本实现不保证后台FTP常驻。若相机App仅支持自己的私有目录，不能直接监听，需要该App导出到授权目录。
真实WiFi SD卡接收协议、iCloud/File Provider云端同步和跨App持续后台接收尚未适配。

## 隔离 FTP 自动化回归

在Mac新终端、项目目录启动只监听回环地址的临时FTP：

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r tool/requirements-test.txt
.venv/bin/python tool/ftp_test_server.py
```

复制输出的随机端口，在另一终端执行 `FTP_TEST_PORT=<端口> flutter test`。
这个用例只用于本机自动化，不能从iPad真机连接，也不要把测试工具开放到公网。
它验证慢写、恢复、冲突保护及真实传输；目录授权通道测试是受控测试，不替代原生选择器/书签真机验收。

原生实现依据：[Apple目录访问](https://developer.apple.com/documentation/uikit/providing-access-to-directories)、
[安全书签](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access)、
[局域网权限](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)、
[iOS后台挂起规则](https://developer.apple.com/documentation/uikit/preparing-your-ui-to-run-in-the-background)。
