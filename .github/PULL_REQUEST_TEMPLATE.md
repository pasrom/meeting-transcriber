## Summary

<!-- 1-3 bullets: what changes, why now. Drop the why if obvious from the title. -->

-

## Behavioural deltas worth flagging

<!-- New TCC prompts, breaking config changes, performance regressions, anything a user/reviewer
     should know that isn't obvious from the diff. Delete this section if there are none. -->

-

## Test plan

<!-- Tick off what was actually run locally before pushing. CI matrix is the catch-all last item. -->

- [ ] `swift build` (Homebrew variant) — clean
- [ ] `swift build -Xswiftc -DAPPSTORE` — clean
- [ ] `swift test --parallel --skip MenuBarIconSnapshotTests`
- [ ] `./scripts/lint.sh` — 0 violations
- [ ] CI matrix green
