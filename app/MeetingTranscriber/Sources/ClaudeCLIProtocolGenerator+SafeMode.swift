#if !APPSTORE

    import Foundation

    /// Starting the CLI without the user's own Claude Code customizations.
    ///
    /// Left to itself the CLI loads everything the user set up for their own
    /// sessions: the global `CLAUDE.md`, hooks, skills and plugins. A
    /// protocol run is not one of their sessions, but it got all of that
    /// anyway. Hooks run their commands on every protocol and can inject text
    /// into the context, and `CLAUDE.md` goes into the context as
    /// instructions, so a reminder written for the user's coding sessions
    /// showed up in a meeting's protocol. Measured with CLI 2.1.285: an
    /// ordinary run fired 38 hook events and could quote the user's global
    /// `CLAUDE.md`; with `CLAUDE_CODE_SAFE_MODE=1` it fired none, did not
    /// see that file, and connected no MCP server.
    ///
    /// The variable rather than `--safe-mode`, which sets it: an
    /// environment variable a CLI does not know is ignored, while an unknown
    /// option fails the run, so the variable needs neither a `--help` probe
    /// nor a fallback. The CLI's help states that sign-in, model selection
    /// and admin-managed policy settings keep working in safe mode, so a CLI
    /// authenticated through the user's own login, or a key passed in by
    /// `buildEnvironment`, still runs.
    extension ClaudeCLIProtocolGenerator {
        static let safeModeVariable = "CLAUDE_CODE_SAFE_MODE"
    }

#endif
