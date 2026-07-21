import ArgumentParser
import Foundation

@main
struct MTCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mt-cli",
        abstract: "Thin client for the Meeting Transcriber debug RPC server.",
        subcommands: [
            State.self, Healthz.self, Screenshot.self, UITree.self, UIPress.self,
            OpenSettings.self, CloseSettings.self, ConfirmBrowserConsent.self,
            SeedSpeaker.self, RenameSpeaker.self, DeleteSpeaker.self, MergeSpeakers.self,
        ],
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

struct OpenSettings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open-settings",
        abstract: "Open the app's Settings window.",
    )

    func run() async throws {
        let client = try RPCClient.loadDefault()
        _ = try await client.post("/action/openSettings", json: [:])
        print("ok")
    }
}

struct CloseSettings: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close-settings",
        abstract: "Close the Settings window if it is open.",
    )

    func run() async throws {
        let client = try RPCClient.loadDefault()
        let data = try await client.post("/action/closeSettings", json: [:])
        FileHandle.standardOutput.write(data)
    }
}

struct ConfirmBrowserConsent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "confirm-browser-consent",
        abstract: "Answer a parked browser-meeting consent prompt (issue #503). "
            + "Prints the server's {\"resolved\":bool} JSON; resolved:false means "
            + "no prompt was waiting yet, so poll until true.",
    )

    @Flag(inversion: .prefixedNo, help: "Grant recording (default) or --no-granted to decline.")
    var granted = true

    func run() async throws {
        let client = try RPCClient.loadDefault()
        let data = try await client.post("/action/confirmBrowserConsent", json: ["granted": granted])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

/// POST a JSON action to the RPC server and write the response body + newline
/// to stdout. Shared by every action subcommand that returns the server's
/// outcome JSON unchanged.
private func postAction(_ path: String, _ payload: [String: String]) async throws {
    let client = try RPCClient.loadDefault()
    let data = try await client.post(path, json: payload)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

struct SeedSpeaker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seed-speaker",
        abstract: "Insert a synthetic speaker with a random embedding (testing only).",
    )

    @Argument(help: "Name of the speaker to seed.")
    var name: String

    func run() async throws {
        try await postAction("/action/seedSpeaker", ["name": name])
    }
}

struct RenameSpeaker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename-speaker",
        abstract: "Rename a speaker in the persisted DB. Merges if the target name exists.",
    )

    @Argument(help: "Current name of the speaker.")
    var from: String

    @Argument(help: "New name. If a speaker already has this name, the two are merged.")
    var to: String

    func run() async throws {
        try await postAction("/action/renameSpeaker", ["from": from, "to": to])
    }
}

struct DeleteSpeaker: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-speaker",
        abstract: "Remove a speaker from the persisted DB.",
    )

    @Argument(help: "Name of the speaker to delete.")
    var name: String

    func run() async throws {
        try await postAction("/action/deleteSpeaker", ["name": name])
    }
}

struct MergeSpeakers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge-speakers",
        abstract: "Merge one speaker into another. Embeddings, centroid and counts are combined.",
    )

    @Argument(help: "Source speaker — its data is merged into the target and the source is removed.")
    var from: String

    @Argument(help: "Target speaker — receives the source's embeddings and centroid.")
    var into: String

    func run() async throws {
        try await postAction("/action/mergeSpeakers", ["from": from, "into": into])
    }
}

struct UITree: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui-tree",
        abstract: "Print the accessibility tree of an allowed app window as JSON. "
            + "Assert on UI structure (a section exists, a control is enabled) "
            + "instead of eyeballing a screenshot.",
    )

    @Option(name: .long, help: "Window identifier to introspect. Defaults to settings.")
    var window: String = "settings"

    func run() async throws {
        let client = try RPCClient.loadDefault()
        let data = try await client.get("/ui/tree?window=\(window)")
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

struct UIPress: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ui-press",
        abstract: "Press a control (by accessibility identifier) in an allowed app window. "
            + "Drives a real in-process UI action — assert the effect via `state`, "
            + "not the returned `pressed` flag.",
    )

    @Argument(help: "Accessibility identifier of the control to press.")
    var identifier: String

    @Option(name: .long, help: "Window identifier the control lives in. Defaults to settings.")
    var window: String = "settings"

    func run() async throws {
        try await postAction("/ui/press", ["window": window, "identifier": identifier])
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
        let data = try await client.get("/screenshot", timeout: RPCClient.screenshotTimeoutSeconds)
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(data.count) bytes to \(path)")
    }
}
