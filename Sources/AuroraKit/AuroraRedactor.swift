import Foundation

public enum AuroraRedactor {
    private static let sensitiveKeys = [
        "admission_proof",
        "binding_proof",
        "hint_secret",
        "token_authenticator",
        "token_public_metadata",
    ]

    public static func redact(_ input: String) -> String {
        sensitiveKeys.reduce(input) { current, key in
            redactAssignment(key: key, in: current)
        }
    }

    private static func redactAssignment(key: String, in input: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"(\b\#(escaped)=)[^\s]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(in: input, range: range, withTemplate: "$1<redacted>")
    }
}
