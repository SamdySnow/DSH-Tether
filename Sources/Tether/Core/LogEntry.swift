import Foundation

/// One line (or chunk) of captured process output.
///
/// The parser is pure, so the type is declared `nonisolated` and can be built
/// from the service actor at the moment a line arrives.
nonisolated struct LogEntry: Identifiable, Sendable {
    enum Stream: Sendable {
        case standardOutput
        case standardError
        /// Produced by the app itself, not the child process.
        case app

        var isAppMessage: Bool { self == .app }
    }

    let id: UUID
    let stream: Stream
    /// Raw text, escape sequences included.
    let raw: String
    /// Escape sequences removed. Used for search, copy and export.
    let plain: String
    /// Rendered form with SGR colours applied. Computed once, on arrival, so the
    /// console does not re-parse the whole transcript on every redraw.
    let styled: AttributedString
    let date: Date

    init(stream: Stream, raw: String, date: Date = Date()) {
        self.id = UUID()
        self.stream = stream
        self.raw = raw
        self.plain = ANSIParser.stripping(raw)
        // ANSI colours are honoured first, then keyword highlighting fills in the
        // text the process left uncoloured.
        self.styled = KeywordHighlighter.highlight(ANSIParser.attributedString(from: raw))
        self.date = date
    }
}
