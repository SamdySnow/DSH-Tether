import AppKit
import SwiftUI

/// Minimal ANSI escape-sequence (SGR) parser.
///
/// The DSH web profile writes colourised output. Rendering that as raw text in a
/// SwiftUI `Text` view would show literal `ESC[32m` garbage, so we translate the
/// common SGR subset into real `AttributedString` attributes.
///
/// Supported: reset, bold, dim, italic, underline, 16-colour foreground and
/// background, 256-colour (`38;5;n` / `48;5;n`) and 24-bit true colour
/// (`38;2;r;g;b` / `48;2;r;g;b`).
enum ANSIParser {

    /// Font size used for the console. Sourced from the theme so text and
    /// highlighting always agree.
    static let fontSize: CGFloat = ConsoleTheme.fontSize

    struct Style {
        var foreground: Color?
        var background: Color?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
    }

    // MARK: - Public entry point

    /// Converts a string that may contain ANSI escape sequences into an
    /// attributed string ready to be rendered in a monospaced `Text`.
    static func attributedString(from input: String) -> AttributedString {
        var output = AttributedString()
        var style = Style()
        var buffer = ""

        /// Emits `buffer` using the style that was active while it accumulated.
        func flush() {
            guard !buffer.isEmpty else { return }
            var piece = AttributedString(buffer)

            piece.font = .system(
                size: fontSize,
                weight: style.bold ? .bold : .regular,
                design: .monospaced
            )
            // Always set an explicit colour. Leaving this unset let the run inherit
            // the system label colour, which is black in light mode and therefore
            // invisible on the console's dark background.
            piece.foregroundColor = style.foreground ?? ConsoleTheme.foreground

            if style.italic {
                piece.font = piece.font?.italic()
            }
            if let background = style.background {
                piece.backgroundColor = background
            }
            if style.underline {
                piece.underlineStyle = .single
            }
            if style.dim {
                piece.foregroundColor = (style.foreground ?? ConsoleTheme.foreground).opacity(0.65)
            }

            output.append(piece)
            buffer.removeAll(keepingCapacity: true)
        }

        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]

            guard character == "\u{1B}" else {
                buffer.append(character)
                index = input.index(after: index)
                continue
            }

            // Escape sequence. Only CSI ... m (SGR) is interpreted; every other
            // escape sequence is consumed and dropped so it cannot leak into the
            // rendered text.
            var cursor = input.index(after: index)

            // Skip an intermediate 7-bit/8-bit introducer we do not model.
            if cursor < input.endIndex, input[cursor] == "[" {
                cursor = input.index(after: cursor)

                var parameters = ""
                while cursor < input.endIndex, !isFinalByte(input[cursor]) {
                    parameters.append(input[cursor])
                    cursor = input.index(after: cursor)
                }

                if cursor < input.endIndex {
                    let command = input[cursor]
                    if command == "m" {
                        flush()
                        apply(parameters: parameters, to: &style)
                    }
                    cursor = input.index(after: cursor)
                }
                index = cursor
                continue
            }

            // A bare ESC or an unsupported sequence: drop the ESC itself.
            index = cursor
        }

        flush()
        return output
    }

    /// Strips every escape sequence, leaving plain text. Used for export and for
    /// searching the transcript.
    static func stripping(_ input: String) -> String {
        String(attributedString(from: input).characters)
    }

    /// Keeps a foreground colour legible on the dark console.
    ///
    /// Handles the case the fixed palette cannot: a process may specify an
    /// arbitrary dark colour by RGB (`ESC[38;2;0;0;0m`) or by 256-colour index.
    /// Those are clamped to the nearest readable grey instead of rendering as
    /// invisible text.
    private static func legible(_ color: Color) -> Color {
        guard let luminance = relativeLuminance(of: color),
              luminance < minimumLuminance else {
            return color
        }
        return ConsoleTheme.remappedBlack
    }

    /// Perceived luminance, using the sRGB coefficients. Returns `nil` when the
    /// colour cannot be converted (for example a pattern or catalogue colour).
    private static func relativeLuminance(of color: Color) -> Double? {
        guard let components = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return 0.2126 * components.redComponent
            + 0.7152 * components.greenComponent
            + 0.0722 * components.blueComponent
    }

    /// Below this, text is unreadable against the console background.
    private static let minimumLuminance = 0.22

    // MARK: - Escape sequence helpers

    private static func isFinalByte(_ character: Character) -> Bool {
        // ECMA-48: final bytes are 0x40...0x7E. "@" ... "~" is a close-enough
        // superset for the sequences terminals actually emit.
        guard let ascii = character.asciiValue else { return false }
        return (0x40...0x7E).contains(ascii)
    }

    private static func apply(parameters: String, to style: inout Style) {
        // An empty parameter string means "reset" (ESC[m).
        let rawCodes = parameters
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? 0 : (Int($0) ?? 0) }

        var position = 0
        while position < rawCodes.count {
            let code = rawCodes[position]

            switch code {
            case 0:
                style = Style()
            case 1:
                style.bold = true
            case 2:
                style.dim = true
            case 3:
                style.italic = true
            case 4:
                style.underline = true
            case 21, 22:
                style.bold = false
                style.dim = false
            case 23:
                style.italic = false
            case 24:
                style.underline = false
            case 30...37:
                style.foreground = palette16[code - 30]
            case 39:
                style.foreground = nil
            case 40...47:
                style.background = palette16[code - 40]
            case 49:
                style.background = nil
            case 90...97:
                style.foreground = palette16[code - 90 + 8]
            case 100...107:
                style.background = palette16[code - 100 + 8]
            case 38, 48:
                // Extended colour: 38;5;n (256) or 38;2;r;g;b (true colour).
                let isForeground = code == 38
                if position + 1 < rawCodes.count, rawCodes[position + 1] == 5,
                   position + 2 < rawCodes.count {
                    // The 256-colour cube includes near-black entries; keep them
                    // readable rather than literally following the index.
                    let colour = color256(index: rawCodes[position + 2])
                    let usable = isForeground ? legible(colour) : colour
                    if isForeground { style.foreground = usable } else { style.background = usable }
                    position += 2
                } else if position + 1 < rawCodes.count, rawCodes[position + 1] == 2,
                          position + 4 < rawCodes.count {
                    let red = Double(clamp8(rawCodes[position + 2])) / 255
                    let green = Double(clamp8(rawCodes[position + 3])) / 255
                    let blue = Double(clamp8(rawCodes[position + 4])) / 255
                    let colour = Color(red: red, green: green, blue: blue)
                    let usable = isForeground ? legible(colour) : colour
                    if isForeground { style.foreground = usable } else { style.background = usable }
                    position += 4
                }
            default:
                break
            }

            position += 1
        }
    }

    private static func clamp8(_ value: Int) -> Int {
        min(255, max(0, value))
    }

    // MARK: - Palettes

    /// Standard 16-colour palette, adapted for a dark surface.
    ///
    /// Note index 0: ANSI "black" is remapped to grey. Tools emit `ESC[30m` for
    /// secondary text on the assumption of a light terminal, and taking that
    /// literally makes the text invisible here. The faint and bright variants of
    /// black are remapped for the same reason.
    private static let palette16: [Color] = [
        ConsoleTheme.remappedBlack,
        Color(red: 0.94, green: 0.43, blue: 0.43),
        Color(red: 0.36, green: 0.90, blue: 0.54),
        Color(red: 0.95, green: 0.80, blue: 0.36),
        Color(red: 0.45, green: 0.66, blue: 1.00),
        Color(red: 0.89, green: 0.53, blue: 0.95),
        Color(red: 0.38, green: 0.85, blue: 0.88),
        ConsoleTheme.foreground,
        ConsoleTheme.muted,
        Color(red: 1.00, green: 0.52, blue: 0.52),
        Color(red: 0.47, green: 0.97, blue: 0.62),
        Color(red: 1.00, green: 0.88, blue: 0.47),
        Color(red: 0.58, green: 0.75, blue: 1.00),
        Color(red: 1.00, green: 0.63, blue: 1.00),
        Color(red: 0.50, green: 0.95, blue: 0.98),
        Color.white,
    ]

    /// xterm 256-colour palette: 16 system colours, a 6x6x6 cube, then a
    /// 24-step greyscale ramp.
    private static func color256(index: Int) -> Color {
        let clamped = min(255, max(0, index))
        if clamped < 16 {
            return palette16[clamped]
        }
        if clamped < 232 {
            let cubeIndex = clamped - 16
            let levels: [Double] = [0, 95, 135, 175, 215, 255]
            let red = levels[(cubeIndex / 36) % 6] / 255
            let green = levels[(cubeIndex / 6) % 6] / 255
            let blue = levels[cubeIndex % 6] / 255
            return Color(red: red, green: green, blue: blue)
        }
        let grey = Double(8 + (clamped - 232) * 10) / 255
        return Color(red: grey, green: grey, blue: grey)
    }
}
