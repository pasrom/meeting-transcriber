# Contributing

## Prerequisites

- macOS 14.2+ to run the app (the audio tap needs it)
- Xcode 26+ to build it. Every package manifest declares `swift-tools-version: 6.2`, which arrived with Swift 6.2 in Xcode 26; an older Xcode fails on the manifest before it compiles anything.
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) (for protocol generation)

If you run `./scripts/lint.sh`, you also need SwiftLint and SwiftFormat 0.62.0 or
newer; the format config disables rules older versions do not recognise and will
reject outright. CI pins exact versions, listed in `scripts/tool-versions.sh`, and
`lint.sh` warns when your local ones differ.

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

**Fold review changes into the commit they belong to.** This project
rebase-merges only (squash is disabled), so every commit on your branch lands on
`main` verbatim; nothing is collapsed at merge time. The merged history must stay
atomic: one logical change per commit, with no separate "address review" commits.

- **While review is ongoing**, push review responses as `fixup!` commits so
  reviewers can see what changed since their last pass:

  ```bash
  git commit --fixup=<sha>   # find the sha with: git log --oneline origin/main..
  ```

  (Single-commit PR? `git commit --amend` plus a force-push is fine too.)

- **Once review has settled** (or when a maintainer asks), fold the fixups into
  their target commits and update the branch:

  ```bash
  git fetch origin
  git rebase --autosquash origin/main
  git push --force-with-lease
  ```

Not comfortable rewriting history? Leave **"Allow edits by maintainers"** checked
(it is on by default) and a maintainer will fold the commits before merging. If we
do, resync your local branch with `git fetch origin && git reset --hard
origin/<your-branch>` instead of pushing again.

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
6. Before merge, fold any review-fix commits into the commit they belong to (see [Commit conventions](#commit-conventions))

## Reporting issues

Use [GitHub Issues](https://github.com/pasrom/meeting-transcriber/issues) to report bugs or request features.

## Code style

- All code and UI text in English
- Keep it simple — avoid over-engineering and premature abstractions
- See [`CLAUDE.md`](CLAUDE.md) for architecture conventions

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
