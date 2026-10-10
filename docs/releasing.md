# Releasing EscapeOS

The shipping IPA is built by GitHub Actions. Nothing is built locally, and a `v*` tag is the only
thing that starts a run. A tag run either **reuses a successful build of the same commit** (no
recompilation — see step 5) or compiles from scratch; either way it ends by publishing the
GitHub Release. Each release carries **two** unsigned IPAs — a standard build and a tunnel build —
produced by a single compile (see step 6).

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

## 1. Bump the version in two places

Both must agree. A mismatch ships an app that reports one version and installs as another.

| File | Key(s) |
|---|---|
| `project.yml` | `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` |
| `Resources/Info.plist` | `CFBundleShortVersionString` and `CFBundleVersion` |

(The Theos `control` file used to be a third location. It was deleted along with the whole Theos
track, so `control` no longer exists.)

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
git add project.yml Resources/Info.plist CHANGELOG.md
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

## 3b. (Optional) Pre-flight validation — bump the version *first*

CI publishes the Release at tag time (step 7), so validation normally happens *after* the run. If you
nevertheless want to compile before tagging — to catch a build error early — run the build on the
**commit you are about to tag**, i.e. *after* steps 1–3:

```sh
gh workflow run build-xcode.yml --ref migrate-xcode
```

Then tag that same commit (step 4).

**Do not validate an earlier commit and bump the version afterwards.** The tag run decides reuse from
`CUR_HASH`, computed as

```sh
git ls-tree -r HEAD -- EscapeOS EscapeOSTunnel project.yml | shasum -a 256
```

which hashes `project.yml` **in full** — including the `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
lines. Bumping the version changes `CUR_HASH`, so a tag on the new commit can no longer reuse the
validation build and compiles from scratch a second time (this is the "two full builds per release"
waste).

Same commit ⇒ same `CUR_HASH` ⇒ the tag run finds the successful `workflow_dispatch` run by `headSha`
(artifacts are readable across runs), reuses its `escapeos-xcode-ipa`, and skips `xcode-build`
entirely.

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

A tag run has **two jobs**: `promote` and `xcode-build`.

- `promote` runs first. If a *successful* build of the same commit already exists (same source
  hash, artifact still inside its retention window), it reuses that build's IPA and publishes the
  Release itself — `xcode-build` is then skipped entirely and nothing is recompiled.
- Otherwise `xcode-build` compiles, packages, and publishes as usual.

So read the `promote` job's step summary first: it states either "已复用（跳过编译）" or
"未复用（走正常构建）".

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

If `xcode-build` was skipped (promote reused a build), there are no compile annotations to read —
inspect the `promote` job instead.

The workflow also uploads `xcodegen-and-build-logs` and `xcode-package-log` artifacts, as a
fallback when the job log itself cannot be fetched.

## 6. Confirm the artifact

```sh
gh release view v0.x.y --json assets --jq '.assets[]|"\(.name) \(.size)"'
```

Expected: **two** assets, one build of the app each:

- `EscapeSpace-0.x.y-xcode-unsigned.ipa` — the **standard** build. Its bundled
  `EscapeSpace.entitlements` has no Network Extension rights, so an ordinary certificate (free or
  paid) can sign it.
- `EscapeSpace-Tunnel-0.x.y-xcode-unsigned.ipa` — the **tunnel** build. It bundles
  `EscapeSpace-Tunnel.entitlements` on the app *and* `EscapeOSTunnel.entitlements` inside the
  embedded `.appex`, both granting `com.apple.developer.networking.networkextension`
  (`packet-tunnel-provider`).

The version in each file name comes from `MARKETING_VERSION`; if it does not match the tag, step 1
was done wrong.

Both IPAs come from a **single** compile — the two are byte-identical except for which entitlements
files travel inside the `.app`. Pick the standard one unless the tester needs the built-in tunnel.

### Signing the tunnel build

The tunnel build only works if the signer applies Network Extension rights to **both** binaries:

- The certificate/provisioning profile must include the `packet-tunnel-provider` capability. Most
  free and enterprise certificates do not; a personal developer certificate that has the capability
  does. A sideloader that ignores the bundled entitlements (and signs with a certificate lacking the
  capability) produces an app that launches but cannot start the tunnel.
- The signing tool must apply `EscapeOSTunnel.entitlements` to `PlugIns/EscapeOSTunnel.appex` as
  well as the app entitlements to the main binary. ESign/Sideloadly read the bundled
  `<name>.entitlements` files next to each binary; TrollStore applies entitlements via `ldid` and
  works on the supported iOS range only (TrollStore officially caps at iOS 17.0, while this app
  targets iOS 18.0 — see the double-version research brief).

## 7. Verify on a device

CI publishes the Release at tag time, so verification happens after the run, not before it. Install
the unsigned IPA with a sideloader (Sideloadly, ESign, TrollStore — the entitlements travel inside
the `.app` for this purpose) and confirm the build starts and the changed behaviour is actually
present.

Install the **standard** IPA by default. Use the **tunnel** IPA only to exercise the built-in
tunnel; if it installs but the tunnel will not start, the signer did not grant Network Extension
rights to both the app and the `.appex` (see step 6).

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
- `CHANGELOG.md` and the two version locations are edited by one person at a time. Two parallel
  tasks editing them will interleave, and one set of changes will be attributed to the wrong
  commit.
