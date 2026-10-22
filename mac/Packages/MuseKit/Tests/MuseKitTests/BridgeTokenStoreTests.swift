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
