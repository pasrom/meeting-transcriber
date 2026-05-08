import Foundation

/// Word Error Rate calculator — pure Levenshtein on tokenised, normalised text.
///
/// Normalisation: lowercase (Unicode-aware), strip Latin punctuation, collapse
/// whitespace. German umlauts (ä/ö/ü/ß) are preserved — folding them would
/// hide a real ASR substitution.
///
/// Compound-word policy: compounds are NOT split. "Bundeskanzler" vs
/// "Bundes Kanzler" scores as substitution + insertion (raw WER may exceed 1.0
/// when the hypothesis has more tokens than the reference).
enum WERCalculator {
    struct Breakdown: Equatable {
        let substitutions: Int
        let deletions: Int
        let insertions: Int
        let referenceLength: Int
        let wer: Double
    }

    /// WER = (S + D + I) / N where N = len(reference tokens).
    /// Edge case: both empty → 0.0; reference empty + hypothesis non-empty → 1.0.
    static func wer(reference: String, hypothesis: String) -> Double {
        werBreakdown(reference: reference, hypothesis: hypothesis).wer
    }

    static func werBreakdown(reference: String, hypothesis: String) -> Breakdown {
        let refTokens = tokenise(reference)
        let hypTokens = tokenise(hypothesis)

        if refTokens.isEmpty {
            let wer = hypTokens.isEmpty ? 0.0 : 1.0
            return Breakdown(
                substitutions: 0,
                deletions: 0,
                insertions: hypTokens.count,
                referenceLength: 0,
                wer: wer,
            )
        }

        let (subs, dels, ins) = editCounts(reference: refTokens, hypothesis: hypTokens)
        let totalErrors = subs + dels + ins
        return Breakdown(
            substitutions: subs,
            deletions: dels,
            insertions: ins,
            referenceLength: refTokens.count,
            wer: Double(totalErrors) / Double(refTokens.count),
        )
    }

    // MARK: - Internals

    static func tokenise(_ s: String) -> [String] {
        // Strip punctuation that ASR engines drop or render inconsistently.
        // Keep apostrophes inside words ("don't") and German umlauts intact.
        let stripped = s.unicodeScalars.map { scalar -> Character in
            if punctuationToStrip.contains(scalar) {
                return " "
            }
            return Character(scalar)
        }
        return String(stripped)
            .lowercased()
            .split { $0.isWhitespace }
            .map(String.init)
    }

    private static let punctuationToStrip: Set<Unicode.Scalar> = {
        var set: Set<Unicode.Scalar> = []
        for s in ".,!?;:\"()[]{}<>—–-" {
            for u in s.unicodeScalars {
                set.insert(u)
            }
        }
        return set
    }()

    /// Levenshtein with tracked operation counts. Standard DP table; we
    /// reconstruct sub/del/ins counts via backtrace.
    private static func editCounts(
        reference: [String],
        hypothesis: [String],
    ) -> (subs: Int, dels: Int, ins: Int) {
        let m = reference.count
        let n = hypothesis.count
        // dp[i][j] = edit distance from reference[0..<i] to hypothesis[0..<j]
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0 ... m {
            dp[i][0] = i
        }
        for j in 0 ... n {
            dp[0][j] = j
        }
        for i in 1 ... max(m, 1) where m >= 1 {
            for j in 1 ... max(n, 1) where n >= 1 {
                if reference[i - 1] == hypothesis[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1]
                } else {
                    dp[i][j] = 1 + min(
                        dp[i - 1][j - 1], // substitution
                        dp[i - 1][j], // deletion
                        dp[i][j - 1], // insertion
                    )
                }
            }
        }

        // Backtrace from (m, n) to (0, 0) to count operations.
        var subs = 0
        var dels = 0
        var ins = 0
        var i = m
        var j = n
        while i > 0 || j > 0 {
            if i > 0, j > 0, reference[i - 1] == hypothesis[j - 1] {
                i -= 1
                j -= 1
                continue
            }
            let subCost = (i > 0 && j > 0) ? dp[i - 1][j - 1] : Int.max
            let delCost = (i > 0) ? dp[i - 1][j] : Int.max
            let insCost = (j > 0) ? dp[i][j - 1] : Int.max
            let best = min(subCost, delCost, insCost)
            if best == subCost {
                subs += 1
                i -= 1
                j -= 1
            } else if best == delCost {
                dels += 1
                i -= 1
            } else {
                ins += 1
                j -= 1
            }
        }
        return (subs, dels, ins)
    }
}
