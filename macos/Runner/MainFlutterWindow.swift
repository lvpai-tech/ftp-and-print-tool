import Cocoa
import Darwin
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
  private let credentials: WorkstationKeychain

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "ai.lvpai.ftp/login-keychain", binaryMessenger: messenger)
    credentials = WorkstationKeychain(service: Bundle.main.bundleIdentifier ?? "ai.lvpai.lvpaiFtpClient")
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
          try self.credentials.write(key: key, value: value)
          result(nil)
        case "read":
          guard let args = call.arguments as? [String: String], let key = args["key"] else {
            result(FlutterError(code: "KEYCHAIN", message: "read 需要 key", details: nil))
            return
          }
          result(try self.credentials.read(key: key))
        case "delete":
          guard let args = call.arguments as? [String: String], let key = args["key"] else {
            result(FlutterError(code: "KEYCHAIN", message: "delete 需要 key", details: nil))
            return
          }
          try self.credentials.delete(key: key)
          result(nil)
        case "containsKey":
          guard let args = call.arguments as? [String: String], let key = args["key"] else {
            result(FlutterError(code: "KEYCHAIN", message: "containsKey 需要 key", details: nil))
            return
          }
          result(try self.credentials.containsKey(key: key))
        case "readAll", "readLegacy":
          let selection = call.arguments as? [String: Any]
          let legacy = call.method == "readLegacy"
          let prefixes = selection?["prefixes"] as? [String]
          if (legacy || call.arguments != nil) && prefixes == nil {
            result(FlutterError(code: "KEYCHAIN", message: "钥匙串读取范围无效", details: nil))
            return
          }
          result(try self.credentials.readAll(
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
}

private final class WorkstationKeychain {
  private let service: String
  private var cached: (revision: Data, values: [String: String])?

  init(service: String) {
    self.service = service
  }

  func write(key: String, value: String) throws {
    try withLock {
      var values = try load()
      values[key] = value
      try save(values)
    }
  }

  func read(key: String) throws -> String? {
    try withLock {
      var values = try load()
      if let value = values[key] { return value }
      guard let previous = try readIndividual(key: key, legacy: false) else { return nil }
      values[key] = previous
      try save(values)
      return previous
    }
  }

  func delete(key: String) throws {
    try withLock {
      var values = try load()
      // Remove any old copy first so a subsequent read cannot migrate it back.
      let status = SecItemDelete(baseQuery(account: key) as CFDictionary)
      if status != errSecItemNotFound { try check(status) }
      if values.removeValue(forKey: key) != nil { try save(values) }
    }
  }

  func containsKey(key: String) throws -> Bool {
    try withLock {
      if try load()[key] != nil { return true }
      return try attributes(for: baseQuery(account: key)) != nil
    }
  }

  func readAll(prefixes: [String]?, keys: Set<String>, legacy: Bool) throws -> [String: String] {
    func selected(_ key: String) -> Bool {
      guard let prefixes = prefixes else { return true }
      return keys.contains(key) || prefixes.contains(where: { key.hasPrefix($0) })
    }

    return try withLock {
      var values = legacy ? [:] : try load()
      let accounts = try individualAccounts(legacy: legacy)
      var migrated = false
      for account in accounts where selected(account) && values[account] == nil {
        if let value = try readIndividual(key: account, legacy: legacy) {
          values[account] = value
          migrated = true
        }
      }
      if migrated && !legacy { try save(values) }
      return values.filter { selected($0.key) }
    }
  }

  private var storeQuery: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "\(service).workstation-credentials.v1",
      kSecAttrAccount as String: "credentials",
    ]
  }

  private func load() throws -> [String: String] {
    let query = storeQuery
    guard let attributes = try attributes(for: query) else {
      cached = nil
      return [:]
    }
    guard let revision = attributes[kSecAttrGeneric as String] as? Data else {
      throw invalidData()
    }
    if let cached = cached, cached.revision == revision { return cached.values }
    guard let data = try readData(query),
          let values = try? JSONDecoder().decode([String: String].self, from: data) else {
      throw invalidData()
    }
    cached = (revision, values)
    return values
  }

  private func save(_ values: [String: String]) throws {
    let query = storeQuery
    let revision = Data(UUID().uuidString.utf8)
    let attributes: [String: Any] = [
      kSecValueData as String: try JSONEncoder().encode(values),
      kSecAttrGeneric as String: revision,
      kSecAttrLabel as String: "帧集快拍工作台凭据",
    ]
    if let previous = cached {
      var matchingRevision = query
      matchingRevision[kSecAttrGeneric as String] = previous.revision
      try check(SecItemUpdate(matchingRevision as CFDictionary, attributes as CFDictionary))
    } else {
      let item = query.merging(attributes) { _, data in data }
      try check(SecItemAdd(item as CFDictionary, nil))
    }
    cached = (revision, values)
  }

  private func readIndividual(key: String, legacy: Bool) throws -> String? {
    guard let data = try readData(baseQuery(account: key, legacy: legacy)) else { return nil }
    guard let value = String(data: data, encoding: .utf8) else { throw invalidData() }
    return value
  }

  private func readData(_ query: [String: Any]) throws -> Data? {
    var query = query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    guard let item = try matching(query) else { return nil }
    guard let data = item as? Data else { throw invalidData() }
    return data
  }

  private func attributes(for query: [String: Any]) throws -> [String: Any]? {
    var query = query
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    guard let item = try matching(query) else { return nil }
    guard let attributes = item as? [String: Any] else { throw invalidData() }
    return attributes
  }

  private func individualAccounts(legacy: Bool) throws -> [String] {
    var query = baseQuery(account: nil, legacy: legacy)
    // Security rejects kSecMatchLimitAll with kSecReturnData for passwords.
    query[kSecReturnAttributes as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitAll
    guard let item = try matching(query) else { return [] }
    guard let rows = item as? [[String: Any]] else { throw invalidData() }
    return rows.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
  }

  private func matching(_ query: [String: Any]) throws -> CFTypeRef? {
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound { return nil }
    try check(status)
    guard let item = item else { throw invalidData() }
    return item
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

  private func invalidData() -> KeychainStoreError {
    KeychainStoreError(status: errSecDecode, message: "钥匙串返回了无法解析的工作台凭据")
  }

  private func withLock<T>(_ action: () throws -> T) throws -> T {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(service).workstation-credentials.lock").path
    let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw lockError() }
    defer { close(fd) }
    while flock(fd, LOCK_EX) != 0 {
      if errno != EINTR { throw lockError() }
    }
    return try action()
  }

  private func lockError() -> KeychainStoreError {
    KeychainStoreError(status: errSecIO, message: "无法锁定本机工作台钥匙串，请重试")
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
        case "isUnsandboxedDistribution":
          guard self.unsandboxed, let task = SecTaskCreateFromSelf(nil) else {
            result(false); return
          }
          let sandbox = SecTaskCopyValueForEntitlement(
            task, "com.apple.security.app-sandbox" as CFString, nil
          ) as? Bool
          result(sandbox != true)
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
