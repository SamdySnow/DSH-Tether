import Foundation

/// The HTTP endpoint DSH is actually listening on.
///
/// DSH announces an authenticated URL when it starts, for example:
///
///     dsh web: http://127.0.0.1:8787/?token=ayMiNWn6lD_qNb9aIn4VU6_2Pf5VLSltYzKfWKepTmw
///
/// The `token` query item is required for access, so the plain
/// `http://127.0.0.1:<port>/` form is not equivalent — opening it yields an
/// unauthenticated request. The announced URL is therefore preferred, and the
/// bare loopback form is only a fallback for the case where the announcement has
/// not been observed yet.
enum ServiceEndpoint {

    /// Extracts the first loopback URL found in a line of process output.
    ///
    /// Runs against text that has already had ANSI sequences stripped, so a match
    /// can still pick up trailing punctuation; that is trimmed before parsing.
    static func extract(from text: String) -> URL? {
        let pattern = #"https?://(?:127\.0\.0\.1|localhost|\[::1\]):\d+/[^\s]*"#
        guard let range = text.range(of: pattern, options: .regularExpression) else {
            return nil
        }

        // Escapes can be interleaved with the match if the source was not the
        // parsed `plain` form, so strip them and any trailing sentence punctuation.
        var candidate = String(text[range])
        candidate = candidate.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*[A-Za-z]",
            with: "",
            options: .regularExpression
        )
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: " \t.,;:!?'\"`()<>"))

        guard let url = URL(string: candidate), url.host != nil else { return nil }
        return url
    }

    /// Unauthenticated loopback URL for a known port.
    ///
    /// Only correct when DSH has not published a token, or when the token is not
    /// enforced; prefer ``extract(from:)``.
    static func loopback(port: Int) -> URL? {
        URL(string: "http://127.0.0.1:\(port)/")
    }
}
