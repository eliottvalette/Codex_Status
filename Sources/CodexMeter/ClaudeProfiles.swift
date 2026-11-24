import Foundation

/// Claude Code keeps one account per configuration directory. `~/.claude` is the default;
/// any other directory is selected with `CLAUDE_CONFIG_DIR`.
enum ClaudeProfiles {
    static let defaultDirectoryName = ".claude"
    private static let maximumProjectNameLength = 200

    /// Finds `~/.claude` and every `~/.claude-*` directory that holds Claude Code data.
    static func discover(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [CodexProfile] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: home.path) else {
            return []
        }

        return names
            .filter { name in
                guard name == defaultDirectoryName || name.hasPrefix(defaultDirectoryName + "-") else {
                    return false
                }
                let directory = home.appending(path: name)
                guard isDirectory(directory) else { return false }
                if name == defaultDirectoryName { return true }
                return isDirectory(directory.appending(path: "projects"))
                    || fileManager.fileExists(atPath: directory.appending(path: ".claude.json").path)
            }
            .sorted { first, second in
                if (first == defaultDirectoryName) != (second == defaultDirectoryName) {
                    return first == defaultDirectoryName
                }
                return first < second
            }
            .map { name in
                let alias = String(name.dropFirst())
                return CodexProfile(
                    id: alias,
                    displayName: alias,
                    homeURL: home.appending(path: name),
                    provider: .claude
                )
            }
    }

    /// Claude Code signs in the default directory only while `CLAUDE_CONFIG_DIR` is unset,
    /// so the default profile must run without the variable.
    static func usesDefaultDirectory(
        _ profile: CodexProfile,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        profile.homeURL.standardizedFileURL.path
            == home.appending(path: defaultDirectoryName).standardizedFileURL.path
    }

    /// The folder name Claude Code gives a working directory under `projects/`: every
    /// UTF-16 unit outside `[A-Za-z0-9]` becomes a hyphen. Longer names are cut at 200
    /// characters and end with a hash, which `matchesProjectDirectory` allows for.
    static func projectDirectoryName(for workingDirectory: String) -> String {
        String(String.UnicodeScalarView(workingDirectory.utf16.map { unit -> Unicode.Scalar in
            let isAlphanumeric = (0x30...0x39).contains(unit)
                || (0x41...0x5A).contains(unit)
                || (0x61...0x7A).contains(unit)
            return isAlphanumeric ? Unicode.Scalar(UInt8(unit)) : "-"
        }))
    }

    static func matchesProjectDirectory(_ name: String, workingDirectory: String) -> Bool {
        let encoded = projectDirectoryName(for: workingDirectory)
        if encoded.count <= maximumProjectNameLength {
            return name == encoded
        }
        return name.hasPrefix(encoded.prefix(maximumProjectNameLength) + "-")
    }

    /// Creates `~/.claude-<name>` and a `claude-<name>` alias in the shell file, as
    /// `claude-accounts add` does. Returns the new profile.
    static func createAccount(
        named rawName: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    ) throws -> CodexProfile {
        guard let name = accountName(rawName) else { throw ClaudeAccountError.invalidName }
        let directory = home.appending(path: "\(defaultDirectoryName)-\(name)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )

        let alias = "claude-\(name)"
        let hasAlias = [".zshrc", ".bashrc", ".bash_profile", ".zprofile"].contains { file in
            let text = (try? String(contentsOf: home.appending(path: file), encoding: .utf8)) ?? ""
            return text.range(of: #"(?m)^\s*alias\s+\#(alias)="#, options: .regularExpression) != nil
        }
        if hasAlias == false {
            let shellFile = home.appending(path: shell.hasSuffix("bash") ? ".bashrc" : ".zshrc")
            let line = "\n# Claude Code account, added by CodexMeter\nalias \(alias)='CLAUDE_CONFIG_DIR=\"$HOME/.\(alias)\" claude'\n"
            if let handle = try? FileHandle(forWritingTo: shellFile) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } else {
                try Data(line.utf8).write(to: shellFile)
            }
        }
        return CodexProfile(id: alias, displayName: alias, homeURL: directory, provider: .claude)
    }

    /// The name a new account can take, without the `claude-` prefix, or `nil`.
    static func accountName(_ rawName: String) -> String? {
        var name = rawName.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        return name.range(of: #"^[a-z0-9][a-z0-9-]{0,39}$"#, options: .regularExpression) == nil ? nil : name
    }

    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

enum ClaudeAccountError: Error, Equatable, LocalizedError {
    case invalidName

    var errorDescription: String? {
        "Use lowercase letters, digits and hyphens for the account name, such as work."
    }
}

enum ClaudeTimestamp {
    /// Parses the ISO 8601 timestamps Claude Code writes, with any number of fractional
    /// digits and either `Z` or a numeric offset.
    static func parse(_ value: String) -> Date? {
        var text = value
        var fraction = 0.0
        if let dot = text.firstIndex(of: ".") {
            let digitsStart = text.index(after: dot)
            let digitsEnd = text[digitsStart...].firstIndex(where: { ("0"..."9").contains($0) == false })
                ?? text.endIndex
            guard digitsEnd > digitsStart, let parsed = Double("0" + text[dot..<digitsEnd]) else {
                return nil
            }
            fraction = parsed
            text.removeSubrange(dot..<digitsEnd)
        }
        return ISO8601DateFormatter().date(from: text)?.addingTimeInterval(fraction)
    }
}
