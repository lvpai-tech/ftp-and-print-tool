import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private var folderAccess: PhotoFolderAccess?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    folderAccess = PhotoFolderAccess(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// 持有用户选择目录的只读作用域，重启后通过书签重新授权。
private final class PhotoFolderAccess {
  private let channel: FlutterMethodChannel
  private let bookmarkKey = "ftp.watch.bookmark.v1"
  private var activeURL: URL?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ai.lvpai.ftp/folder-access", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      do {
        switch call.method {
        case "choose":
          let panel = NSOpenPanel()
          panel.title = "选择相机照片接收文件夹"
          panel.canChooseDirectories = true
          panel.canChooseFiles = false
          panel.allowsMultipleSelection = false
          guard panel.runModal() == .OK, let url = panel.url else { result(nil); return }
          try self.activate(url)
          try self.save(url)
          result(url.path)
        case "restore":
          guard let data = UserDefaults.standard.data(forKey: self.bookmarkKey) else { result(nil); return }
          var stale = false
          let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                            relativeTo: nil, bookmarkDataIsStale: &stale)
          try self.activate(url)
          if stale { try self.save(url) }
          result(url.path)
        case "release":
          self.release()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        self.release()
        result(FlutterError(code: "FOLDER_ACCESS", message: "目录授权失败，请重新选择本机文件夹", details: nil))
      }
    }
  }

  private func activate(_ url: URL) throws {
    release()
    guard url.startAccessingSecurityScopedResource() else {
      throw NSError(domain: "PhotoFolderAccess", code: 1)
    }
    activeURL = url
    _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
  }

  private func save(_ url: URL) throws {
    let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                    includingResourceValuesForKeys: nil, relativeTo: nil)
    UserDefaults.standard.set(data, forKey: bookmarkKey)
  }

  private func release() {
    activeURL?.stopAccessingSecurityScopedResource()
    activeURL = nil
  }

  deinit { release() }
}
