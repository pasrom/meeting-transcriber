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
    /// ordinary run fired the user's hooks and could quote their global
    /// `CLAUDE.md`; with `CLAUDE_CODE_SAFE_MODE=1` it fired none and did not
    /// see that file. MCP servers were already off before this, through
    /// `--strict-mcp-config` in `noToolsArguments`.
    ///
    /// The variable rather than `--safe-mode`, which sets it: an
    /// environment variable a CLI does not know is ignored, while an unknown
    /// option fails the run, so the variable needs neither a `--help` probe
    /// nor a fallback. Safe mode keeps the user's own routing: measured with
    /// CLI 2.1.328 and the protocol run's tool and model arguments, with no
    /// key in the environment, a run with the variable set skipped a
    /// `SessionStart` hook from `settings.json` but still sent its requests
    /// to the `ANTHROPIC_BASE_URL` of that file's `env` block, carrying the
    /// key its `apiKeyHelper` printed. The CLI's help states that sign-in
    /// and model selection keep working in safe mode, so a CLI signed in
    /// through the user's login or a key passed in by `buildEnvironment`
    /// still runs too. Bedrock and Vertex variables in that `env` block were
    /// not tried.
    extension ClaudeCLIProtocolGenerator {
        static let safeModeVariable = "CLAUDE_CODE_SAFE_MODE"
    }

#endif
