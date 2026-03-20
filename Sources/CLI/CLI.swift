import ArgumentParser
import Engram
import Foundation

@main
struct EngramCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "engram",
        abstract: "AI agent with holographic memory",
        subcommands: [Chat.self, Login.self, ModelCmd.self, Setup.self,
                      Memory.self, Sessions.self, Skills.self,
                      GatewayCmd.self, DaemonCmd.self, IdentityCmd.self],
        defaultSubcommand: Chat.self
    )
}
