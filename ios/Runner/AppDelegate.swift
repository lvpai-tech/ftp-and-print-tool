import Flutter
import UIKit
import UniformTypeIdentifiers

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var folderAccess: PhotoFolderAccess?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    folderAccess = PhotoFolderAccess(messenger: engineBridge.applicationRegistrar.messenger())
  }
}

/// 文件选择器返回的目录必须持续持有安全作用域；仅在用户明确开始时读取。
private final class PhotoFolderAccess: NSObject, UIDocumentPickerDelegate {
  private let channel: FlutterMethodChannel
  private let bookmarkKey = "ftp.watch.bookmark.v1"
  private let inboxKey = "ftp.watch.inbox.v1"
  private var activeURL: URL?
  private var scoped = false
  private var pending: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ai.lvpai.ftp/folder-access", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      do {
        switch call.method {
        case "choose":
          guard self.pending == nil else {
            result(FlutterError(code: "PICKER_BUSY", message: "文件夹选择器已打开", details: nil)); return
          }
          let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
          guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }),
                let window = scene.windows.first(where: { $0.isKeyWindow }),
                var controller = window.rootViewController else {
            result(FlutterError(code: "NO_WINDOW", message: "请回到应用前台选择目录", details: nil)); return
          }
          while let presented = controller.presentedViewController { controller = presented }
          let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
          picker.delegate = self
          picker.allowsMultipleSelection = false
          self.pending = result
          controller.present(picker, animated: true)
        case "inbox":
          let url = try self.inbox()
          try self.activate(url)
          UserDefaults.standard.set(true, forKey: self.inboxKey)
          result(url.path)
        case "restore":
          if UserDefaults.standard.bool(forKey: self.inboxKey) {
            let url = try self.inbox()
            try self.activate(url)
            result(url.path)
          } else if let data = UserDefaults.standard.data(forKey: self.bookmarkKey) {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withoutUI],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            try self.activate(url)
            if stale { try self.save(url) }
            result(url.path)
          } else { result(nil) }
        case "release":
          self.release()
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        self.release()
        result(self.accessError())
      }
    }
  }

  private func inbox() throws -> URL {
    let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
    let url = documents.appendingPathComponent("CameraInbox", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
    return url
  }

  private func activate(_ url: URL) throws {
    release()
    let granted = url.startAccessingSecurityScopedResource()
    guard granted || url.standardizedFileURL.path.hasPrefix(NSHomeDirectory() + "/") else {
      throw NSError(domain: "PhotoFolderAccess", code: 1)
    }
    activeURL = url
    scoped = granted
    _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
  }

  private func save(_ url: URL) throws {
    let data = try url.bookmarkData(options: [.minimalBookmark],
                                    includingResourceValuesForKeys: nil, relativeTo: nil)
    UserDefaults.standard.set(data, forKey: bookmarkKey)
    UserDefaults.standard.set(false, forKey: inboxKey)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pending else { return }
    pending = nil
    guard let url = urls.first else { result(nil); return }
    do {
      try activate(url)
      try save(url)
      result(url.path)
    } catch {
      release()
      result(accessError())
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pending?(nil)
    pending = nil
  }

  private func accessError() -> FlutterError {
    FlutterError(code: "FOLDER_ACCESS", message: "目录授权失败，请重新选择已下载到本机的文件夹", details: nil)
  }

  private func release() {
    if scoped { activeURL?.stopAccessingSecurityScopedResource() }
    activeURL = nil
    scoped = false
  }

  deinit { release() }
}
