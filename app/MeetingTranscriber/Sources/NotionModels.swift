// swiftlint:disable:this file_name
// The wire models mirror Notion's JSON, where absent keys are distinct from
// empty values and optional booleans/collections are part of the API contract.
import Foundation

// MARK: - Notion Database Models

struct NotionDatabaseCreateRequest: Encodable {
    struct Parent: Encodable {
        let pageId: String

        enum CodingKeys: String, CodingKey {
            case type
            case pageId = "page_id"
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("page_id", forKey: .type)
            try container.encode(pageId, forKey: .pageId)
        }
    }

    struct TitleContent: Encodable {
        let text: TextContent

        enum CodingKeys: String, CodingKey { case type, text }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        }
    }

    struct TextContent: Encodable {
        let content: String
    }

    struct Properties: Encodable {
        func encode(to encoder: any Encoder) throws {
            let definitions: [String: [String: [String: String]]] = [
                "Title": ["title": [:]],
                "Tags": ["multi_select": [:]],
                "Date": ["date": [:]],
                "Created time": ["created_time": [:]],
                "Last edited time": ["last_edited_time": [:]],
            ]
            var container = encoder.singleValueContainer()
            try container.encode(definitions)
        }
    }

    let parent: Parent
    let title: [TitleContent]
    let properties: Properties
}

struct NotionDatabaseResponse: Decodable {
    struct TitleItem: Decodable {
        let plainText: String?
        enum CodingKeys: String, CodingKey {
            case plainText = "plain_text"
        }
    }

    struct PropertyInfo: Decodable {
        let type: String
    }

    let id: String
    let title: [TitleItem]? // swiftlint:disable:this discouraged_optional_collection
    let properties: [String: PropertyInfo]? // swiftlint:disable:this discouraged_optional_collection
    let inTrash: Bool? // swiftlint:disable:this discouraged_optional_boolean
    let archived: Bool? // swiftlint:disable:this discouraged_optional_boolean

    var isTrashed: Bool {
        inTrash == true || archived == true
    }

    enum CodingKeys: String, CodingKey {
        case id, title, properties, archived
        case inTrash = "in_trash"
    }
}

struct NotionBotInfoResponse: Decodable {
    struct BotDetails: Decodable {
        let workspaceName: String?
        enum CodingKeys: String, CodingKey {
            case workspaceName = "workspace_name"
        }
    }

    let name: String?
    let bot: BotDetails?
}

/// The columns the exporter can use, resolved once so schema checks and
/// page creation cannot disagree about which property receives the date or
/// the tags.
struct NotionResolvedSchema: Equatable, Sendable {
    let titleColumnName: String
    let dateColumnName: String?
    let tagsColumnName: String?

    /// Only the title is required. Date and Tags are optional enrichment, so
    /// a database without them is still usable; the Settings UI offers to add
    /// them instead of calling the database incompatible.
    var missingOptionalColumnLabels: [String] {
        var missing: [String] = []
        if tagsColumnName == nil { missing.append("Tags") }
        if dateColumnName == nil { missing.append("Date") }
        return missing
    }

    /// Conventional names the exporter is willing to write into. Deliberately
    /// an allowlist, not "the first date/multi_select column": a database with
    /// a Status multi_select and a Due date would otherwise receive speaker
    /// names and the meeting date in columns that mean something else.
    static let dateColumnNames = ["date", "meeting date", "meeting-day", "meeting day", "call date", "when"]
    static let tagColumnNames = ["tags", "labels", "speakers", "participants"]

    /// Picks one property per role deterministically. A property whose name
    /// matches the allowlist wins; otherwise the column stays unset.
    static func resolve(_ properties: [String: NotionDatabaseResponse.PropertyInfo]) -> Self {
        let sorted = properties.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }

        func isRecognizedName(_ name: String, names: [String]) -> Bool {
            let lowercased = name.lowercased()
            if names.contains(lowercased) { return true }
            // `NotionColumnDefinition` may have to append this suffix when the
            // conventional name is occupied by another type.
            return names.contains { lowercased.hasPrefix("\($0) (meeting transcriber") }
        }

        func column(type: String, names: [String], preferred: String) -> String? {
            if let exact = sorted.first(where: { property in
                property.value.type == type && property.key.caseInsensitiveCompare(preferred) == .orderedSame
            }) {
                return exact.key
            }
            return sorted.first { property in
                property.value.type == type && isRecognizedName(property.key, names: names)
            }?.key
        }

        return Self(
            titleColumnName: sorted.first { property in property.value.type == "title" }?.key ?? "Title",
            dateColumnName: column(type: "date", names: dateColumnNames, preferred: "Date"),
            tagsColumnName: column(type: "multi_select", names: tagColumnNames, preferred: "Tags"),
        )
    }
}

/// A column the exporter may add to an existing database.
struct NotionColumnDefinition: Equatable, Sendable {
    enum Kind: String, Sendable {
        case tags = "multi_select"
        case date

        var defaultName: String {
            switch self {
            case .tags: "Tags"
            case .date: "Date"
            }
        }
    }

    let name: String
    let kind: Kind

    /// Builds the PATCH definitions for the requested missing labels, choosing
    /// a free property name when the conventional one is already occupied by a
    /// different type. Notion rejects a PATCH that reuses an existing name.
    static func definitions(
        for missingLabels: [String],
        existingProperties: [String: NotionDatabaseResponse.PropertyInfo],
    ) -> [Self] {
        var usedNames = Set(existingProperties.keys.map { $0.lowercased() })

        func freeName(for preferred: String) -> String {
            guard usedNames.contains(preferred.lowercased()) else {
                usedNames.insert(preferred.lowercased())
                return preferred
            }
            var candidate = "\(preferred) (Meeting Transcriber)"
            var counter = 2
            while usedNames.contains(candidate.lowercased()) {
                candidate = "\(preferred) (Meeting Transcriber \(counter))"
                counter += 1
            }
            usedNames.insert(candidate.lowercased())
            return candidate
        }

        return missingLabels.compactMap { label in
            let kind: Kind
            switch label {
            case "Tags": kind = .tags
            case "Date": kind = .date
            default: return nil
            }
            return Self(name: freeName(for: kind.defaultName), kind: kind)
        }
    }
}

struct NotionDatabasePatchRequest: Encodable {
    let properties: [String: [String: AnyEncodable]]

    init(columns: [NotionColumnDefinition]) {
        var props: [String: [String: AnyEncodable]] = [:]
        for column in columns {
            props[column.name] = [column.kind.rawValue: AnyEncodable([String: String]())]
        }
        self.properties = props
    }
}

struct NotionDatabaseSchemaStatus: Equatable, Sendable {
    let databaseID: String
    let title: String
    let titleColumnName: String
    let dateColumnName: String?
    let tagsColumnName: String?
    let hasTags: Bool
    let hasDate: Bool
    let missingColumns: [String]

    /// True when every optional column is present. A database with only a
    /// title is still exportable; this only drives the Settings hint.
    var hasAllOptionalColumns: Bool {
        missingColumns.isEmpty
    }

    init(databaseID: String, title: String, schema: NotionResolvedSchema) {
        self.databaseID = databaseID
        self.title = title
        titleColumnName = schema.titleColumnName
        dateColumnName = schema.dateColumnName
        tagsColumnName = schema.tagsColumnName
        hasTags = schema.tagsColumnName != nil
        hasDate = schema.dateColumnName != nil
        missingColumns = schema.missingOptionalColumnLabels
    }
}

// MARK: - Notion Search Models

struct NotionSearchItem: Decodable {
    struct PageProperty: Decodable {
        let type: String
        let title: [NotionDatabaseResponse.TitleItem]? // swiftlint:disable:this discouraged_optional_collection

        enum CodingKeys: String, CodingKey {
            case type, title
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.type = (try? container.decode(String.self, forKey: .type)) ?? ""
            self.title = try? container.decode([NotionDatabaseResponse.TitleItem].self, forKey: .title)
        }
    }

    let id: String
    let title: [NotionDatabaseResponse.TitleItem]? // swiftlint:disable:this discouraged_optional_collection
    let properties: [String: PageProperty]? // swiftlint:disable:this discouraged_optional_collection
    let inTrash: Bool? // swiftlint:disable:this discouraged_optional_boolean
    let archived: Bool? // swiftlint:disable:this discouraged_optional_boolean

    var isTrashed: Bool {
        inTrash == true || archived == true
    }

    enum CodingKeys: String, CodingKey {
        case id, title, properties, archived
        case inTrash = "in_trash"
    }
}

private struct FailableDecodable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: any Decoder) {
        let container = try? decoder.singleValueContainer()
        self.value = try? container?.decode(T.self)
    }
}

struct NotionSearchResponse: Decodable {
    let results: [NotionSearchItem]
    let hasMore: Bool
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case results
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let failableItems = try? container.decode([FailableDecodable<NotionSearchItem>].self, forKey: .results)
        self.results = failableItems?.compactMap(\.value) ?? []
        hasMore = (try? container.decode(Bool.self, forKey: .hasMore)) ?? false
        nextCursor = try? container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

struct NotionDatabaseItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

struct NotionPageItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
}

// MARK: - Notion Page Models

struct NotionPageCreateRequest: Encodable {
    struct Parent: Encodable {
        let databaseId: String
        enum CodingKeys: String, CodingKey {
            case databaseId = "database_id"
        }
    }

    struct Icon: Encodable {
        let emoji: String

        enum CodingKeys: String, CodingKey { case type, emoji }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("emoji", forKey: .type)
            try container.encode(emoji, forKey: .emoji)
        }
    }

    let parent: Parent
    let icon: Icon?
    let properties: [String: NotionPropertyValue]
    let children: [NotionBlock]
}

enum NotionPropertyValue: Encodable {
    case title(String)
    case date(Date)
    case multiSelect([String])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .title(text):
            let dict: [String: [[String: AnyEncodable]]] = [
                "title": [
                    [
                        "type": AnyEncodable("text"),
                        "text": AnyEncodable(["content": AnyEncodable(String(text.prefix(2000)))]),
                    ],
                ],
            ]
            try container.encode(dict)

        case let .date(date):
            let formatter = ISO8601DateFormatter()
            let dict: [String: [String: String]] = [
                "date": ["start": formatter.string(from: date)],
            ]
            try container.encode(dict)

        case let .multiSelect(tags):
            var seen = Set<String>()
            let selectArray: [[String: String]] = tags.compactMap { tag in
                let name = String(tag.replacingOccurrences(of: ",", with: " ")
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(100))
                let genericNames = ["unknown", "remote", "local", "speaker"]
                guard !name.isEmpty, !genericNames.contains(name.lowercased()),
                      name.range(of: #"^(S\d+|SPEAKER[_ ]?\d+)$"#, options: [.regularExpression, .caseInsensitive]) == nil,
                      seen.insert(name.lowercased()).inserted else { return nil }
                return ["name": name]
            }
            let dict: [String: [[String: String]]] = [
                "multi_select": selectArray,
            ]
            try container.encode(dict)
        }
    }
}

struct NotionPageUpdateRequest: Encodable {
    let properties: [String: NotionPropertyValue]
}

struct NotionPageResponse: Decodable {
    let id: String
    let url: String?
    private let archived: Bool? // swiftlint:disable:this discouraged_optional_boolean
    private let inTrash: Bool? // swiftlint:disable:this discouraged_optional_boolean

    var isTrashed: Bool {
        archived == true || inTrash == true
    }

    enum CodingKeys: String, CodingKey {
        case id, url, archived
        case inTrash = "in_trash"
    }
}

struct NotionBlockSummary: Decodable {
    let id: String
}

struct NotionBlockListResponse: Decodable {
    let results: [NotionBlockSummary]
    let hasMore: Bool
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case results
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decode([NotionBlockSummary].self, forKey: .results)
        hasMore = try container.decodeIfPresent(Bool.self, forKey: .hasMore) ?? false
        nextCursor = try container.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

struct NotionAPIErrorBody: Decodable {
    let code: String?
    let message: String?
}

// MARK: - Notion Block Models

struct NotionBlock: Encodable {
    let object: String = "block"
    let type: String
    let content: [String: AnyEncodable]

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(object, forKey: Self.key("object"))
        try container.encode(type, forKey: Self.key("type"))
        try container.encode(content, forKey: Self.key(type))
    }

    private static func key(_ string: String) -> DynamicKey {
        // CodingKey's failable initializer only fails for invalid integer keys.
        // swiftlint:disable:next force_unwrapping
        DynamicKey(stringValue: string)!
    }
}

struct NotionBlockAppendRequest: Encodable {
    let children: [NotionBlock]
}

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

struct AnyEncodable: Encodable {
    private let encodeFunc: (any Encoder) throws -> Void

    init(_ value: some Encodable) {
        encodeFunc = { try value.encode(to: $0) }
    }

    func encode(to encoder: any Encoder) throws {
        try encodeFunc(encoder)
    }
}
