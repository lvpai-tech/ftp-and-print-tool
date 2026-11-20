# 打印照片 UI 原型（throwaway）

回答：自动打印为主、又要兼顾柜台找单与异常处理时，页面怎样排布。

## 运行

在 `ftp-and-print-tool` 目录：

```bash
flutter run -t lib/prototype/print_photos_ui_main.dart -d windows
```

或 Chrome：

```bash
flutter run -t lib/prototype/print_photos_ui_main.dart -d chrome
```

底部切换 **A 指挥台 / B 队列 / C 双焦**。假数据，不接 `PrintBridge`。

同目录另有静态 HTML 对照稿 `print-photos-ui.html`（可双击打开）。
