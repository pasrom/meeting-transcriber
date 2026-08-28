import Foundation

/// Opt-in canonical spelling rules applied after ASR. Each non-empty line uses
/// `Canonical => spoken variant | another variant`. Matching is deliberately
/// whole-word/phrase and case-insensitive. Rules are bounded before compiling
/// regular expressions because this runs on the main-actor pipeline path.
struct TerminologyNormalizer: Sendable {
    static let maximumRulesTextBytes = 64 * 1024
    static let maximumRuleCount = 200
    static let maximumTermBytes = 512

    struct Diagnostics: Equatable, Sendable {
        let activeRuleCount: Int
        let ignoredLineCount: Int
        let isTooLarge: Bool

        var message: String {
            if isTooLarge {
                return "Terminology rules are too large to apply."
            }
            var result = "\(activeRuleCount) active terminology rule\(activeRuleCount == 1 ? "" : "s")."
            if ignoredLineCount > 0 {
                result += " \(ignoredLineCount) invalid line\(ignoredLineCount == 1 ? " was" : "s were") ignored."
            }
            return result
        }
    }

    private let rules: [Rule]
    let diagnostics: Diagnostics

    var isEmpty: Bool {
        rules.isEmpty
    }

    init(rulesText: String = "") {
        let result = Self.parse(rulesText)
        rules = result.rules
        diagnostics = result.diagnostics
    }

    func normalize(_ text: String) -> String {
        var candidates: [Replacement] = []
        let sourceRange = NSRange(text.startIndex..., in: text)
        for (ruleIndex, rule) in rules.enumerated() {
            rule.expression.enumerateMatches(in: text, range: sourceRange) { match, _, _ in
                guard let match else { return }
                candidates.append(
                    Replacement(range: match.range, canonical: rule.canonical, ruleIndex: ruleIndex),
                )
            }
        }

        let sorted = candidates.sorted { lhs, rhs in
            (lhs.range.location, -lhs.range.length, lhs.ruleIndex)
                < (rhs.range.location, -rhs.range.length, rhs.ruleIndex)
        }
        var selected: [Replacement] = []
        var nextAvailableLocation = 0
        for candidate in sorted where candidate.range.location >= nextAvailableLocation {
            selected.append(candidate)
            nextAvailableLocation = candidate.range.upperBound
        }

        return selected.reversed().reduce(text) { current, replacement in
            guard let range = Range(replacement.range, in: current) else { return current }
            return current.replacingCharacters(in: range, with: replacement.canonical)
        }
    }

    private struct Rule: @unchecked Sendable {
        let canonical: String
        let expression: NSRegularExpression
    }

    private struct Replacement {
        let range: NSRange
        let canonical: String
        let ruleIndex: Int
    }

    private struct ParseResult {
        let rules: [Rule]
        let diagnostics: Diagnostics
    }

    private static func orderedAlternatives(canonical: String, variants: [String]) -> [String] {
        ([canonical] + variants)
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.count != rhs.element.count {
                    return lhs.element.count > rhs.element.count
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func parse(_ text: String) -> ParseResult {
        guard text.utf8.count <= maximumRulesTextBytes else {
            return ParseResult(
                rules: [],
                diagnostics: Diagnostics(activeRuleCount: 0, ignoredLineCount: 0, isTooLarge: true),
            )
        }

        var ignoredLineCount = 0
        var rules: [Rule] = []
        for line in text.components(separatedBy: .newlines) {
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard rules.count < maximumRuleCount else {
                ignoredLineCount += 1
                continue
            }
            let pieces = line.components(separatedBy: "=>")
            guard pieces.count == 2 else {
                ignoredLineCount += 1
                continue
            }
            let canonical = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !canonical.isEmpty, canonical.utf8.count <= maximumTermBytes else {
                ignoredLineCount += 1
                continue
            }

            var seen = Set<String>()
            let variants = pieces[1]
                .components(separatedBy: "|")
                .map { variant in variant.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { variant in
                    !variant.isEmpty
                        && variant.utf8.count <= maximumTermBytes
                        && seen.insert(variant.folding(
                            options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"),
                        )).inserted
                }
            guard !variants.isEmpty else {
                ignoredLineCount += 1
                continue
            }

            // Regex alternation is leftmost-first. Try the longest complete
            // phrase first so both directions work when one term prefixes the
            // other: `Kubernetes => Kubernetes Cluster` contracts the latter,
            // while `Kubernetes Cluster => Cluster` still expands the latter.
            // Keep the configured order for equal-length terms so the pattern
            // is deterministic; the replacement is always the canonical form.
            let alternatives = orderedAlternatives(canonical: canonical, variants: variants)
                .map(NSRegularExpression.escapedPattern(for:))
                .joined(separator: "|")
            let pattern = "(?<![\\p{L}\\p{N}])(?:\(alternatives))(?![\\p{L}\\p{N}])"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                ignoredLineCount += 1
                continue
            }
            rules.append(Rule(canonical: canonical, expression: expression))
        }
        return ParseResult(
            rules: rules,
            diagnostics: Diagnostics(
                activeRuleCount: rules.count,
                ignoredLineCount: ignoredLineCount,
                isTooLarge: false,
            ),
        )
    }
}
