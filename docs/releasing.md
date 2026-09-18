# Releasing EscapeOS

The shipping IPA is built by GitHub Actions. Nothing is built locally, and a `v*` tag is the only
thing that starts a build. Pushing the tag is what produces, in one run, the unsigned IPA and the
GitHub Release.

Follow the steps in order.

---

## The one rule that matters most

**Never re-push a tag that already exists on the remote.**

A release is identified by its version number. If you move a tag or re-upload an asset under the
same version, everyone who already downloaded it keeps a different binary under the same number —
including the person testing for you, who will then report behaviour from a build you no longer
have. Once a version has shipped, the next build gets the **next version number**, always.

Force-updating a *local* tag that has never been pushed is fine (`git tag -f`). Force-pushing a
tag that is already on the remote is not.

---

## Before you start

- `.github/workflows/build-xcode.yml` is the **only** workflow in the tree. A `v*` tag therefore
  starts exactly one workflow.
- You need push access to `AmorCool/EscapeOS` and the development branch is `migrate-xcode`.
- Version numbers only ever increase within `0.x.y`.

Set up a token for the `gh` commands below:

```sh
export GH_TOKEN=$(git remote get-url origin | sed -E 's|.*//([^@]+)@.*|\1|' | sed 's/^[^:]*://')
```

---

## 1. Bump the version in three places

All three must agree. A mismatch ships an app that reports one version and installs as another.

| File | Key(s) |
|---|---|
| `control` | `Version:` |
| `project.yml` | `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` |
| `Resources/Info.plist` | `CFBundleShortVersionString` and `CFBundleVersion` |

- `MARKETING_VERSION` must equal `CFBundleShortVersionString` — this is the `<version>` in the IPA
  file name and the tag.
- `CURRENT_PROJECT_VERSION` must equal `CFBundleVersion` — the build number. Increment it on every
  release, even a re-cut of the same marketing version.

## 2. Add the CHANGELOG entry

Put a new section at the top of `CHANGELOG.md`:

```markdown
## [0.x.y] - YYYY-MM-DD
```

Describe what changed and why. If a fix came from a device log, quote the relevant lines — that is
what makes a later "did we already fix this?" question answerable.

## 3. Commit and push

Stage only the files this release touches. Do **not** use `git add -A`: it sweeps up other work in
progress and other people's uncommitted changes.

```sh
git add control project.yml Resources/Info.plist CHANGELOG.md
git commit -m "v0.x.y"
git push origin migrate-xcode
```

Then confirm the commit really landed on the remote. A tag pointing at a commit the remote never
received produces a build of the *previous* code, and the resulting "it still fails" report is
about a version you never shipped.

```sh
git ls-remote origin refs/heads/migrate-xcode
git rev-parse HEAD
```

The two hashes must match.

## 4. Tag and push the tag

```sh
git tag -f v0.x.y
git push origin v0.x.y
git ls-remote origin refs/tags/v0.x.y
```

- `git tag -f` moves a local tag that already exists. Use it when you tagged the wrong commit
  locally and have not pushed yet.
- The push may fail with an HTTP 500; retry it. The tag is not created until the push succeeds.
- Always finish with `git ls-remote` and confirm the tag exists on the remote.

## 5. Watch the run

Look the run up by commit SHA — the run-list API is heavily cached and will otherwise return a
stale run:

```sh
SHA=$(git rev-parse HEAD)
RID=$(gh api "repos/AmorCool/EscapeOS/actions/runs?head_sha=$SHA" --jq '.workflow_runs[0].id')
gh api "repos/AmorCool/EscapeOS/actions/runs/$RID" --jq '"\(.status)/\(.conclusion)"'
```

On failure, find the step first, then read the annotations, which carry the file, line, and
compiler message:

```sh
gh api "repos/AmorCool/EscapeOS/actions/runs/$RID/jobs" \
  --jq '.jobs[]|.steps[]|select(.conclusion=="failure")|.name'

CUR=$(gh api "repos/AmorCool/EscapeOS/actions/runs/$RID/jobs" \
  --jq '.jobs[]|select(.name=="xcode-build")|.check_run_url' | sed 's|.*/||')
gh api "repos/AmorCool/EscapeOS/check-runs/$CUR/annotations" \
  --jq '.[]|select(.annotation_level=="failure")|"\(.path):\(.start_line) \(.message)"'
```

The workflow also uploads `xcodegen-and-build-logs` and `xcode-package-log` artifacts, as a
fallback when the job log itself cannot be fetched.

## 6. Confirm the artifact

```sh
gh release view v0.x.y --json assets --jq '.assets[]|"\(.name) \(.size)"'
```

Expected: a single asset named `EscapeSpace-0.x.y-xcode-unsigned.ipa`. The version in the file
name comes from `MARKETING_VERSION`; if it does not match the tag, step 1 was done wrong.

## 7. Verify on a device

CI publishes the Release at tag time, so verification happens after the run, not before it. Install
the unsigned IPA with a sideloader (Sideloadly, ESign, TrollStore — the entitlements travel inside
the `.app` for this purpose) and confirm the build starts and the changed behaviour is actually
present.

If verification fails, fix the code and go back to step 1 with a **new** version number.

## 8. Deliver the download link

```sh
gh release view v0.x.y --json url --jq '.url'
```

Send that link out as soon as the build is green. Do not batch it with the next release: a tester
who is still on the previous build reports the previous build's bugs.

---

## Failure handling

**Upload or artifact failure is not a build failure.** If the annotations show only an
infrastructure error such as `Failed to FinalizeArtifact: ETIMEDOUT` while the build and package
steps succeeded, do **not** re-push the tag. Re-run the failed jobs in place:

```sh
gh api -X POST "repos/AmorCool/EscapeOS/actions/runs/$RID/rerun-failed-jobs"
```

**Compilation failure.** Fix the source, bump to a new version, and tag again. Never reuse the
version that failed, and never move a tag that was already pushed.

**A tag was pushed before its commit.** Push the commit, then re-run the workflow. If the run
already failed for that reason, the cleanest fix is still a new version number.

---

## Notes

- The Xcode workflow listens only on `v*`. Branch pushes do not build, so a mistake caught after
  pushing to `migrate-xcode` costs nothing until you tag.
- If a second `v*`-tag workflow is ever added (a Theos or MHA track), remember it would publish a
  second, differently built IPA into the same Release.
- `CHANGELOG.md` and the three version locations are edited by one person at a time. Two parallel
  tasks editing them will interleave, and one set of changes will be attributed to the wrong
  commit.
