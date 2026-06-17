#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    final class IdempotencyStoreTests: XCTestCase {
        func testLookupMissingKeyReturnsNil() {
            let store = IdempotencyStore()
            XCTAssertNil(store.lookup("absent"))
        }

        func testRememberThenLookupReturnsIDs() {
            var store = IdempotencyStore()
            let ids = [UUID(), UUID()]
            store.remember("k", ids)
            XCTAssertEqual(store.lookup("k"), ids)
        }

        func testRememberSameKeyUpdatesInPlaceWithoutSelfEviction() {
            // capacity 1: a same-key re-remember must update in place, not append
            // a second slot (which would push count past capacity and evict "k").
            var store = IdempotencyStore(capacity: 1)
            let first = [UUID()]
            let second = [UUID()]
            store.remember("k", first)
            store.remember("k", second)
            XCTAssertEqual(store.lookup("k"), second, "same-key remember updates in place, no self-eviction")
        }

        func testEvictsOldestKeyBeyondCapacity() {
            var store = IdempotencyStore(capacity: 2)
            store.remember("a", [UUID()])
            store.remember("b", [UUID()])
            store.remember("c", [UUID()]) // evicts "a" (oldest)
            XCTAssertNil(store.lookup("a"), "oldest key evicted past capacity")
            XCTAssertNotNil(store.lookup("b"))
            XCTAssertNotNil(store.lookup("c"))
        }
    }
#endif
