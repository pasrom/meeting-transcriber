import Foundation

/// Fail closed on constraints outside this subset. Strip annotations that can
/// contain data before sending a schema to the model. Validate the same subset
/// against arguments locally, including constraints on nested values.
enum ContextSchema {
    private static let types: Set<String> = ["object", "array", "string", "integer", "number", "boolean", "null"]
    private static let annotations: Set<String> = ["title", "description", "default", "examples", "$comment"]
    private static let common: Set<String> = ["type", "const", "enum"]
    private static let constraints: [String: Set<String>] = [
        "object": ["properties", "required", "additionalProperties", "minProperties", "maxProperties"],
        "array": ["items", "minItems", "maxItems", "uniqueItems"],
        "string": ["minLength", "maxLength"],
        "integer": ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"],
        "number": ["minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum"],
    ]

    static func catalogSchema(_ schema: ContextJSON) -> ContextJSON? {
        guard var fields = schema.object, fields["type"] == .string("object") else { return nil }
        if let dialect = fields.removeValue(forKey: "$schema") {
            let supported = [
                "http://json-schema.org/draft-07/schema#",
                "https://json-schema.org/draft/2019-09/schema",
                "https://json-schema.org/draft/2020-12/schema",
            ]
            guard let url = dialect.string, supported.contains(url) else { return nil }
        }
        return sanitized(.object(fields))
    }

    private static func sanitized(_ schema: ContextJSON) -> ContextJSON? {
        guard var fields = schema.object, let type = fields["type"]?.string, types.contains(type) else { return nil }
        let allowed = common.union(annotations).union(constraints[type] ?? [])
        guard Set(fields.keys).isSubset(of: allowed) else { return nil }
        for key in annotations {
            fields.removeValue(forKey: key)
        }
        for (key, value) in fields {
            guard let clean = sanitizedField(key, value) else { return nil }
            fields[key] = clean
        }
        if type == "object", let required = fields["required"]?.array,
           !Set(required.compactMap(\.string)).isSubset(of: Set(fields["properties"]?.object?.keys.map(\.self) ?? [])) {
            return nil
        }
        return .object(fields)
    }

    private static func sanitizedField(_ key: String, _ value: ContextJSON) -> ContextJSON? {
        switch key {
        case "properties":
            return sanitizedProperties(value)

        case "items":
            return sanitized(value)

        case "additionalProperties":
            // Schema-valued additionalProperties is supported. An absent or
            // true value allows any JSON value, still subject to egress limits.
            if case .bool = value { return value }
            return sanitized(value)

        case "required":
            guard let items = value.array, items.allSatisfy({ $0.string != nil }),
                  Set(items.compactMap(\.string)).count == items.count else { return nil }

        case "enum":
            guard let items = value.array, !items.isEmpty else { return nil }

        // Enumerations and constants are validation data. Omit their values
        // from the model catalog only if the source is denied entirely.
        case "uniqueItems":
            guard case .bool = value else { return nil }

        case "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum":
            guard numeric(value) != nil else { return nil }

        case "minProperties", "maxProperties", "minItems", "maxItems", "minLength", "maxLength":
            guard case let .integer(count) = value, count >= 0 else { return nil }

        default: break
        }
        return value
    }

    private static func sanitizedProperties(_ value: ContextJSON) -> ContextJSON? {
        guard let properties = value.object, properties.count <= 32 else { return nil }
        var clean: [String: ContextJSON] = [:]
        for (name, child) in properties {
            guard let reviewed = sanitized(child) else { return nil }
            clean[name] = reviewed
        }
        return .object(clean)
    }

    static func accepts(_ value: ContextJSON, schema: ContextJSON) -> Bool {
        if let allowed = schema["enum"]?.array, !allowed.contains(where: { equal($0, value) }) { return false }
        if let constant = schema["const"], !equal(constant, value) { return false }
        switch (schema["type"]?.string, value) {
        case let ("object", .object(fields)): return acceptsObject(fields, schema)

        case let ("array", .array(items)):
            guard countFits(items.count, schema: schema, suffix: "Items") else { return false }
            if schema["uniqueItems"] == .bool(true),
               items.enumerated().contains(where: { index, item in items.prefix(index).contains { equal($0, item) } }) {
                return false
            }
            guard let itemSchema = schema["items"] else { return true }
            return items.allSatisfy { accepts($0, schema: itemSchema) }

        case let ("string", .string(text)):
            return countFits(text.unicodeScalars.count, schema: schema, suffix: "Length")

        case ("integer", .integer), ("number", .integer), ("number", .number):
            return fitsNumber(value, schema)

        case ("boolean", .bool), ("null", .null): return true

        default: return false
        }
    }

    private static func acceptsObject(_ fields: [String: ContextJSON], _ schema: ContextJSON) -> Bool {
        guard countFits(fields.count, schema: schema, suffix: "Properties"),
              (schema["required"]?.array ?? []).compactMap(\.string).allSatisfy({ fields[$0] != nil }) else { return false }
        return fields.allSatisfy { key, value in
            if let property = schema["properties"]?[key] { return accepts(value, schema: property) }
            guard let additional = schema["additionalProperties"] else { return true }
            if case let .bool(allowed) = additional { return allowed }
            return accepts(value, schema: additional)
        }
    }

    private static func countFits(_ count: Int, schema: ContextJSON, suffix: String) -> Bool {
        if case let .integer(minimum) = schema["min" + suffix], count < minimum { return false }
        if case let .integer(maximum) = schema["max" + suffix], count > maximum { return false }
        return true
    }

    private static func fitsNumber(_ value: ContextJSON, _ schema: ContextJSON) -> Bool {
        guard let number = numeric(value) else { return false }
        if let min = numeric(schema["minimum"]), number < min { return false }
        if let max = numeric(schema["maximum"]), number > max { return false }
        if let min = numeric(schema["exclusiveMinimum"]), number <= min { return false }
        if let max = numeric(schema["exclusiveMaximum"]), number >= max { return false }
        return true
    }

    private static func numeric(_ value: ContextJSON?) -> Decimal? {
        switch value {
        case let .integer(value): Decimal(value)
        case let .number(value) where value.isFinite: Decimal(string: String(value), locale: Locale(identifier: "en_US_POSIX"))
        default: nil
        }
    }

    private static func equal(_ first: ContextJSON, _ second: ContextJSON) -> Bool {
        switch (first, second) {
        case let (.object(a), .object(b)):
            return a.count == b.count && a.allSatisfy { key, value in b[key].map { equal(value, $0) } ?? false }

        case let (.array(a), .array(b)):
            return a.count == b.count && zip(a, b).allSatisfy(equal)

        default:
            if let a = numeric(first), let b = numeric(second) { return a == b }
            return first == second
        }
    }
}
