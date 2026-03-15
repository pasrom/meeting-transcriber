# Contributing

## Prerequisites

- macOS 14.2+
- Xcode 16+ (Swift toolchain)
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (for protocol generation)

## Setup

```bash
git clone https://github.com/pasrom/meeting-transcriber
cd meeting-transcriber
./scripts/run_app.sh
```

Run the tests to verify everything works:

```bash
cd app/MeetingTranscriber && swift test
```

## Development workflow

### Branching

Create a feature branch from `main`:

```bash
git checkout -b feat/my-feature main
```

**Always rebase, never merge:**

```bash
git fetch origin
git rebase origin/main
```

### Commit conventions

Follow [Conventional Commits](https://www.conventionalcommits.org/). See [`CLAUDE.md`](CLAUDE.md) for the types, scopes, and rules used in this project.

Examples:

```
feat(app): add Webex meeting detection
fix(app): prevent duplicate recording on reconnect
test(app): add WhisperKitEngine concurrency tests
```

### AI-assisted development

The project includes a [`CLAUDE.md`](CLAUDE.md) with full architecture context. If you use [Claude Code](https://docs.anthropic.com/en/docs/claude-code), we recommend the [`/git-workflow` skill](https://github.com/pasrom/dotclaude/blob/main/skills/git-workflow/SKILL.md) for commit creation — install it via the [dotclaude](https://github.com/pasrom/dotclaude) collection.

### Tests

All new features and bug fixes must include tests. Run the full test suite before submitting:

```bash
cd app/MeetingTranscriber && swift test
```

## Submitting a PR

1. One PR per feature, bug fix, or refactor — keep it focused
2. Rebase your branch onto `main` before opening the PR
3. Ensure all tests pass
4. Write a clear PR description: what changed and why
5. Link related issues if applicable

## Reporting issues

Use [GitHub Issues](https://github.com/pasrom/meeting-transcriber/issues) to report bugs or request features.

## Code style

- All code and UI text in English
- Keep it simple — avoid over-engineering and premature abstractions
- See [`CLAUDE.md`](CLAUDE.md) for architecture conventions

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
