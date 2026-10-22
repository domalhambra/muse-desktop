import Foundation
import Testing
@testable import MuseKit

// A random service, never mMac's own item, and deleted even when an expectation fails.
@Test func theKeychainKeepsAndReplacesTheToken() throws {
  let store = KeychainTokenStore(service: "com.domalhambra.mmac.test.\(UUID().uuidString)", account: "mcp-bridge")
  defer { try? store.delete() }
  #expect(try store.read() == nil)
  try store.write("first")
  #expect(try store.read() == "first")
  try store.write("second")
  #expect(try store.read() == "second")
  try store.delete()
  #expect(try store.read() == nil)
}

@Test func theMemoryStoreKeepsTheToken() throws {
  let store = MemoryTokenStore()
  #expect(try store.read() == nil)
  try store.write("t")
  #expect(try store.read() == "t")
  #expect(try MemoryTokenStore("given").read() == "given")
}

// These only build the stores; none reads or writes the Keychain.
@Test func theAppItemIsMMacsOwnUnlessATestServiceIsSet() {
  let own = KeychainTokenStore.app(environment: [:])
  #expect(own.service == "com.domalhambra.mmac.bridge-token")
  #expect(own.account == "mcp-bridge")
  #expect(KeychainTokenStore.app(environment: ["MMAC_KEYCHAIN_SERVICE": ""]).service == own.service)
  let test = KeychainTokenStore.app(environment: ["MMAC_KEYCHAIN_SERVICE": "com.domalhambra.mmac.test"])
  #expect(test.service == "com.domalhambra.mmac.test")
  #expect(test.account == "mcp-bridge")
}

@Test func debugBuildsCanKeepTheTokenInMemory() {
  #expect(BridgeTokenStores.app(environment: ["MMAC_TOKEN_STORE": "memory"]) is MemoryTokenStore)
  let keychain = BridgeTokenStores.app(environment: ["MMAC_KEYCHAIN_SERVICE": "com.domalhambra.mmac.test"])
  #expect((keychain as? KeychainTokenStore)?.service == "com.domalhambra.mmac.test")
  #expect((BridgeTokenStores.app(environment: [:]) as? KeychainTokenStore)?.service == "com.domalhambra.mmac.bridge-token")
}
