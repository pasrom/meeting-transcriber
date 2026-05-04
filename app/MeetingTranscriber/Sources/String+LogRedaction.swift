import CryptoKit
import Foundation

extension String {
    /// Deterministic 4-hex-char pseudonym derived from SHA-256.
    /// Stable across runs (same input → same output) so logs can be correlated
    /// without exposing the clear name. Used for speaker IDs in diagnostic logs.
    var pseudonymized: String {
        guard !isEmpty else { return "speaker_anon" }
        let hash = SHA256.hash(data: Data(utf8))
        let prefix = hash.prefix(2).map { String(format: "%02x", $0) }.joined()
        return "speaker_\(prefix)"
    }

    /// First-and-last-char redaction: "Roman" → "R***n", "Tom" → "T**", "Li" → "L*".
    /// Less privacy-preserving than `pseudonymized` (length leaks); use for UI-adjacent
    /// logs where the user actively benefits from recognising "their" name. For
    /// machine-readable forensic logs, prefer `pseudonymized`.
    var redactedName: String {
        let chars = Array(self)
        if chars.isEmpty { return "" }
        if chars.count == 1 { return "*" }
        if chars.count == 2 { return "\(chars[0])*" }
        if chars.count == 3 { return "\(chars[0])**" }
        let last = chars[chars.count - 1]
        let middle = String(repeating: "*", count: chars.count - 2)
        return "\(chars[0])\(middle)\(last)"
    }
}
