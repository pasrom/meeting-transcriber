## What changed and why

<!-- One or two lines. Link the issue if there is one. -->

## Checklist

- [ ] Rebased on `main`, no merge commits, since a merge commit pulls commits that are
      already on `main` into this branch and the review reads it commit by commit:
      `git fetch https://github.com/pasrom/meeting-transcriber main && git rebase FETCH_HEAD`
      (the URL spelled out because in a fork clone `origin` is your fork)
- [ ] `./scripts/lint.sh` is clean
- [ ] Tests pass: `cd app/MeetingTranscriber && swift test`
- [ ] Conventional Commits, one logical change per commit

The **Update branch** button merges by default; pick **Update with rebase** from its
dropdown instead. Would rather not rewrite history? Leave *Allow edits by maintainers*
checked and a maintainer folds the commits before merging, as
[CONTRIBUTING.md](https://github.com/pasrom/meeting-transcriber/blob/main/CONTRIBUTING.md)
offers.
