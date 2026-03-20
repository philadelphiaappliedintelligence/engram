import Foundation

/// Install skills from GitHub repositories.
/// Skills are cloned into ~/.engram/skills/ and auto-discovered by SkillLoader.
public enum SkillHub {

    private static var skillsDir: URL {
        AgentConfig.configDir.appendingPathComponent("skills")
    }

    /// Install a skill from a GitHub URL or shorthand (user/repo).
    /// Supports:
    ///   - github.com/user/repo
    ///   - https://github.com/user/repo
    ///   - user/repo (shorthand)
    ///   - user/repo#subdirectory (specific skill in monorepo)
    public static func install(source: String) throws -> String {
        let (repoURL, subdir) = parseSource(source)

        let fm = FileManager.default
        try? fm.createDirectory(at: skillsDir, withIntermediateDirectories: true)

        // Derive skill name from repo
        let repoName = URL(string: repoURL)?.lastPathComponent
            .replacingOccurrences(of: ".git", with: "") ?? "skill"
        let skillName = subdir ?? repoName
        let destDir = skillsDir.appendingPathComponent(skillName)

        // Remove existing if present
        try? fm.removeItem(at: destDir)

        if let subdir {
            // Clone to temp, copy subdirectory
            let tempDir = fm.temporaryDirectory.appendingPathComponent("engram_skill_\(UUID().uuidString)")
            defer { try? fm.removeItem(at: tempDir) }

            let result = shell("git clone --depth 1 '\(repoURL)' '\(tempDir.path)' 2>&1")
            guard result.status == 0 else {
                throw SkillHubError.cloneFailed(result.output)
            }

            let srcDir = tempDir.appendingPathComponent(subdir)
            guard fm.fileExists(atPath: srcDir.path) else {
                throw SkillHubError.subdirNotFound(subdir)
            }

            try fm.copyItem(at: srcDir, to: destDir)
        } else {
            let result = shell("git clone --depth 1 '\(repoURL)' '\(destDir.path)' 2>&1")
            guard result.status == 0 else {
                throw SkillHubError.cloneFailed(result.output)
            }

            // Remove .git directory to save space
            try? fm.removeItem(at: destDir.appendingPathComponent(".git"))
        }

        // Verify SKILL.md exists
        let skillFile = destDir.appendingPathComponent("SKILL.md")
        if !fm.fileExists(atPath: skillFile.path) {
            // Check if there's a README.md we can use
            let readme = destDir.appendingPathComponent("README.md")
            if fm.fileExists(atPath: readme.path) {
                try? fm.copyItem(at: readme, to: skillFile)
            }
        }

        return skillName
    }

    /// List installed skills with their source info.
    public static func listInstalled() -> [(name: String, path: String)] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: skillsDir, includingPropertiesForKeys: nil
        ) else { return [] }

        return contents.compactMap { url -> (name: String, path: String)? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            return (name: url.lastPathComponent, path: url.path)
        }.sorted { $0.name < $1.name }
    }

    /// Remove an installed skill.
    public static func uninstall(name: String) throws -> Bool {
        let dir = skillsDir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        try FileManager.default.removeItem(at: dir)
        return true
    }

    // MARK: - Private

    private static func parseSource(_ source: String) -> (url: String, subdir: String?) {
        var s = source.trimmingCharacters(in: .whitespaces)
        var subdir: String?

        // Extract #subdirectory
        if let hashIdx = s.firstIndex(of: "#") {
            subdir = String(s[s.index(after: hashIdx)...])
            s = String(s[..<hashIdx])
        }

        // Normalize to full URL
        if s.hasPrefix("https://") || s.hasPrefix("git@") {
            return (s, subdir)
        }
        if s.hasPrefix("github.com/") {
            return ("https://\(s)", subdir)
        }
        // Shorthand: user/repo
        if s.contains("/") && !s.contains(":") {
            return ("https://github.com/\(s).git", subdir)
        }

        return (s, subdir)
    }

    private static func shell(_ command: String) -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = pipe
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

public enum SkillHubError: Error, LocalizedError {
    case cloneFailed(String)
    case subdirNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .cloneFailed(let msg): return "Git clone failed: \(msg)"
        case .subdirNotFound(let dir): return "Subdirectory not found: \(dir)"
        }
    }
}
