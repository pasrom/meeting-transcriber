#if !APPSTORE

    import Foundation

    /// Starting the CLI with no tools and no MCP servers.
    ///
    /// The prompt carries the transcript, which is untrusted text: anything
    /// said in a meeting, or anything in an imported file. Left to itself the
    /// CLI session gets the user's full tool set, shell included, and every
    /// MCP server the user configured, so a sentence in the meeting could ask
    /// the model to use them. Writing a protocol is text in, text out and
    /// needs no tool. `--tools ""` removes every built-in tool and
    /// `--strict-mcp-config` drops every MCP server not given with
    /// `--mcp-config`, which this app passes none of. Neither changes which
    /// settings, credentials or environment the CLI reads, so a CLI routed
    /// through the user's own settings (API key, proxy) keeps working.
    ///
    /// A CLI older than these options refuses them as unknown. Unlike
    /// `noSessionPersistenceFlag`, there is no second run without them: that
    /// run would hand the transcript to an unrestricted session, which is
    /// what the options are there to prevent, and a fallback nobody sees
    /// would quietly undo it. The run fails instead, with a message asking
    /// for a newer CLI. `--disallowedTools` is no substitute either: it can
    /// only name tools known in advance, not whatever MCP servers a user has.
    extension ClaudeCLIProtocolGenerator {
        /// The empty tool list is an argument of its own. `--tools` takes a
        /// variadic list, so it must be followed by another option or end
        /// the arguments, never by the prompt.
        static let noToolsArguments = ["--tools", "", "--strict-mcp-config"]

        /// Whether a run given the restriction was refused it.
        static func rejectedToolRestriction(stderr: String, message: String, arguments: [String]) -> Bool {
            ["--tools", "--strict-mcp-config"].contains { option in
                rejectedOption(option, stderr: stderr, message: message, arguments: arguments)
            }
        }

        /// The message for a run whose CLI refused the restriction, ending
        /// with what the CLI itself reported.
        static func toolRestrictionRejectedMessage(_ cliMessage: String) -> String {
            "This Claude CLI cannot start a session without tools (it does not know --tools or "
                + "--strict-mcp-config), so no protocol was generated. "
                + "Update the Claude CLI and try again. The CLI said: \(cliMessage)"
        }
    }

#endif
