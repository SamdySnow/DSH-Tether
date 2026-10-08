import Foundation
import SwiftUI

/// Colours and typography for the console surface.
///
/// The console is a **dark** surface, which drives two decisions:
///
/// 1. The default text colour is near-white rather than the system label colour.
///    Using `.primary` here produced black text on a black background whenever the
///    system was in light mode, making output unreadable.
/// 2. ANSI "black" (`ESC[30m`) is remapped to a visible grey. Loggers emit it for
///    secondary text assuming a light terminal, and taken literally it is
///    invisible against a dark one.
enum ConsoleTheme {

    // MARK: - Surface

    /// Console background, used both by the view and to judge contrast.
    static let background = Color(red: 0.055, green: 0.063, blue: 0.086)

    /// Base text colour. Every run that carries no explicit colour ends up here.
    static let foreground = Color(red: 0.894, green: 0.910, blue: 0.937)

    static let fontSize: CGFloat = 12

    // MARK: - Semantic colours

    static let error = Color(red: 1.00, green: 0.42, blue: 0.42)
    static let warning = Color(red: 1.00, green: 0.78, blue: 0.34)
    static let success = Color(red: 0.36, green: 0.90, blue: 0.54)
    static let info = Color(red: 0.34, green: 0.78, blue: 0.96)
    static let url = Color(red: 0.48, green: 0.64, blue: 0.97)
    static let path = Color(red: 0.73, green: 0.60, blue: 0.97)
    static let number = Color(red: 1.00, green: 0.62, blue: 0.39)
    static let keyword = Color(red: 0.49, green: 0.81, blue: 1.00)
    static let muted = Color(red: 0.54, green: 0.58, blue: 0.65)
    static let string = Color(red: 0.62, green: 0.81, blue: 0.42)

    /// Colour for a run that the process explicitly marked as "black".
    static let remappedBlack = Color(red: 0.42, green: 0.46, blue: 0.53)
}

/// Semantic category used to colour a matched keyword.
enum HighlightStyle: String, CaseIterable, Sendable {
    case error
    case warning
    case success
    case info
    case url
    case path
    case number
    case keyword
    case string
    case muted

    var color: Color {
        switch self {
        case .error: ConsoleTheme.error
        case .warning: ConsoleTheme.warning
        case .success: ConsoleTheme.success
        case .info: ConsoleTheme.info
        case .url: ConsoleTheme.url
        case .path: ConsoleTheme.path
        case .number: ConsoleTheme.number
        case .keyword: ConsoleTheme.keyword
        case .string: ConsoleTheme.string
        case .muted: ConsoleTheme.muted
        }
    }

    var isBold: Bool {
        switch self {
        case .error, .success, .warning: true
        default: false
        }
    }

    var isUnderlined: Bool { self == .url }
}

/// Colours keywords in log output so different kinds of information are
/// distinguishable at a glance.
///
/// Keyword colouring is applied **only to text that carries no explicit ANSI
/// colour**. A process that has already chosen a colour knows better than a
/// heuristic, so its choice always wins.
enum KeywordHighlighter {

    /// Which regex engine to use.
    ///
    /// `NSRegularExpression` needs no compile-time feature flags, so it is the
    /// default. Swift's `Regex` is faster and has no Objective-C bridging, so the
    /// alternative path is kept and can be selected by enabling the
    /// `USE_SWIFT_REGEX` compilation condition.
    #if USE_SWIFT_REGEX
    private static let useSwiftRegex = true
    #else
    private static let useSwiftRegex = false
    #endif

    struct Rule: Sendable {
        let pattern: String
        let style: HighlightStyle
    }

    /// Ordered by importance. Earlier rules win on overlap, so a line containing
    /// `error: failed to open /tmp/x` colours the error words as errors rather
    /// than letting the path rule take them.
    static let rules: [Rule] = [
        // Severity first: these carry the most meaning.
        Rule(pattern: #"\b(?:errors?|failed|failure|fatal|exception|panic|abort(?:ed)?|denied|refused|timeout|timed out|not found|unable to|cannot|invalid)\b"#, style: .error),
        Rule(pattern: #"\b(?:warn(?:ing)?s?|deprecated|caution|skipped|retry(?:ing)?)\b"#, style: .warning),
        Rule(pattern: #"\b(?:success(?:ful(?:ly)?)?|succeeded|ok|ready|listening|started|done|complete[d]?|passed|resolved|installed|available)\b"#, style: .success),
        Rule(pattern: #"\b(?:info|note|notice|using|running|starting|loading|fetch(?:ing)?|found|created|updated|added|removed|building|compiling)\b"#, style: .info),

        // Then shapes that are unambiguous.
        Rule(pattern: #"https?://[^\s\"]+"#, style: .url),
        Rule(pattern: #"(?:^|(?<=[\s(\["']))(?:/[\w.@+-]+)+/?"#, style: .path),
        Rule(pattern: #"\b\d{1,3}(?:\.\d{1,3}){3}\b"#, style: .number),
        Rule(pattern: #"(?<![\w.])\d+(?:\.\d+)?(?:ms|s|MB|KB|GB|%|s\b)?"#, style: .number),
        Rule(pattern: #"\b[0-9a-f]{7,40}\b"#, style: .muted),
        Rule(pattern: #"\b\d{1,2}:\d{2}:\d{2}(?:\.\d+)?\b"#, style: .muted),

        // Package and tool names that identify what is happening.
        Rule(pattern: #"\b(?:npm|npx|node|dsh|DSH|deepseek-ai|deepseek|cordis|pnpm|yarn)\b"#, style: .keyword),
        Rule(pattern: #"@[a-z0-9][\w.-]*/[\w.-]+"#, style: .keyword),
        Rule(pattern: #"\b(?:true|false|null|undefined|nil)\b"#, style: .string),
    ]

    /// Applies keyword colouring to `input`, leaving explicitly-coloured runs
    /// untouched.
    static func highlight(_ input: AttributedString) -> AttributedString {
        guard !input.characters.isEmpty else { return input }

        var result = AttributedString()

        for run in input.runs {
            let piece = AttributedString(input[run.range])

            // An ANSI-coloured run keeps its colour: the process's own intent
            // outranks a keyword heuristic.
            guard run.foregroundColor == nil else {
                result.append(piece)
                continue
            }

            for segment in segments(of: String(piece.characters), template: piece) {
                result.append(segment)
            }
        }

        return result
    }

    /// Splits `text` into coloured keyword segments and plain gaps, carrying
    /// `template`'s font and background onto each piece.
    private static func segments(of text: String, template: AttributedString) -> [AttributedString] {
        guard !text.isEmpty else { return [] }

        let found = matches(in: text)
        guard !found.isEmpty else { return [applyingTemplate(template, to: text)] }

        var pieces: [AttributedString] = []
        var cursor = text.startIndex

        for (range, style) in found {
            if cursor < range.lowerBound {
                pieces.append(applyingTemplate(template, to: String(text[cursor..<range.lowerBound])))
            }

            var coloured = applyingTemplate(template, to: String(text[range]))
            coloured.foregroundColor = style.color
            if style.isBold {
                coloured.font = (template.font ?? .system(size: ConsoleTheme.fontSize, design: .monospaced)).bold()
            }
            if style.isUnderlined {
                coloured.underlineStyle = .single
            }
            pieces.append(coloured)

            cursor = range.upperBound
        }

        if cursor < text.endIndex {
            pieces.append(applyingTemplate(template, to: String(text[cursor...])))
        }

        return pieces
    }

    /// Builds an attributed string from `text` carrying only `template`'s
    /// non-colour attributes, so the highlighter never inherits a colour.
    private static func applyingTemplate(_ template: AttributedString, to text: String) -> AttributedString {
        var piece = AttributedString(text)
        piece.font = template.font ?? .system(size: ConsoleTheme.fontSize, design: .monospaced)
        piece.backgroundColor = template.backgroundColor
        return piece
    }

    /// Non-overlapping matches, earliest rule winning.
    private static func matches(in text: String) -> [(range: Range<String.Index>, style: HighlightStyle)] {
        guard !text.isEmpty else { return [] }

        var claimed: [Range<String.Index>] = []
        var found: [(Range<String.Index>, HighlightStyle)] = []

        for rule in rules {
            for range in ranges(of: rule.pattern, in: text) {
                // Skip anything an earlier rule already claimed.
                guard !claimed.contains(where: { $0.overlaps(range) }) else { continue }
                claimed.append(range)
                found.append((range, rule.style))
            }
        }

        return found.sorted { $0.0.lowerBound < $1.0.lowerBound }
    }

    /// All matches of `pattern` in `text`, using whichever engine is enabled.
    private static func ranges(of pattern: String, in text: String) -> [Range<String.Index>] {
        useSwiftRegex ? swiftRanges(of: pattern, in: text) : foundationRanges(of: pattern, in: text)
    }

    /// Foundation path. `NSRegularExpression` matching is thread-safe, so the
    /// cache below is safe to share across the actors that build log entries.
    private static func foundationRanges(of pattern: String, in text: String) -> [Range<String.Index>] {
        guard let regex = compiledFoundation(pattern) else { return [] }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, options: [], range: full).compactMap { match in
            Range(match.range, in: text)
        }
    }

    private nonisolated(unsafe) static var foundationCache: [String: NSRegularExpression] = [:]
    private static let foundationCacheLock = NSLock()

    private static func compiledFoundation(_ pattern: String) -> NSRegularExpression? {
        foundationCacheLock.lock()
        defer { foundationCacheLock.unlock() }

        if let cached = foundationCache[pattern] { return cached }
        guard let created = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        foundationCache[pattern] = created
        return created
    }

    /// Swift `Regex` path, selected with the `USE_SWIFT_REGEX` compilation
    /// condition.
    private static func swiftRanges(of pattern: String, in text: String) -> [Range<String.Index>] {
        #if USE_SWIFT_REGEX
        guard let regex = try? Regex(pattern).ignoresCase() else { return [] }
        return text.matches(of: regex).map(\.range)
        #else
        return []
        #endif
    }
}
