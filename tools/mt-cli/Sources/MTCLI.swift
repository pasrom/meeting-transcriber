import ArgumentParser
import Foundation

@main
struct MTCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mt-cli",
        abstract: "Thin client for the Meeting Transcriber debug RPC server.",
        subcommands: [State.self, Healthz.self, Screenshot.self],
    )
}

struct State: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the current pipeline + speaker DB state as JSON.",
    )

    func run() async throws {
        let client = try RPCClient.loadDefault()
        let data = try await client.get("/state")
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

struct Healthz: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Probe the RPC server. Exits 0 when reachable, non-zero otherwise.",
    )

    func run() async throws {
        let client = try RPCClient.loadDefault()
        _ = try await client.get("/healthz")
        print("ok")
    }
}

struct Screenshot: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save a PNG of the app's frontmost window.",
    )

    @Argument(help: "Output PNG path. Defaults to ./screenshot.png.")
    var path: String = "screenshot.png"

    func run() async throws {
        let client = try RPCClient.loadDefault()
        let data = try await client.get("/screenshot")
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(data.count) bytes to \(path)")
    }
}
