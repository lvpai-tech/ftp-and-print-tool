import Cocoa
import FlutterMacOS
import Sparkle

class MainFlutterWindow: NSWindow {
  private var folderAccess: PhotoFolderAccess?
  private var desktopUpdater: DesktopUpdater?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    folderAccess = PhotoFolderAccess(messenger: flutterViewController.engine.binaryMessenger)
    desktopUpdater = DesktopUpdater(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

private final class DesktopUpdater: NSObject, SPUUpdaterDelegate {
  private let channel: FlutterMethodChannel
  private var updater: SPUUpdater?
  private var feed: String?
  private var prepared = false

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ai.lvpai.ftp/desktop-update", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self, call.method == "check", let feed = call.arguments as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
            Data(base64Encoded: key)?.count == 32 else {
        result(false)
        return
      }
      do {
        if self.updater == nil {
          self.feed = feed
          let driver = WorkstationUpdateDriver(hostBundle: .main, delegate: nil)
          driver.prepareUpdate = { [weak self] completion in
            guard let self = self else { completion(false); return }
            self.channel.invokeMethod("prepare", arguments: nil) { response in
              self.prepared = (response as? Bool) == true
              completion(self.prepared)
            }
          }
          let updater = SPUUpdater(
            hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
          try updater.start()
          updater.automaticallyChecksForUpdates = false
          self.updater = updater
        }
        self.updater?.checkForUpdates()
        result(true)
      } catch {
        result(FlutterError(code: "UPDATE_START", message: "无法启动 macOS 更新器", details: nil))
      }
    }
  }

  func feedURLString(for updater: SPUUpdater) -> String? {
    return feed
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    guard prepared else { return }
    prepared = false
    channel.invokeMethod("recover", arguments: nil)
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
