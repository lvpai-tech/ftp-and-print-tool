# FTP 客户端发布与下载

2026-11-19 实现版本为 `0.3.0+3`。FTP版本接口、管理发布页与CDN下载页已上线，安装包清单尚未发布。
Windows生产通道ZIP已构建，SHA-256为`25a204f9b7b2fcdd3bef018727b6f66809d7cbd022fc3790f9996c5e2a2bbd6b`，
大小12,285,212字节；当前EXE为NotSigned，正式分发前仍须按下文签名并重新打包校验。
苹果端仍需在 Mac 上编译及真机验收。此文区分本地打包与线上发布；打包脚本不会上传任何文件。

## 发布方式

复用现有安卓 APK 发布链路：管理端申请 COS 直传地址，浏览器上传完整安装包，后端核对实际大小与
SHA-256 后写入对应平台的 `latest.json`。旧安卓和打印端目录保持原有规则。

| 管理端产品 | platform | 分发文件 |
| --- | --- | --- |
| FTP Windows x64 / `FTP_WINDOWS_X64` | `windows-x64` | 完整 Release 的 ZIP |
| FTP Mac Apple 芯片 / `FTP_MACOS_ARM64` | `macos-arm64` | Developer ID 签名、公证的 DMG |
| FTP Mac Intel / `FTP_MACOS_X64` | `macos-x64` | Developer ID 签名、公证的 DMG |
| FTP iOS / `FTP_IOS` | `ios` | App Store 或 TestFlight 官方链接 |

安装包按平台、环境隔离：

```text
https://cdn.hilvpai.com/ftp-client/{local|test|prd}/{platform}/latest.json
https://cdn.hilvpai.com/ftp-client/{env}/{platform}/lvpai-ftp-{versionName}-{versionCode}-{platform}.{zip|dmg}
```

二进制清单必填：`versionCode`、`versionName`、`platform`、`channel`、`installerUrl`、`sizeBytes`、`sha256`。
iOS 清单用 `storeUrl` 替代文件地址、大小及校验值，不通过本站分发裸 IPA。
版本号由 `pubspec.yaml` 管理，`+` 后构建号必须递增（每个平台、环境独立比较）。
客户端通过编译参数 `LVPAI_UPDATE_ENV` 固定通道，默认 `prd`；不会自动将 test 切换到 prd。

## Windows 本地打包

需要 Python 3.11+、Flutter、Windows C++ 工具链和 x64 Node 20 或更高版本（CI 使用 Node 22），在 Flutter 仓库根目录执行：

```powershell
$env:PUB_HOSTED_URL='https://pub.dev'
$env:FLUTTER_STORAGE_BASE_URL='https://storage.flutter-io.cn'
flutter pub get --enforce-lockfile
flutter analyze
flutter test
python tool/package_release.py --platform windows-x64 --channel test
```

也可通过 `--flutter`、`--node` 指定本机工具。Node 发行包若将 `LICENSE` 放在其它目录，使用 `--node-license` 指定该版本的许可证。
脚本重新构建指定通道，打包 EXE、DLL、data 和从本仓生成的 `print-runtime`，排除 PDB，输出到 `build/releases/test/windows-x64/`。
如果需要每用户一键安装器，安装 Inno Setup 6.7 后加 `--iscc` 传入 `ISCC.exe` 的完整路径。同一次构建额外生成 `*-setup.exe`、`*.exe.sha256` 和 `setup-release-info.json`，安装器会带上构建所用 Visual Studio 的 x64 VC++ 可再分发 DLL。
安装器默认使用 `%LOCALAPPDATA%\Programs\Lvpai\ZhenjiWorkstation`，提供桌面与开始菜单快捷方式，并在 Windows「已安装的应用」登记卸载。先从系统托盘退出工作台，再安装或卸载。相同 Windows 账户继续使用 `%APPDATA%\ai.lvpai\lvpai_ftp_client` 中的现有配置及队列。
便携 ZIP 沿用原有清单。带更新器的签名安装版使用独立的 Setup.exe 清单。测试安装器也可从 Windows Actions 的 `lvpai-ftp-windows-x64-setup` 产物领取。
若 MSBuild 报路径过长，从较短的源码路径构建。使用 `subst` 时，将项目放在映射盘的子目录。
`release-info.json` 仅用于核对管理表单，不是已经发布的线上清单。同版本输出已存在时脚本明确失败，
应提升版本号，或先明确归档自己的旧产物，避免误覆盖。

本机当前测试包为 `lvpai-ftp-0.3.0-3-windows-x64.zip`，12,285,224 字节，SHA-256：

```text
ac96a332718dc7f2b02bed4f62f928767d38d64889215c08965924979608ae7b
```

解压到可写目录后运行 `lvpai_ftp_client.exe`。此包未做 Windows 代码签名。
正式 Windows 发布前使用项目持有的代码签名证书签署 EXE/DLL，再将完整 Release 重新打包、计算校验和；
不能在后台校验或生成清单之后再修改安装包。当前脚本不代办 Windows 签名。

## GitHub Actions 构建产物

workflow 文件进入默认分支后，在 GitHub Actions 选择对应构建任务和分支。下列任务使用 Flutter 3.50.0 和锁文件指定的包源。Android 和 iOS 保持 `test` 通道。Windows 和 macOS 可选 `local`、`test`、`prd`，默认 `prd`。关闭 `publish_update` 时生成供手动验收的安装包，保留 14 天。

| Workflow | 产物 | 用途 |
| --- | --- | --- |
| `Build Android APK` | `lvpai-ftp-android-debug.apk` | Android 调试签名包，可安装测试手动上传 |
| `Build iOS` | `lvpai-ftp-ios-unsigned.zip` | iPhone/iPad 设备 Release 构建，内含未签名 `Runner.app`，真机安装需另行签名 |
| `Build Windows` | `lvpai-ftp-<版本>-<构建号>-windows-x64.zip` | 未签名的完整 x64 Release，含 Node 打印内核；SHA-256 见随包的 `release-info.json` |
| `Build Windows` | `lvpai-ftp-<版本>-<构建号>-windows-x64-setup.exe` | 未签名的每用户 x64 安装器，附独立 SHA-256 和 `setup-release-info.json` |
| `Build macOS` | `lvpai-ftp-macos-personal.zip` | 个人跨机包：临时签名 `.app` + 随包打印内核 +「打开旅派客户端.command」；其他 Mac 首次需右键打开。不是公证正式包 |
| `Build macOS` | `lvpai-ftp-<版本>-<构建号>-macos-<架构>-personal.dmg` | 选择 `lvpai-ftp-macos-personal-dmg` 产物并解压，挂载 DMG 后将工作台拖入「应用程序」。使用 ad hoc 签名，首次打开可能需在「隐私与安全性」选择「仍要打开」。附 SHA-256 文件 |

正式 iOS 分发沿用下文的 Xcode、App Store Connect 和 TestFlight 流程。

## macOS 内测 DMG 的 COS 存档

`Build macOS` 可将已有的 Apple 芯片个人内测 DMG 传到 `ftp-client/test/macos-arm64/ci/<批次>/<文件名>`，供 CDN 手动下载。客户端更新按[桌面自动更新测试通道](#桌面自动更新测试通道)发布。

1. 运行 `Build macOS` 生成个人内测 DMG。下载该运行的 `lvpai-ftp-macos-personal-dmg` 产物，解压后用随包的 `.dmg.sha256` 核对 DMG。记下来源运行 ID。
2. 在持有授权 COS 凭据的可信机器上，用 Python SDK 创建 `CosS3Client`，调用 [上传脚本](tool/upload_macos_cos_smoke.py) 的 `prepare_plan(client, bucket, key, dmg)`。`bucket` 传入桶全名，`key` 使用本节的存档前缀和新批次，`dmg` 是指向原 DMG 的 `Path`。返回的计划有效 30 分钟，包含该对象的 `upload_id`、源文件 SHA-256、各分块和合并的预签名地址。将计划序列化为 JSON，存入 GitHub `cos-test` 环境的 `COS_SMOKE_PUT_URL`。长期 COS 密钥留在可信机器上。 [GitHub 环境 Secrets](https://docs.github.com/en/rest/actions/secrets#create-or-update-an-environment-secret)
3. 手动运行 `Build macOS`，分支选 `dev/huangml`，将来源运行 ID 填入 `cos_smoke_run_id`，保持 `publish_update` 关闭。`cos-smoke` job 用内置 `github.token` 下载原产物，核验 SHA-256 并并行上传 2 MiB 分块，每块校验 MD5。暂时性网络错误允许该块重试。所有分块送达后，COS 根据 ETag 顺序合并成一个 DMG。
4. 工作流成功后从 COS 读回整个文件，核对长度和 SHA-256，再核对 CDN 下载链接。测试结束后删除临时 Secret。若工作流失败，先确认运行已结束且对象尚未合并，再由可信机器按对应对象键和 `upload_id` 中止未完成的分块上传。重跑时为新批次和原产物重新签发计划。 [COS 中止分块上传](https://cloud.tencent.com/document/product/436/7740)

2026-11-23，97,070,064 字节的 Apple 芯片 DMG 已由 GitHub 托管运行器在约 5 分 21 秒内上传并合并。COS 读回 SHA-256 与原产物一致，CDN 返回 HTTP `200`。 [成功运行](https://github.com/lvpai-tech/ftp-and-print-tool/actions/runs/45164980362) · [下载内测 DMG](https://cdn.hilvpai.com/ftp-client/test/macos-arm64/ci/multipart-ae4c74d98b13/lvpai-ftp-0.4.3-7-macos-arm64-personal.dmg)

## Mac 构建与打包

先按 [APPLE_TESTING.md](APPLE_TESTING.md) 配置 Xcode、依赖及应用标识，完成目录授权与 FTP 实测。
在对应架构 Mac 上执行 `flutter build macos --release --dart-define=LVPAI_UPDATE_ENV=test`。
在最终构建完成后，把与应用同架构的 Node 和打印内核加入 `.app`，再签名。

```sh
python3 tool/bundle_print_runtime.py \
  --destination 'build/macos/Build/Products/Release/lvpai_ftp_client.app/Contents/Resources/print-runtime' \
  --node '/absolute/path/to/node/bin/node' \
  --node-license '/absolute/path/to/node/LICENSE'
```

用 Xcode 配置所属 Team、唯一 Bundle ID、Developer ID Application、Hardened Runtime 和必要 entitlements，
签署 `print-runtime/node`、嵌套 Framework 和插件，再签署外层 `.app`。保留网络客户端、用户选择目录只读及书签权限。
如 Xcode 重新构建，须保留相同 Flutter 通道配置并重新加入打印内核。签名后执行：

```sh
python3 tool/package_release.py --platform macos-arm64 --channel test \
  --app '/absolute/path/to/signed/lvpai_ftp_client.app' \
  --sign-identity 'Developer ID Application: YOUR TEAM (TEAMID)' \
  --notary-profile 'YOUR_EXISTING_KEYCHAIN_PROFILE'
```

Intel 包用 `--platform macos-x64`，不把同一架构包冒充另一架构。
`--app` 必须是当前版本、当前通道的已签名 Release；脚本检查版本、签名、Hardened Runtime、打印内核文件和目标 CPU，
但无法从二进制独立核验 Dart 编译通道，因此构建者必须核对构建记录。
脚本创建含 Applications 快捷方式的 DMG，签署 DMG，提交 Apple 公证、staple 并运行 Gatekeeper 检查，
任一步失败均不生成最终发布文件。公证凭据只存系统钥匙串，不提交到仓库。
以上 Mac 打包流程尚未在 Windows 执行验证。

iPad/iOS 用 Xcode 归档上传 App Store Connect，先通过 TestFlight 真机验证，再按需要上架。
管理端填写去掉查询参数的官方链接，例如 `https://testflight.apple.com/join/XXXXXXXX` 或
`https://apps.apple.com/cn/app/id数字`；这些示意值不能用于实际发布。
正式分发资质与苹果审核由持有开发者账号的发布者完成。

## 管理端发布步骤

1. 将本轮 operation 后端和管理端前端配套部署后，管理员进入已有客户端版本发布界面。
2. 选择 FTP 产品及 `test`，填写和包内一致的 versionCode/versionName，上传上述完整 ZIP/DMG；
   iOS 改为填写有效官方链接，不选文件。
3. 后端校验 COS 文件与客户端计算值一致，再更新清单。确认客户端「检查更新」、完整下载、
   安装启动、目录授权和隔离 FTP 传输均正常。
4. 正式发布重新构建 `--channel prd` 并完成对应签名、验证，选择 `prd`，确认生产发布。
   test 包不能直接冒充 prd 包；发布版本不能低于或等于现有版本。

以下路由位于 `/api/operation/client-releases`，沿用现有 operation 网关和管理员认证：

| 方法和路径 | 用法 |
| --- | --- |
| `GET /current?product=FTP_WINDOWS_X64&env=test` | 读取指定产品/环境的当前发布状态，未发布返回 available=false |
| `POST /prepare-upload` | 提交product/env/versionCode/versionName/contentLength/contentType，取得COS上传URL和objectKey |
| `POST /confirm` | 上传完成后提交上述版本信息、objectKey、sha256、contentLength及confirmProduction，核验后更新清单 |
| `POST /publish-ios-link` | 提交env/versionCode/versionName/storeUrl/confirmProduction，发布iOS官方入口 |

FTP二进制的contentType为`application/octet-stream`。接口返回沿用项目`Result`包装，
`PARAM_ERROR`包括低版本、错误链接、大小/校验和不符和生产未确认；
`STATE_CONFLICT`包括文件已存在、文件未上传或存储读取失败。
请求/响应具体字段以父仓DTO/VO为准；客户端不访问管理接口，直接读取公开CDN清单。
现有 COS 清单更新不是分布式原子版本比较，请串行发布同平台同环境版本；本轮没有引入并发发布锁。
发现问题应发布更大构建号的修复版本，不能用覆盖旧同名包或降版本绕过校验。

<a id="桌面自动更新测试通道"></a>

## 桌面自动更新发布

在 `Build Windows` 或 `Build macOS` 手动运行表单选择 `dev/huangml`、`channel` 和 `publish_update`。`channel` 默认 `prd`，也可选 `test` 或 `local`。开启 `publish_update` 后，工作流签名并直接发布到对应通道的 COS。`channel` 同时决定客户端编译参数、应用名称和更新路径。`local` 发布使用 CDN 的 `local` 目录，可用于指定该通道的本地安装。

运营人员只需选择通道和发布开关。版本名称及构建号来自仓库 `pubspec.yaml`，例如 `0.4.5+9` 对应版本 `0.4.5`、构建号 `9`。每个平台、通道的新版构建号须高于该清单已发布版本。工作流核对打包元数据、安装包 SHA-256 和发布通道，分块上传并在 CDN 读回包大小后写清单，再读回核对清单。版本化对象禁止覆盖。重试已上传的同名安装包时使用与前次完全一致的制品。

| 构建 | 更新入口 | 发布产物 |
| --- | --- | --- |
| Windows x64 | `ftp-client/{channel}/windows-x64/setup/latest.json` | Authenticode 签名的 `*-windows-x64-setup.exe` |
| macOS Apple 芯片 | `ftp-client/{channel}/macos-arm64/appcast.xml` | Developer ID 签名、公证、Sparkle EdDSA 签名的 `*-macos-arm64.dmg` |

在 GitHub 对应的 `cos-prd`、`cos-test` 或 `cos-local` 环境配置下列参数，并允许 `dev/huangml`。COS 凭据按对应通道限制到 Windows `setup/` 及 macOS DMG、`appcast.xml`，允许读取、写清单和初始化、上传、完成及中止分块。发布桶须支持 `ForbidOverwrite`。macOS 个人包存档单独使用 `cos-test`，见 [COS 存档](#macos-内测-dmg-的-cos-存档)。

| 范围 | Secrets | Variables |
| --- | --- | --- |
| COS | `COS_SECRET_ID`、`COS_SECRET_KEY` | `COS_BUCKET`、`COS_REGION` |
| Windows | `WINDOWS_SIGNING_PFX`（Base64）、`WINDOWS_SIGNING_PASSWORD` | |
| macOS | `MACOS_SIGNING_P12`（Base64）、`MACOS_SIGNING_PASSWORD`、`MACOS_NOTARY_APPLE_ID`、`MACOS_NOTARY_PASSWORD`（应用专用密码）、`SPARKLE_PRIVATE_KEY`（`generate_keys -x` 导出的文本） | `MACOS_SIGN_IDENTITY`、`MACOS_NOTARY_TEAM_ID`、`SPARKLE_PUBLIC_KEY` |

现场先手动装一版带更新器的签名包，再在同一通道发布更高构建号。`test` 显示「帧集快拍（测试版）」，`local` 显示「帧集快拍（本地版）」，`prd` 显示「帧集快拍」。Windows 沿用安装标识和数据路径，更新前后通过 Authenticode 验证且使用同一证书。更换证书时，先分发使用新证书的首装包。macOS 沿用应用标识和非沙箱数据目录，需核对新签名下的钥匙串、收图目录和队列访问。

「检查更新」发现新版并确认后，应用下载和验证包，暂停接收新的上传任务并保留队列，等待当前上传与打印结束，再安装并重开工作台。复核版本、机位绑定、监听恢复、上传队列及打印档案。自动打印沿用每次启动需现场开启的规则。

## 下载页上线

`site/` 只需部署 `index.html`、`style.css`、`releases.js`、`download.js` 四个文件到
COS 的 `ftp-client/` 目录。入口 `https://cdn.hilvpai.com/ftp-client/index.html` 已于2026-11-19上线，四个平台在没有有效清单时显示“尚未发布”。
不上传 package.json、依赖、源码或测试数据。设置正确 HTML/CSS/JavaScript Content-Type；
这四个文件和 `latest.json` 使用 no-cache，版本化安装包可以长缓存且禁止覆盖。

网页同源读取四个平台的 prd 清单，没有版本时明确显示「尚未发布」；清单格式或网络错误显示失败，
不展示虚构下载按钮。客户端下载后额外校验大小及 SHA-256；网页展示校验值供用户核对。
客户端下载失败会清理不完整缓存。桌面签名安装版使用上节的自动更新流程，便携 ZIP 与个人 DMG 使用手动安装入口。
iOS 点击官方安装入口，由 Apple 完成分发更新。

本地预览可执行 `python -m http.server 5189 --bind 127.0.0.1 --directory site`，
访问 `http://127.0.0.1:5189/`。本地没有真实清单时显示尚未发布，不需创建假数据。

## 验证与交接

下载页可在仅复制客户端源码的机器独立测试（需Node.js和Playwright Chromium）：

```sh
cd site
npm install
npx playwright install chromium
npm test
cd ..
```

`node --test tool/release.test.cjs`还读取父仓`frontend/operation-web/live-bridge.js`，
因此需要完整仓库；它不是独立客户端源码包的测试入口。
Flutter真实FTP测试准备见[客户端测试](README.md#测试)，未设置`FTP_TEST_PORT`会跳过网络用例。

本轮 `flutter analyze` 无问题，完整 17 项 Flutter 测试通过（含真实隔离回环 FTP）；
`node --test tool/release.test.cjs` 的 5 项测试通过，下载页 Playwright 桌面/手机浏览器测试通过。
前端测试使用明确的受控接口/清单，不是生产 COS 发布验收。
Java25 隔离源码副本的 common、operation `clean verify` 通过，operation 135 项测试中 4 项既有跳过。
没有把这些结果作为全仓六模块、微信原生或完整阶段门禁通过证据。

复制 `ftp-client` 到 Mac 可独立接续客户端；管理端及 Java 发布能力位于父仓，单独客户端源码包不包含它们。
源码包不携带 SDK、缓存、FTP 账号、业务照片、签名证书或发布凭据。
未完成项：苹果原生编译与真机验收、Windows 正式签名、后端/下载页部署、真实发布与下载验证。
