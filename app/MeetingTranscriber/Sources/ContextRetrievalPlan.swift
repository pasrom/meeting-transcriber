import Foundation

struct ContextSegment: Codable, Sendable {
    let id: String
    let text: String

    static func index(_ transcript: String) -> [Self] {
        transcript.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .enumerated().compactMap { index, line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return Self(id: "seg-\(index + 1)", text: String(line))
            }
    }
}

struct ContextCatalogEntry: Encodable, Sendable {
    let toolID: String
    let description: String
    let inputSchema: ContextJSON

    enum CodingKeys: String, CodingKey {
        case toolID = "tool_id"
        case description
        case inputSchema = "input_schema"
    }
}

struct ContextRetrievalPlan {
    let requests: [ContextJSON]

    init?(_ response: String) {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= ContextLimits.plannerReply else { return nil }
        // Some plain-text models wrap otherwise valid JSON in one Markdown fence.
        let json: String = if trimmed.hasPrefix("```json\n"), trimmed.hasSuffix("\n```") {
            String(trimmed.dropFirst(8).dropLast(4))
        } else {
            trimmed
        }
        guard let root = try? JSONDecoder().decode(ContextJSON.self, from: Data(json.utf8)),
              Set(root.object?.keys.map(\.self) ?? []) == ["schema_version", "requests"],
              root["schema_version"] == .integer(1) else { return nil }
        guard let requests = root["requests"]?.array else { return nil }
        self.requests = requests
    }
}

struct ContextLookup: Sendable {
    struct Mention: Sendable {
        let segmentID: String
        let surfaceText: String
    }

    let requestID: String
    let toolID: String
    let arguments: ContextJSON
    let argumentTextBytes: Int
    let mentions: [Mention]

    init?(
        _ raw: ContextJSON, segments: [String: String], transcript: String, secrets: [String],
    ) {
        guard Set(raw.object?.keys.map(\.self) ?? []) == ["request_id", "tool_id", "arguments", "mentions"],
              let requestID = raw["request_id"]?.string, requestID.range(of: "^[A-Za-z0-9_-]{1,48}$", options: .regularExpression) != nil,
              !ContextDataSafety.containsKnownSecret(requestID, secrets: secrets),
              let toolID = raw["tool_id"]?.string, toolID.utf8.count <= 160,
              let arguments = raw["arguments"], arguments.object != nil,
              let bytes = try? ContextJSON.encoded(arguments), bytes.count <= ContextLimits.arguments,
              let rawMentions = raw["mentions"]?.array, (1 ... 8).contains(rawMentions.count) else { return nil }

        var mentions: [Mention] = []
        for item in rawMentions {
            guard Set(item.object?.keys.map(\.self) ?? []) == ["segment_id", "surface_text"],
                  let id = item["segment_id"]?.string, let segment = segments[id],
                  let surface = item["surface_text"]?.string, !surface.isEmpty, surface.utf8.count <= 160,
                  segment.range(of: surface, options: [.caseInsensitive, .diacriticInsensitive]) != nil else { return nil }
            mentions.append(Mention(segmentID: id, surfaceText: surface))
        }
        guard let textBytes = ContextDataSafety.safeArgumentBytes(arguments, in: transcript, secrets: secrets) else { return nil }
        self.requestID = requestID
        self.toolID = toolID
        self.arguments = arguments
        argumentTextBytes = textBytes
        self.mentions = mentions
    }
}

enum ContextDataSafety {
    // Data minimization is structural. These common credential signatures
    // supplement the exact configured-secret checks without claiming DLP.
    private static let sensitivePattern = #"(?i)(-----BEGIN [A-Z ]*PRIVATE KEY-----|\b(?:bearer|basic)\s+[a-z0-9+/_.=~-]{8,}"#
        + #"|\b(?:sk-[a-z0-9_-]{10,}|gh[pousr]_[a-z0-9]{10,}|github_pat_[a-z0-9_]{10,}|AKIA[A-Z0-9]{16})\b"#
        + #"|\b(?:password|passwd|api.?key|secret|token|authorization)\s*["']?\s*[:=]\s*["']?\S+)"#

    private static let prohibitedKey = #"(?i)(?:password|passwd|secret|authorization|api.?key|access.?token|refresh.?token|credential"#
        + #"|transcript|conversation|messages|command|(?:^|[_.-])script(?:$|[_.-]))"#

    static func containsKnownSecret(_ string: String, secrets: [String]) -> Bool {
        secrets.contains { secret in
            guard !secret.isEmpty else { return false }
            if secret.utf8.count >= 4 { return string.contains(secret) }
            return string.split { !$0.isLetter && !$0.isNumber }.contains { $0 == secret }
        }
    }

    static func containsSensitive(_ string: String, secrets: [String]) -> Bool {
        containsKnownSecret(string, secrets: secrets)
            || string.range(of: sensitivePattern, options: .regularExpression) != nil
    }

    static func containsSensitive(_ value: ContextJSON, secrets: [String]) -> Bool {
        switch value {
        case let .object(fields):
            fields.contains { key, value in
                key.range(of: prohibitedKey, options: .regularExpression) != nil
                    || containsSensitive(key, secrets: secrets) || containsSensitive(value, secrets: secrets)
            }

        case let .array(values):
            values.contains { containsSensitive($0, secrets: secrets) }

        case let .string(string): containsSensitive(string, secrets: secrets)

        case .integer, .number, .bool, .null: false
        }
    }

    static func safeArgumentBytes(_ arguments: ContextJSON, in transcript: String, secrets: [String]) -> Int? {
        guard !containsSensitive(arguments, secrets: secrets), let strings = argumentStrings(arguments),

              strings.allSatisfy({ text in
                  text.utf8.count <= 160
                      && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                      && text.range(
                          of: #"(?:https?://|file:|data:|[A-Za-z0-9_+/=-]{64,})"#,
                          options: [.regularExpression, .caseInsensitive],
                      ) == nil
              }) else { return nil }
        let textBytes = strings.reduce(0) { $0 + $1.utf8.count }
        guard textBytes <= ContextLimits.queryTextPerCall else { return nil }
        let complete = words(transcript.replacingOccurrences(
            of: #"(?m)^\h*(?:(?:\[?\d{1,2}:\d{2}(?::\d{2})?\]?)[\h-]*)?(?:\[[^\]\n]{1,80}\][:\h]*)?"#,
            with: "", options: .regularExpression,
        ))
        let query = words(strings.joined(separator: " "))
        let sortedQuery = words(strings.sorted().joined(separator: " "))
        guard !complete.isEmpty else { return textBytes }
        let wholeTranscript = " " + complete + " "
        let reversedQuery = words(strings.reversed().joined(separator: " "))
        guard [query, sortedQuery, reversedQuery].allSatisfy({ !(" " + $0 + " ").contains(wholeTranscript) }) else {
            return nil
        }
        return textBytes
    }

    // swiftlint:disable:next discouraged_optional_collection
    private static func argumentStrings(_ value: ContextJSON, depth: Int = 0) -> [String]? {
        guard depth <= 5 else { return nil }
        let children: [ContextJSON]
        switch value {
        case let .object(fields):
            guard fields.count <= 12, fields.keys.allSatisfy({ key in
                key.range(of: #"^[\p{L}\p{N}_.-]{1,64}$"#, options: .regularExpression) != nil
            }) else { return nil }
            children = fields.sorted { $0.key < $1.key }.map(\.value)

        case let .array(values):
            guard values.count <= 12 else { return nil }
            children = values

        case let .string(text): return [text]

        case .integer, .number, .bool, .null: return []
        }
        var strings: [String] = []
        for child in children {
            guard let nested = argumentStrings(child, depth: depth + 1) else { return nil }
            strings += nested
        }
        return strings
    }

    private static func words(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }
}
