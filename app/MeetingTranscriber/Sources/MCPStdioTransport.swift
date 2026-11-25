#if !APPSTORE
    import Foundation
    #if canImport(Darwin)
        import Darwin
    #else
        import Glibc
    #endif

    actor MCPStdioTransport: MCPContextTransport {
        private struct Pending {
            let id: Int
            let continuation: CheckedContinuation<MCPWireReply, any Error>
            let timeout: Task<Void, Never>
        }

        private let source: MCPSource
        private let environment: [String: String]
        private var process: Process?
        private var input: FileHandle?
        private var output: FileHandle?
        private var reader: Task<Void, Never>?
        private var pending: Pending?
        private var bytes = Data()
        private var received = 0
        private var changed = false
        private var closed = false

        init(source: MCPSource, environment: [String: String]) {
            self.source = source
            self.environment = environment
        }

        func exchange(_ message: MCPWireMessage, seconds: TimeInterval) async throws -> MCPWireReply {
            try Task.checkCancellation()
            guard !closed, pending == nil else { throw ContextFailure.connection }
            guard message.method != "tools/call" || !changed else { throw ContextFailure.revoked }
            if process == nil { try start() }
            received = bytes.count
            var line = message.data
            line.append(10)
            guard let id = message.id else {
                try write(line)
                return MCPWireReply(result: .object([:]))
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let timeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                        await self?.stop(reason: ContextFailure.timeout)
                    }
                    pending = Pending(id: id, continuation: continuation, timeout: timeout)
                    do { try write(line) } catch { stop(reason: error) }
                }
            } onCancel: {
                Task { await self.stop(reason: CancellationError()) }
            }
        }

        func setProtocolVersion(_: String) {}

        func takeToolListChange() -> Bool {
            defer { changed = false }
            return changed
        }

        func close(endSession _: Bool) {
            stop(reason: ContextFailure.connection)
        }

        private func start() throws {
            guard source.location.hasPrefix("/"), !source.location.utf8.contains(0),
                  source.arguments.count <= 64, source.arguments.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 4096 }),
                  environment.count <= 32, environment.allSatisfy({ key, value in
                      !key.isEmpty && !key.contains("=") && !key.utf8.contains(0)
                          && !value.utf8.contains(0) && value.utf8.count <= 8192
                  }) else { throw ContextFailure.invalidEndpoint }

            let pair = try Self.inputSocketPair()
            let pipe = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: source.location)
            process.arguments = source.arguments
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
                .merging(environment) { _, configured in configured }
            process.standardInput = pair.child
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { throw ContextFailure.connection }
            try? pair.child.close()

            self.process = process
            input = pair.host
            let output = pipe.fileHandleForReading
            self.output = output
            let (stream, replies) = AsyncThrowingStream<Data, any Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
            output.readabilityHandler = { handle in
                var buffer = [UInt8](repeating: 0, count: 8192)
                let count = read(handle.fileDescriptor, &buffer, buffer.count)
                if count <= 0 {
                    handle.readabilityHandler = nil
                    replies.finish()
                } else if case .dropped = replies.yield(Data(buffer.prefix(count))) {
                    handle.readabilityHandler = nil
                    replies.finish(throwing: ContextFailure.limit)
                }
            }
            reader = Task { [weak self] in
                do {
                    for try await data in stream {
                        guard !Task.isCancelled else { return }
                        await self?.receive(data)
                    }
                    await self?.stop(reason: ContextFailure.connection)
                } catch {
                    await self?.stop(reason: error)
                }
            }
        }

        private static func inputSocketPair() throws -> (host: FileHandle, child: FileHandle) {
            var sockets = [Int32](repeating: 0, count: 2)
            #if canImport(Darwin)
                let socketType = SOCK_STREAM
            #else
                let socketType = Int32(SOCK_STREAM.rawValue)
            #endif
            guard socketpair(AF_UNIX, socketType, 0, &sockets) == 0 else { throw ContextFailure.connection }
            let host = FileHandle(fileDescriptor: sockets[0], closeOnDealloc: true)
            let child = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
            guard fcntl(host.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0,
                  fcntl(child.fileDescriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw ContextFailure.connection }
            #if canImport(Darwin)
                var enabled: Int32 = 1
                guard setsockopt(host.fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
                else { throw ContextFailure.connection }
            #endif
            return (host, child)
        }

        private func write(_ line: Data) throws {
            guard let input else { throw ContextFailure.connection }
            #if canImport(Darwin)
                let flags = MSG_DONTWAIT
            #else
                let flags = Int32(MSG_DONTWAIT | MSG_NOSIGNAL)
            #endif
            let count = line.withUnsafeBytes { send(input.fileDescriptor, $0.baseAddress, $0.count, flags) }
            guard count == line.count else { throw ContextFailure.connection }
        }

        private func receive(_ data: Data) {
            guard !closed else { return }
            received += data.count
            guard received <= ContextLimits.wire else { stop(reason: ContextFailure.limit); return }
            bytes.append(data)
            do {
                while let newline = bytes.firstIndex(of: 10) {
                    let line = bytes.prefix(upTo: newline)
                    bytes.removeSubrange(...newline)
                    let message = try MCPWireMessage.decode(line)
                    if MCPWireMessage.listChanged(message) { changed = true }
                    if let pending, let result = try MCPWireMessage.response(message, id: pending.id) {
                        self.pending = nil
                        pending.timeout.cancel()
                        pending.continuation.resume(returning: MCPWireReply(result: result))
                    }
                }
            } catch {
                stop(reason: error)
            }
        }

        private func stop(reason: any Error) {
            guard !closed else { return }
            closed = true
            pending?.timeout.cancel()
            pending?.continuation.resume(throwing: reason)
            pending = nil
            reader?.cancel()
            reader = nil
            output?.readabilityHandler = nil
            try? input?.close()
            input = nil
            if let process, process.isRunning {
                let child = process.processIdentifier
                BoundedProcess.signalGroup(of: child, SIGTERM)
                Task.detached {
                    try? await Task.sleep(for: .seconds(1))
                    if process.isRunning { BoundedProcess.signalGroup(of: child, SIGKILL) }
                }
            }
            process = nil
        }
    }
#endif
