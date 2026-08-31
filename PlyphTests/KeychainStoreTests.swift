import XCTest
@testable import Plyph

final class KeychainStoreTests: XCTestCase {
    private let provider = "test-provider-\(UUID().uuidString)"

    override func tearDown() {
        try? KeychainStore.delete(provider: provider)
        super.tearDown()
    }

    func testWriteReadDelete() throws {
        do {
            try KeychainStore.write("  secret-key-123  ", provider: provider)
            let stored = try KeychainStore.read(provider: provider)
            XCTAssertEqual(stored, "secret-key-123")

            try KeychainStore.write("updated-key", provider: provider)
            XCTAssertEqual(try KeychainStore.read(provider: provider), "updated-key")

            try KeychainStore.delete(provider: provider)
            XCTAssertEqual(try KeychainStore.read(provider: provider), "")
        } catch let error as KeychainStore.KeychainError {
            // Skip when the environment has no usable keychain (e.g. restricted CI).
            if case .unavailable(let status) = error, status == -34018 {
                throw XCTSkip("Keychain unavailable in this environment")
            }
            throw error
        }
    }

    func testEmptyWriteRemovesItem() throws {
        do {
            try KeychainStore.write("some-key", provider: provider)
            XCTAssertNotEqual(try KeychainStore.read(provider: provider), "")
            // Writing an empty value deletes the item (GNOME parity).
            try KeychainStore.write("   ", provider: provider)
            XCTAssertEqual(try KeychainStore.read(provider: provider), "")
        } catch let error as KeychainStore.KeychainError {
            if case .unavailable(let status) = error, status == -34018 {
                throw XCTSkip("Keychain unavailable in this environment")
            }
            throw error
        }
    }
}
