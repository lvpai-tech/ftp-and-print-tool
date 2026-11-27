# 桌面打印内核

`src/flutter-bridge.cjs` 是 Flutter 的启动入口。它通过标准输入输出接收命令和返回状态，使用 Node 内置模块调用运营打印接口，并通过 `scripts/` 里的 Windows 或 macOS 命令出纸。Windows 使用 `printer-status.ps1` 读取打印机和队列状态。macOS 通过本机 CUPS 的 IPP 接口读取驱动上报的缺纸、卡纸及作业状态，根据 `lp` 返回的作业 ID 逐张观察。

Windows 默认从 EXE 旁加载 `print-runtime/`，macOS 还会查找 `.app/Contents/Resources/print-runtime/`。打包脚本从本目录读取源码、系统脚本和示例配置，并加入 Node 和许可证。应用在用户应用支持目录的 `printing/config.json` 中保存打印设备档案、共用打印机 `printer` 和分辨率 `printDpi`。同一队列的旧配置自动沿用，使用过多个队列的旧配置需重新选择。独立 CLI 可通过 `PRINT_AGENT_PRINTER` 指定队列。

Windows 从源码联调打印页见[客户端开发说明](../README.md#windows-开发)。

macOS 对应的命令为 `export LVPAI_PRINT_RUNTIME="$PWD/print-runtime"` 和 `export LVPAI_PRINT_NODE="$(command -v node)"`，然后运行 `flutter run -d macos`。

使用 Node 22 从仓库根目录运行 `node --test 'print-runtime/test/*.test.cjs'`。测试使用受控本机服务与命令，实体出纸单独验收。打包方式见[发布手册](../RELEASING.md)。
