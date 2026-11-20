# 随包打印内核

这份目录是 Flutter 客户端打包时使用的 Node 打印内核，对应父仓 `print-desktop` 的运行时子集。

- `src/`：`flutter-bridge.cjs` 及打印调度、出纸、配置等脚本（仅 Node 内置模块）
- `scripts/print-image-mac.sh` / `print-image.ps1`：本机出纸命令
- `config.mac.example.json`：示例配置，不会自动加载

开发时仍可用环境变量指向父仓：

```sh
export LVPAI_PRINT_RUNTIME=/path/to/creative-travel-shoot/print-desktop
export LVPAI_PRINT_NODE=$(command -v node)
```

发布包默认使用可执行文件旁或 `Contents/Resources/print-runtime`。  
父仓 `print-desktop` 有行为变更时，把对应文件同步回这里后再构建。

不要把 Node 二进制提交进 Git；macOS 个人包由 workflow / `tool/package_macos_personal.sh` 在构建时下载。
