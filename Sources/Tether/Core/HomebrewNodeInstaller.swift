import Foundation

enum NodeInstallError: Error {
    case homebrewNotFound
    case brewFailed(String)
}

enum HomebrewNodeInstaller {

    static func brewPath() -> String? {
        let environmentPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let candidateDirectories = ["/opt/homebrew/bin", "/usr/local/bin"] + environmentPaths
        var checkedDirectories = Set<String>()

        for directory in candidateDirectories where checkedDirectories.insert(directory).inserted {
            let candidate = "\(directory)/brew"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static func install() throws -> String {
        guard let brew = brewPath() else {
            throw NodeInstallError.homebrewNotFound
        }

        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["install", "node"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let outputText = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let details = outputText.isEmpty
                ? "brew install node exited with status \(process.terminationStatus)."
                : String(outputText.suffix(3000))
            throw NodeInstallError.brewFailed(details)
        }
        return outputText
    }
}
