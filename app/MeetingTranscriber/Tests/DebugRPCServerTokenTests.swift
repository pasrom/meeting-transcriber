#if !APPSTORE
    @testable import MeetingTranscriber
    import XCTest

    /// The bearer token: how it is made, how it is written, and that a server
    /// publishes it only once it actually holds the port.
    final class DebugRPCServerTokenTests: XCTestCase {
        func testMakeTokenIs64HexAndDistinctAcrossCalls() {
            let a = DebugRPCServer.makeToken()
            let b = DebugRPCServer.makeToken()
            XCTAssertEqual(a.count, 64)
            XCTAssertTrue(a.allSatisfy(\.isHexDigit))
            XCTAssertNotEqual(a, b, "two tokens in a row must differ")
        }

        func testWriteTokenReplacesTheFileWithMode600() throws {
            let url = makeTempFile(suffix: "-rpc-token")
            // An earlier token under a looser mode: the write must leave neither.
            FileManager.default.createFile(
                atPath: url.path, contents: Data("seed-token-1234".utf8),
                attributes: [.posixPermissions: 0o644],
            )

            XCTAssertTrue(DebugRPCServer.writeToken("fresh", to: url))

            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "fresh")
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attrs[.posixPermissions] as? Int) ?? -1, 0o600)
            let leftovers = try FileManager.default
                .contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
                .filter { $0.hasPrefix(".\(url.lastPathComponent).") }
            XCTAssertEqual(leftovers, [], "the temporary file must be renamed away, not left behind")
        }

        /// The production server publishes to the data-folder file, which is
        /// where `mt-cli` reads it. Read from the source and compared, never
        /// run: starting it would replace the user's own token file. That the
        /// file passed in reaches the server is pinned by `AppStateTests`.
        func testTheProductionServerPublishesToTheDataFolderFile() throws {
            XCTAssertEqual(DebugRPCServer.tokenFileURL, AppPaths.dataDir.appendingPathComponent(".rpc-token"))
            let appState = try appSourceText("AppState.swift")
            XCTAssertTrue(appState.contains("tokenFile: DebugRPCServer.tokenFileURL"))
        }

        /// A started server publishes its own token, so clients reading the
        /// file can reach it.
        @MainActor
        func testAServerWritesItsTokenOnceItListens() async throws {
            let url = makeTempFile(suffix: "-rpc-token")
            let server = DebugRPCServer(port: 0, token: "this-server", tokenFile: url) { .empty }
            server.start()
            defer { server.stop() }
            await waitFor(server.boundPort != nil, timeout: regressionCeiling)
            XCTAssertNotNil(server.boundPort, "the listener never came up")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "this-server")
        }

        /// A server whose token cannot be written stops instead of listening
        /// on a token no client can read.
        @MainActor
        func testAServerThatCannotWriteItsTokenStops() async throws {
            // A port known to be bindable: take one from the OS, then free it.
            let probe = DebugRPCServer(port: 0, token: "probe") { .empty }
            probe.start()
            await waitFor(probe.boundPort != nil, timeout: regressionCeiling)
            let port = try XCTUnwrap(probe.boundPort, "the probe never came up")
            probe.stop()

            // The token file's parent is a regular file, so no write can succeed.
            let blocker = makeTempFile(suffix: "-not-a-folder")
            XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data()))
            let url = blocker.appendingPathComponent(".rpc-token")
            let server = DebugRPCServer(port: port, token: "unwritten", tokenFile: url) { .empty }
            server.start()
            defer { server.stop() }
            // Same settle time as the bind-failure test below.
            try await Task.sleep(for: .seconds(1))
            XCTAssertNil(server.boundPort, "a server without a published token must not report itself listening")

            // Not reporting a port is not enough: the listener must be gone, so
            // the port is free for the next server.
            let next = DebugRPCServer(port: port, token: "next") { .empty }
            next.start()
            defer { next.stop() }
            await waitFor(next.boundPort != nil, timeout: regressionCeiling)
            XCTAssertEqual(next.boundPort, port, "the failed server still holds the port")
        }

        /// A server that cannot bind must not touch the file: the port is held
        /// by another instance sharing the data folder (a second build, or a
        /// second `AppState`), and its clients would otherwise be handed a token
        /// that the server actually listening never accepts.
        @MainActor
        func testAServerThatCannotBindLeavesTheTokenFileAlone() async throws {
            let holder = DebugRPCServer(port: 0, token: "holder") { .empty }
            holder.start()
            defer { holder.stop() }
            await waitFor(holder.boundPort != nil, timeout: regressionCeiling)
            let port = try XCTUnwrap(holder.boundPort, "the holder never came up")

            let url = makeTempFile(suffix: "-rpc-token")
            XCTAssertTrue(DebugRPCServer.writeToken("holder", to: url))
            let loser = DebugRPCServer(port: port, token: "loser", tokenFile: url) { .empty }
            loser.start()
            defer { loser.stop() }
            // A fixed wait, not a measured bound: there is no event for "the
            // bind failed" to wait on, and the loser's own boundPort check below
            // is what shows the bind did not succeed.
            try await Task.sleep(for: .seconds(1))

            XCTAssertNil(loser.boundPort, "the second bind was expected to fail; if it can succeed this test proves nothing")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "holder")
        }
    }
#endif
