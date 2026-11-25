import CryptoKit
import Foundation

enum ContextDigest {
    static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    static func hash(_ data: Data) -> String {
        sha256(data).map { String(format: "%02x", $0) }.joined()
    }
}
