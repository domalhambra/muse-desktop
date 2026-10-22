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
  public static var app: KeychainTokenStore {
    #if DEBUG
      if let service = ProcessInfo.processInfo.environment["MMAC_KEYCHAIN_SERVICE"], !service.isEmpty {
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
    let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if status == errSecItemNotFound {
      var add = query
      add[kSecValueData as String] = data
      add[kSecAttrLabel as String] = "mMac MCP bridge token"
      let added = SecItemAdd(add as CFDictionary, nil)
      guard added == errSecSuccess else { throw Self.error(added) }
    } else if status != errSecSuccess {
      throw Self.error(status)
    }
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

/// A token store in memory, for tests and previews.
public final class MemoryTokenStore: BridgeTokenStore {
  private let token: Mutex<String?>
  public init(_ token: String? = nil) { self.token = Mutex(token) }
  public func read() throws -> String? { token.withLock { $0 } }
  public func write(_ token: String) throws { self.token.withLock { $0 = token } }
}
