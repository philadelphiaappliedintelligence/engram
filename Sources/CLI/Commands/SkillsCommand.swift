import ArgumentParser
import Engram
import Foundation

struct Skills: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage skills",
        subcommands: [SkillsList.self, SkillInstall.self, SkillUninstall.self],
        defaultSubcommand: SkillsList.self
    )
}

struct SkillsList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List installed skills")

    func run() async throws {
        let loader = SkillLoader(); loader.loadAll()
        let skills = loader.all
        if skills.isEmpty {
            print("No skills installed.")
            print("  Install: engram skills install user/repo")
            print("  Create:  ~/.engram/skills/<name>/SKILL.md")
            return
        }
        print("\(bold("Skills")) (\(skills.count))\n")
        for skill in skills {
            let auto = skill.metadata.autoLoad ? " \(cyan("[auto]"))" : ""
            let tags = skill.metadata.tags.isEmpty ? "" : dim(" (\(skill.metadata.tags.joined(separator: ", ")))")
            print("  \(bold(skill.metadata.name))\(auto)\(tags)")
            print("    \(skill.metadata.description)")
        }
    }
}

struct SkillInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install", abstract: "Install a skill from GitHub")
    @Argument(help: "GitHub repo: user/repo or URL") var source: String

    func run() async throws {
        print("Installing skill from \(source)...")
        do {
            let name = try SkillHub.install(source: source)
            print("Installed: \(bold(name))")
            let loader = SkillLoader(); loader.loadAll()
            if let skill = loader.get(name) { print("  \(skill.metadata.description)") }
        } catch { print(red("Failed: \(error.localizedDescription)")) }
    }
}

struct SkillUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Remove a skill")
    @Argument(help: "Skill name") var name: String

    func run() async throws {
        do {
            if try SkillHub.uninstall(name: name) { print("Removed: \(name)") }
            else { print("Skill not found: \(name)") }
        } catch { print(red("Failed: \(error.localizedDescription)")) }
    }
}
