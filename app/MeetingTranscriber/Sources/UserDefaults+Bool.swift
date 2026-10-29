import Foundation

extension UserDefaults {
    /// A stored flag, or `fallback` when the key was never written or holds
    /// something that is not a flag.
    ///
    /// Not `object(forKey:) as? Bool`: an untyped `defaults write <domain> <key> 1`
    /// stores the *string* "1", which that cast reads as missing, so the setting
    /// silently fell back to its default while the launch path's own
    /// `bool(forKey:)` read of `autoWatch` saw true (issue #814).
    func bool(forKey key: String, default fallback: Bool) -> Bool {
        flag(forKey: key) ?? fallback
    }

    /// The flag stored under `key`, or nil when it is absent or unreadable.
    ///
    /// Numbers and the strings `defaults write` produces for one ("1", "yes",
    /// "true" and their negatives) count. Anything else is nil rather than
    /// false: `bool(forKey:)` would read a stray "on" as false, which turns a
    /// default-on setting off. The optional is the point: nil means "no
    /// answer", which each caller resolves to its own default.
    func flag(forKey key: String) -> Bool? { // swiftlint:disable:this discouraged_optional_boolean
        switch object(forKey: key) {
        case let value as Bool:
            value

        case let value as Int:
            value != 0

        case let string as String:
            switch string.lowercased() {
            case "1", "yes", "true": true
            case "0", "no", "false": false
            default: nil
            }

        default:
            nil
        }
    }
}
