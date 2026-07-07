import Foundation

/// A speaker identity in the dual-track pipeline: a raw diarizer id plus the
/// track it came from. This type is the single home for the `R_`/`M_` track
/// prefix knowledge that is otherwise duplicated across the codebase.
///
/// `encoded` / `init(encoded:)` are the ONE serialization boundary between this
/// value and the legacy prefixed-string form used by persistence, wire formats,
/// and the diarization merge. Raw diarizer ids are `SPEAKER_\d+` (they never
/// begin with `R_` or `M_`), so the round-trip is bijective:
/// `SpeakerKey(encoded: key.encoded) == key` for every key.
struct SpeakerKey: Hashable, Comparable {
    /// Which diarized track a speaker id belongs to. `single` is the
    /// unprefixed single-source form.
    enum Track: String, Codable {
        case app, mic, single
    }

    let track: Track
    /// Raw diarizer id, e.g. `"SPEAKER_0"` (never carries a track prefix).
    let id: String
}

extension SpeakerKey {
    /// The exact legacy string form. This is the ONE place the prefix strings
    /// live: `R_` for the remote/app track, `M_` for the mic track, and the
    /// bare id for single-source.
    var encoded: String {
        switch track {
        case .app: "R_\(id)"
        case .mic: "M_\(id)"
        case .single: id
        }
    }

    /// Parses the legacy prefix form. Total, never fails: an id that lacks an
    /// `R_`/`M_` prefix is treated as single-source (its raw ids are
    /// `SPEAKER_\d+`, so this is unambiguous).
    init(encoded: String) {
        if encoded.hasPrefix("R_") {
            self.init(track: .app, id: String(encoded.dropFirst(2)))
        } else if encoded.hasPrefix("M_") {
            self.init(track: .mic, id: String(encoded.dropFirst(2)))
        } else {
            self.init(track: .single, id: encoded)
        }
    }

    /// Orders by the encoded string form so downstream (UI / DTO) ordering is
    /// preserved when later slices sort `SpeakerKey`s directly instead of their
    /// legacy string labels.
    static func < (lhs: SpeakerKey, rhs: SpeakerKey) -> Bool {
        lhs.encoded < rhs.encoded
    }
}
