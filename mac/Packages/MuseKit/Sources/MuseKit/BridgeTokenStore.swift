import Foundation
import Security
import Synchronization

/// Where mMac keeps the MCP bridge's token. The backend holds it in memory only.
public protocol BridgeTokenStore: Sendable {
  func read() throws -> String?
  func write(_ token: String) throws
}

/// The token as a generic password in the login Keychain.
public struct KeychainTokenStore: BridgeTokenStore {
  public let service: String
  public let account: String

  public init(service: String, account: String) {
    self.service = service
    self.account = account
  }

  /// mMac's own item. Debug builds take `MMAC_KEYCHAIN_SERVICE`, so test runs never touch it.
  public static var app: KeychainTokenStore { app(environment: ProcessInfo.processInfo.environment) }

  static func app(environment: [String: String]) -> KeychainTokenStore {
    #if DEBUG
      if let service = environment["MMAC_KEYCHAIN_SERVICE"], !service.isEmpty {
        return KeychainTokenStore(service: service, account: "mcp-bridge")
      }
    #endif
    return KeychainTokenStore(service: "com.domalhambra.mmac.bridge-token", account: "mcp-bridge")
  }

  private var query: [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }

  public func read() throws -> String? {
    var query = self.query
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = result as? Data else { throw Self.error(status) }
    return String(decoding: data, as: UTF8.self)
  }

  public func write(_ token: String) throws {
    let data = Data(token.utf8)
    var status = update(data)
    if status == errSecItemNotFound {
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrLabel as String] = "mMac MCP bridge token"
      status = SecItemAdd(add as CFDictionary, nil)
      // Another writer added the item between the update and the add: update it once more.
      if status == errSecDuplicateItem { status = update(data) }
    }
    guard status == errSecSuccess else { throw Self.error(status) }
  }

  private func update(_ data: Data) -> OSStatus {
    SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
  }

  /// Removes the item. Tests use it to clean up.
  public func delete() throws {
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.error(status) }
  }

  private static func error(_ status: OSStatus) -> WorkspaceError {
    WorkspaceError(SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status).")
  }
}

/// The store mMac uses.
public enum BridgeTokenStores {
  /// The login Keychain, or in Debug builds with `MMAC_TOKEN_STORE=memory`, memory. UI tests set
  /// it so they never touch the Keychain: mMac is signed ad hoc, so every build has a new code
  /// identity, and the Keychain asks for the login password before it lets a new build read an
  /// item an older build made.
  public static var app: any BridgeTokenStore { app(environment: ProcessInfo.processInfo.environment) }

  static func app(environment: [String: String]) -> any BridgeTokenStore {
    #if DEBUG
      if environment["MMAC_TOKEN_STORE"] == "memory" { return MemoryTokenStore() }
    #endif
    return KeychainTokenStore.app(environment: environment)
  }
}

/// A token store in memory, for tests and previews.
public final class MemoryTokenStore: BridgeTokenStore {
  private let token: Mutex<String?>
  public init(_ token: String? = nil) { self.token = Mutex(token) }
  public func read() throws -> String? { token.withLock { $0 } }
  public func write(_ token: String) throws { self.token.withLock { $0 = token } }
}
