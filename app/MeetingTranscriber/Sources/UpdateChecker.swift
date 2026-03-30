import Foundation
import Observation

// MARK: - Models

struct ReleaseInfo: Equatable {
    let tagName: String
    let name: String
    let prerelease: Bool
    let htmlURL: URL
    let dmgURL: URL?

    var version: (Int, Int, Int)? {
        UpdateChecker.parseVersion(tagName)
    }
}

// MARK: - Protocol

protocol UpdateProviding: Sendable {
    func latestRelease() async throws -> ReleaseInfo
    func allReleases() async throws -> [ReleaseInfo]
}

// MARK: - GitHub Release Provider

struct GitHubReleaseProvider: UpdateProviding {
    private let owner = "pasrom"
    private let repo = "meeting-transcriber"

    private struct GitHubRelease: Codable {
        let tagName: String
        let name: String?
        let prerelease: Bool
        let htmlURL: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case prerelease
            case htmlURL = "html_url"
            case assets
        }
    }

    private struct GitHubAsset: Codable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    func latestRelease() async throws -> ReleaseInfo {
        let release: GitHubRelease = try await fetchJSON(path: "releases/latest")
        return mapRelease(release)
    }

    func allReleases() async throws -> [ReleaseInfo] {
        let releases: [GitHubRelease] = try await fetchJSON(path: "releases")
        return releases.map { mapRelease($0) }
    }

    private func fetchJSON<T: Decodable>(path: String) async throws -> T {
        // swiftlint:disable:next force_unwrapping
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/\(path)")!
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateCheckerError.networkError(
                "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)",
            )
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func mapRelease(_ release: GitHubRelease) -> ReleaseInfo {
        let dmgAsset = release.assets.first { $0.name.hasSuffix(".dmg") }
        return ReleaseInfo(
            tagName: release.tagName,
            name: release.name ?? release.tagName,
            prerelease: release.prerelease,
            // swiftlint:disable:next force_unwrapping
            htmlURL: URL(string: release.htmlURL)!,
            dmgURL: dmgAsset.flatMap { URL(string: $0.browserDownloadURL) },
        )
    }
}

// MARK: - Errors

enum UpdateCheckerError: LocalizedError {
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case let .networkError(detail): "Network error: \(detail)"
        }
    }
}

// MARK: - UpdateChecker

@MainActor
@Observable
final class UpdateChecker {
    var availableUpdate: ReleaseInfo?
    var isChecking = false
    var lastCheckDate: Date?
    var lastError: String?

    private let provider: UpdateProviding
    private let currentVersion: (Int, Int, Int)
    private var checkTask: Task<Void, Never>?
    private var periodicTask: Task<Void, Never>?

    init(provider: UpdateProviding = GitHubReleaseProvider()) {
        self.provider = provider
        let version =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        self.currentVersion = Self.parseVersion(version) ?? (0, 0, 0)
    }

    func checkNow(includePreReleases: Bool = false) {
        // Deduplicate concurrent calls
        guard checkTask == nil else { return }

        isChecking = true
        lastError = nil

        checkTask = Task {
            defer {
                isChecking = false
                checkTask = nil
            }

            do {
                let release: ReleaseInfo?
                if includePreReleases {
                    let all = try await provider.allReleases()
                    release = all.first { r in
                        guard let remote = r.version else { return false }
                        return Self.isNewer(remote, than: currentVersion)
                    }
                } else {
                    let latest = try await provider.latestRelease()
                    if let remote = latest.version, Self.isNewer(remote, than: currentVersion) {
                        release = latest
                    } else {
                        release = nil
                    }
                }
                availableUpdate = release
                lastCheckDate = Date()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func startPeriodicChecks(settings: AppSettings) {
        periodicTask?.cancel()

        periodicTask = Task {
            // Initial delay
            try? await Task.sleep(for: .seconds(30))

            while !Task.isCancelled {
                if settings.checkForUpdates {
                    checkNow(includePreReleases: settings.includePreReleases)
                }
                try? await Task.sleep(for: .seconds(86400)) // 24 hours
            }
        }
    }

    // MARK: - Version Utilities

    nonisolated static func parseVersion(_ string: String) -> (Int, Int, Int)? {
        var s = string
        if s.hasPrefix("v") { s = String(s.dropFirst()) }
        // Strip pre-release suffix (e.g. "1.2.3-beta" → "1.2.3")
        if let dash = s.firstIndex(of: "-") {
            s = String(s[s.startIndex ..< dash])
        }
        let parts = s.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return (parts[0], parts[1], parts[2])
    }

    nonisolated static func isNewer(
        _ remote: (Int, Int, Int), than local: (Int, Int, Int),
    ) -> Bool {
        if remote.0 != local.0 { return remote.0 > local.0 }
        if remote.1 != local.1 { return remote.1 > local.1 }
        return remote.2 > local.2
    }
}
