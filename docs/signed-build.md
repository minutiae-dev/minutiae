# Building the signed macOS release

How to produce a **Developer-ID-signed, notarized, stapled** `Minutiae.app` (and
`.dmg`) that opens on any Mac with no Gatekeeper warnings.

Everything here is macOS-only and Apple-Silicon-only (`aarch64`, `minimumSystemVersion` 14.4).

## Why this isn't just `tauri build`

Tauri signs the `.app` at the end of its build. But the MLX **LLM sidecar**
(`minutiae-llm`, the "Enhance notes" feature) is *not* in `externalBin` — it and
its Metal shader `.bundle`s are injected into the bundle **after** Tauri builds,
which invalidates Tauri's signature. So the real flow is: let Tauri build and
ad-hoc-sign, then inject the sidecar, then **re-sign the whole bundle with
Developer ID and notarize it ourselves**. Tauri's own signing/notarization and
its `.dmg` never see the injected sidecar, so we don't use them.

(The audio **engine** sidecar, `minutiae-engine`, *is* in `externalBin` and is
rebuilt in release mode automatically by `beforeBuildCommand`.)

## One-time setup

### 1. Signing identity

You need a **Developer ID Application** certificate in your login keychain:

```sh
security find-identity -v -p codesigning
# → "Developer ID Application: Your Name (TEAMID)"
```

### 2. Credentials file: `.notarize.env`

Create `.notarize.env` in the repo root (it is gitignored). It sets the signing
identity and the notarization credentials. Both `sign-and-notarize.sh` and
`make-dmg.sh` source it automatically when `APPLE_SIGNING_IDENTITY` isn't
already exported, so you can run them directly — no `source` needed. Variables
already in the environment win, which is how CI supplies its own.

```sh
export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"

# Notarization — Apple ID method:
export APPLE_ID="you@example.com"
export APPLE_PASSWORD="abcd-efgh-ijkl-mnop"   # app-specific password (appleid.apple.com), NOT your login password
export APPLE_TEAM_ID="TEAMID"
```

Alternative to the Apple ID method — an App Store Connect **API key**:

```sh
export APPLE_API_KEY="XXXXXXXXXX"                    # Key ID
export APPLE_API_ISSUER="xxxxxxxx-xxxx-xxxx-..."     # Issuer ID
export APPLE_API_KEY_PATH="/absolute/path/AuthKey_XXXXXXXXXX.p8"
```

`sign-and-notarize.sh` prefers the API key if `APPLE_API_KEY` is set, otherwise
falls back to the Apple ID trio.

### 3. Toolchain PATH gotcha

`pnpm tauri build` shells out to `cargo`, which isn't always on a
non-interactive `PATH`. If you see `cargo metadata ... (os error 2)`:

```sh
export PATH="$HOME/.cargo/bin:$PATH"
```

## The build, step by step

From the repo root:

```sh
# 0. (once, and after any llm-engine change) build the slow MLX LLM sidecar
scripts/build-llm-sidecar.sh release          # → app/src-tauri/binaries/minutiae-llm (+ *.bundle metallibs)

# 1. build the app: rebuilds the engine sidecar (release) + frontend + Rust core,
#    produces an ad-hoc-signed Minutiae.app
export PATH="$HOME/.cargo/bin:$PATH"
pnpm build                                    # = pnpm --filter minutiae tauri build

# 2. inject the LLM sidecar, Developer-ID sign, notarize, staple
scripts/sign-and-notarize.sh                  # sources .notarize.env itself
                                              # SKIP_NOTARIZE=1 to sign only (fast iteration)

# 3. (optional) wrap the notarized .app in a notarized .dmg installer
scripts/make-dmg.sh                           # → ~/Desktop/Minutiae.dmg
```

Step 1's `beforeBuildCommand` runs `scripts/build-sidecar.sh release`, so the
audio engine (including anything you changed under `engine/`) is always rebuilt
in release mode — you do **not** need to build it separately.

The `minutiae-llm` sidecar (step 0) is slow to build (MLX / `xcodebuild`) and
rarely changes, so it's built once and stashed in `binaries/`. Rebuild it only
after changing the LLM engine.

### What `sign-and-notarize.sh` does

1. Runs `install-llm-into-app.sh` to place `minutiae-llm` in `Contents/MacOS` and
   the `*.bundle` metallibs in `Contents/Resources` (where `Bundle.module`
   resolves them — putting them next to the binary makes Metal init fail).
2. Signs, in order, each with **hardened runtime** (`--options runtime`) and a
   timestamp:
   - `minutiae-llm` with `Entitlements.llm.plist` (allow-jit +
     disable-library-validation for MLX/Metal),
   - `minutiae-engine` with `Entitlements.plist` (audio-input),
   - the `.app` last, with `Entitlements.plist`, which seals `Resources`.
   Nested-first, bundle-last is required or the seal is inconsistent.
3. `codesign --verify --deep --strict` and prints the signing authority.
4. Zips and submits to Apple's notary service with `notarytool ... --wait`.
5. `stapler staple` + `validate`, then `spctl -a -vv`.
6. Writes `~/Desktop/Minutiae-signed.zip` (the stapled ticket travels inside the
   `.app`).

### SaaS build variant

The paid SaaS build is the same pipeline with the `saas` feature and
`VITE_SAAS=1`, wrapped by one script:

```sh
scripts/release-saas.sh        # build-llm-sidecar → pnpm build:saas → sign-and-notarize → make-dmg
```

## Iterating on signing without notarizing

Notarization is a network submission that takes minutes. To iterate on
entitlements / signing only:

```sh
SKIP_NOTARIZE=1 scripts/sign-and-notarize.sh
```

This signs and runs `spctl` but skips submission/stapling. The result is **not**
distributable to other Macs (no notarization ticket).

## Verifying the result

```sh
APP="app/src-tauri/target/release/bundle/macos/Minutiae.app"

codesign --verify --deep --strict --verbose=2 "$APP"   # signature seal
codesign -dvv "$APP" 2>&1 | grep Authority             # Developer ID, not "adhoc"
xcrun stapler validate "$APP"                           # notarization ticket present
spctl -a -vv "$APP"                                     # → "accepted", "source=Notarized Developer ID"
```

A correctly built app shows `source=Notarized Developer ID` and `accepted` from
`spctl`. If `spctl` says `rejected` or the authority is `adhoc`, the notarize/sign
step didn't complete.

## Distributing

Share `~/Desktop/Minutiae.dmg` (or `Minutiae-signed.zip`). Because the ticket is
stapled, it validates offline — recipients don't need to clear quarantine and get
no Gatekeeper warning.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `cargo metadata ... (os error 2)` during `pnpm build` | `cargo` not on PATH → `export PATH="$HOME/.cargo/bin:$PATH"` |
| `error: app not found` from sign script | Run `pnpm build` first; or pass the `.app` path as `$1` |
| `minutiae-llm missing` | Run `scripts/build-llm-sidecar.sh release` (step 0) |
| "the language model stopped unexpectedly" in the packaged app | metallib `.bundle`s landed in `Contents/MacOS` instead of `Contents/Resources` — `install-llm-into-app.sh` handles this; don't hand-copy |
| App "is damaged" on another Mac | Bundle modified after signing, or ad-hoc only (not Developer ID) — re-run `sign-and-notarize.sh` |
| `spctl` says `rejected` | Not notarized/stapled — check the `notarytool` verdict in the script output |
| notary submission `Invalid` | `xcrun notarytool log <submission-id> --apple-id ...` to see which binary lacked hardened runtime / a valid signature |

## Reference

- `scripts/build-llm-sidecar.sh` — build the MLX LLM sidecar (`[release]`)
- `scripts/build-sidecar.sh` — build the audio engine sidecar (`[release]`); run by `beforeBuildCommand`
- `scripts/install-llm-into-app.sh` — inject the LLM sidecar into a built `.app`
- `scripts/sign-and-notarize.sh` — inject + Developer-ID sign + notarize + staple
- `scripts/make-dmg.sh` — notarized `.dmg` around the signed `.app`
- `scripts/release-saas.sh` — full SaaS release chain
- `app/src-tauri/Entitlements.plist` — app + engine entitlements (audio-input)
- `app/src-tauri/Entitlements.llm.plist` — LLM sidecar entitlements (jit, library-validation)
- `.notarize.env` — signing identity + notary credentials (gitignored)
