import Cocoa
import FlutterMacOS
import Security
import Sparkle

class MainFlutterWindow: NSWindow {
  private var folderAccess: PhotoFolderAccess?
  private var desktopUpdater: DesktopUpdater?
  private var loginKeychain: LoginKeychainStore?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    folderAccess = PhotoFolderAccess(messenger: flutterViewController.engine.binaryMessenger)
    desktopUpdater = DesktopUpdater(messenger: flutterViewController.engine.binaryMessenger)
    loginKeychain = LoginKeychainStore(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}

/// Login Keychain access for workstation credentials on macOS.
private final class LoginKeychainStore {
  private let channel: FlutterMethodChannel
  private let service: String

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ai.lvpai.ftp/login-keychain", binaryMessenger: messenger)
    service = Bundle.main.bundleIdentifier ?? "ai.lvpai.lvpaiFtpClient"
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      do {
        switch call.method {
        case "write":
          guard let args = call.arguments as? [String: String],
                let key = args["key"],
                let value = args["value"] else {
            result(FlutterError(code: "KEYCHAIN", message: "write 需要 key 和 value", details: nil))
            return
          }
          try self.write(key: key, value: value)
          result(nil)
        case "read":
          guard let args = call.arguments as? [String: String], let key = args["key"] else {
            result(FlutterError(code: "KEYCHAIN", message: "read 需要 key", details: nil))
            return
          }
          result(try self.read(key: key))
        case "delete":
          guard let args = call.arguments as? [String: String], let key = args["key"] else {
            result(FlutterError(code: "KEYCHAIN", message: "delete 需要 key", details: nil))
            return
          }
          try self.delete(key: key)
          result(nil)
        case "containsKey":
          guard let args = call.arguments as? [String: String], let key = args["key"] else {
            result(FlutterError(code: "KEYCHAIN", message: "containsKey 需要 key", details: nil))
            return
          }
          result(try self.containsKey(key: key))
        case "readAll", "readLegacy":
          let selection = call.arguments as? [String: Any]
          let legacy = call.method == "readLegacy"
          let prefixes = selection?["prefixes"] as? [String]
          if (legacy || call.arguments != nil) && prefixes == nil {
            result(FlutterError(code: "KEYCHAIN", message: "钥匙串读取范围无效", details: nil))
            return
          }
          result(try self.readAll(
            prefixes: prefixes,
            keys: Set(selection?["keys"] as? [String] ?? []),
            legacy: legacy
          ))
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch let error as KeychainStoreError {
        NSLog("Login Keychain %@ failed: %d", call.method, error.status)
        result(FlutterError(code: "KEYCHAIN", message: error.message, details: error.status))
      } catch {
        result(FlutterError(code: "KEYCHAIN", message: "\(error)", details: nil))
      }
    }
  }

  private func write(key: String, value: String) throws {
    let query = baseQuery(account: key)
    let attributes = [kSecValueData as String: Data(value.utf8)]
    let item = query.merging(attributes) { _, data in data }
    let status = SecItemAdd(item as CFDictionary, nil)
    if status == errSecDuplicateItem {
      try check(SecItemUpdate(query as CFDictionary, attributes as CFDictionary))
    } else {
      try check(status)
    }
  }

  private func read(key: String, legacy: Bool = false) throws -> String? {
    var query = baseQuery(account: key, legacy: legacy)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    try check(status)
    guard let data = item as? Data else {
      throw KeychainStoreError(status: errSecParam, message: "钥匙串返回了无法解析的数据")
    }
    return String(data: data, encoding: .utf8)
  }

  private func delete(key: String) throws {
    let status = SecItemDelete(baseQuery(account: key) as CFDictionary)
    if status == errSecItemNotFound { return }
    try check(status)
  }

  private func containsKey(key: String) throws -> Bool {
    var query = baseQuery(account: key)
    query[kSecReturnData as String] = false
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let status = SecItemCopyMatching(query as CFDictionary, nil)
    if status == errSecSuccess { return true }
    if status == errSecItemNotFound { return false }
    throw KeychainStoreError(status: status)
  }

  private func readAll(prefixes: [String]?, keys: Set<String>, legacy: Bool) throws -> [String: String] {
    var query = baseQuery(account: nil, legacy: legacy)
    // Security rejects kSecMatchLimitAll with kSecReturnData for passwords.
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return [:] }
    try check(status)
    guard let rows = item as? [[String: Any]] else { return [:] }
    var values: [String: String] = [:]
    for row in rows {
      guard let account = row[kSecAttrAccount as String] as? String else { continue }
      if let prefixes = prefixes, !keys.contains(account),
         !prefixes.contains(where: { account.hasPrefix($0) }) { continue }
      values[account] = try read(key: account, legacy: legacy)
    }
    return values
  }

  private func baseQuery(account: String?, legacy: Bool = false) -> [String: Any] {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: legacy ? "flutter_secure_storage_service" : service,
    ]
    if legacy {
      query[kSecUseDataProtectionKeychain as String] = true
      query[kSecAttrSynchronizable as String] = false
    }
    if let account = account {
      query[kSecAttrAccount as String] = account
    }
    return query
  }

  private func check(_ status: OSStatus) throws {
    if status == errSecSuccess { return }
    throw KeychainStoreError(status: status)
  }
}

private struct KeychainStoreError: Error {
  let status: OSStatus
  let message: String

  init(status: OSStatus, message: String? = nil) {
    self.status = status
    if let message = message {
      self.message = message
    } else if let sys = SecCopyErrorMessageString(status, nil) as String? {
      self.message = sys
    } else {
      self.message = "钥匙串错误 \(status)"
    }
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

/// 使用 Finder 选择的目录，沙箱构建保留其安全作用域。
private final class PhotoFolderAccess {
  private let channel: FlutterMethodChannel
  private let bookmarkKey = "ftp.watch.bookmark.v1"
  private var activeURL: URL?
  private var scopes: [String: URL] = [:]
  private let unsandboxed = Bundle.main.object(forInfoDictionaryKey: "LvpaiUnsandboxedDistribution") as? Bool == true
  private let localBookmarkPrefix = "local:"

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ai.lvpai.ftp/folder-access", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      do {
        switch call.method {
        case "choose", "chooseScoped":
          let panel = NSOpenPanel()
          panel.title = "选择相机照片接收文件夹"
          panel.canChooseDirectories = true
          panel.canChooseFiles = false
          panel.allowsMultipleSelection = false
          guard panel.runModal() == .OK, let url = panel.url else { result(nil); return }
          if self.unsandboxed && call.method == "chooseScoped" {
            try self.checkReadable(url)
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            result(["path": url.path, "bookmark": self.localBookmarkPrefix + data.base64EncodedString()])
            return
          }
          if call.method == "chooseScoped" {
            let granted = url.startAccessingSecurityScopedResource()
            defer { if granted { url.stopAccessingSecurityScopedResource() } }
            let data = try url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil, relativeTo: nil)
            result(["path": url.path, "bookmark": data.base64EncodedString()])
          } else {
            try self.activate(url)
            try self.save(url)
            result(url.path)
          }
        case "acquireScoped":
          guard let args = call.arguments as? [String: String],
                let scope = args["scope"] else {
            result(FlutterMethodNotImplemented); return
          }
          if self.unsandboxed {
            result(try self.restoreLocalFolder(args)?.path)
            return
          }
          let data: Data?
          if let bookmark = args["bookmark"] {
            data = Data(base64Encoded: bookmark)
          } else {
            data = UserDefaults.standard.data(forKey: self.bookmarkKey)
          }
          guard let data = data else { result(nil); return }
          var stale = false
          let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                            relativeTo: nil, bookmarkDataIsStale: &stale)
          self.release(scope)
          guard url.startAccessingSecurityScopedResource() else {
            throw NSError(domain: "PhotoFolderAccess", code: 1)
          }
          self.scopes[scope] = url
          result(url.path)
        case "releaseScoped":
          if let args = call.arguments as? [String: String], let scope = args["scope"] {
            self.release(scope)
          }
          result(nil)
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
        if call.method == "choose" || call.method == "restore" { self.release() }
        result(FlutterError(code: "FOLDER_ACCESS", message: "目录授权失败，请重新选择本机文件夹", details: nil))
      }
    }
  }

  private func restoreLocalFolder(_ args: [String: String]) throws -> URL? {
    let bookmark = args["bookmark"]
    let url: URL
    if let bookmark = bookmark, bookmark.hasPrefix(localBookmarkPrefix) {
      guard let data = Data(base64Encoded: String(bookmark.dropFirst(localBookmarkPrefix.count))) else {
        throw CocoaError(.fileReadCorruptFile)
      }
      var stale = false
      url = try URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                    relativeTo: nil, bookmarkDataIsStale: &stale)
    } else {
      // 旧签名的安全作用域书签可能无法解析。对已有设置重新验证实际路径。
      guard bookmark != nil || UserDefaults.standard.data(forKey: bookmarkKey) != nil,
            let path = args["path"], path.hasPrefix("/") else { return nil }
      url = URL(fileURLWithPath: path, isDirectory: true)
    }
    try checkReadable(url)
    return url
  }

  private func checkReadable(_ url: URL) throws {
    _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
  }

  private func activate(_ url: URL) throws {
    release()
    guard url.startAccessingSecurityScopedResource() else {
      throw NSError(domain: "PhotoFolderAccess", code: 1)
    }
    activeURL = url
    try checkReadable(url)
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

  private func release(_ scope: String) {
    scopes.removeValue(forKey: scope)?.stopAccessingSecurityScopedResource()
  }

  deinit {
    release()
    for url in scopes.values { url.stopAccessingSecurityScopedResource() }
  }
}
