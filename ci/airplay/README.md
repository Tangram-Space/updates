# AirPlay signing helpers for hosted Actions

These helpers prepare and verify release files. They do not create a signing
key, install AirPlay, upload an asset, or publish an appcast. They deliberately
run only on an Intel macOS GitHub-hosted runner for `Tangram-Space/updates`.

## Reviewed validation core

`release_core.py` is an exact byte copy of the AirPlay project's
`scripts/update_release.py` as supplied with the 1.3.2/build 6 candidate:

```
SHA256 f6a15523085d6e2ca2756a5a1dfe3f4591126c8c72e0dab3cc86169c3bf11dc4
```

`sparkle_signing.py` verifies that SHA before importing the core. It preserves
the core's archive pin, bundle checks, minimum macOS version, increasing build
number, enclosure URL/size, archive signature and signed-feed verification.
It replaces only the subprocess transport and the source of the already
verified public key. The copied core's original configuration/key-generation
entry points are not used by these wrappers.

When the project's release validation changes, review and copy the new core
explicitly, update `CORE_SHA256`, and review the transport call contract again.
Do not update that hash automatically or maintain two independently edited
release algorithms.

## Secret boundary

Provision `AIRPLAY_SPARKLE_PRIVATE_KEY` as an Actions secret separately. Its
value is the canonical Base64 export produced by Sparkle `generate_keys -x`:
the current 32-byte seed format or its supported older 96-byte format. Do not
put it in workflow arguments, public variables, source files or build artifacts.

Each invocation removes the variable from its environment before launching
tools. An official `generate_keys -f` import into a private, temporary runner
Keychain and `generate_keys -p` lookup derive the real public key. The import
file is mode 0600 and removed after use. The runner's previous default Keychain
and search list are restored. The ephemeral Keychain password is a different
value from the signing key; it is passed to Apple's `security` command without
printing command arguments.

Archive and appcast signing/verification use the official
`--ed-key-file -` stdin interface. Child stdout/stderr are captured and never
forwarded on failure because Sparkle can include malformed private input in an
error. No private input is included in an exception or release output. The
helpers do not claim secure erasure of Python process memory or protection
against forcible runner termination; the hosted runner must be ephemeral.

## Commands

First derive and verify the public configuration from the existing secret,
before spending time on the build:

```sh
python3 configure-from-secret.py \
  --sparkle-archive "$SPARKLE_ARCHIVE" \
  --feed-url https://raw.githubusercontent.com/Tangram-Space/updates/main/feeds/airplay/stable/appcast.xml \
  --output "$PUBLIC_CONFIG"
```

An existing configuration must match exactly; the helper refuses silent key
rotation. It prints only the public key and public configuration path.

After the build-only report and its allowlisted outputs pass collection:

```sh
python3 sign-release.py \
  --preparation-report "$AIRPLAY_PREPARATION_JSON" \
  --config "$PUBLIC_CONFIG" \
  --sparkle-archive "$SPARKLE_ARCHIVE" \
  --download-url-prefix https://github.com/Tangram-Space/updates/releases/download/airplay-v1.3.2-b6/ \
  --output "$AIRPLAY_CI_SIGNED_OUTPUT"
```

For a later release, also pass `--previous-appcast` pointing to the current
feed copied into `RUNNER_TEMP`. Its signature is verified before parsing and
its highest build must be lower. The download tag is always
`airplay-v<VERSION>-b<BUILD>`. The output directory must be new and inside
`RUNNER_TEMP`.

Successful output contains exactly the signed-release ZIP, `appcast.xml` and
`release.json`. The release core packs and verifies the ZIP from the prepared
bundle; publish this final ZIP, whose hash is in `release.json`, rather than
the earlier unsigned preparation ZIP. `published` remains false. Publish the
ZIP first, then the exact signed appcast bytes in a separate authorized step.

## Tool pin and validation limits

The complete official Sparkle 2.9.6 archive must match SHA256
`52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192`
before extraction. The core verifies the included native code signatures and
framework version before invoking its tools.

Primary source for the supported key transport:

- [Sparkle 2.9.6 generate_keys](https://github.com/sparkle-project/Sparkle/blob/2.9.6/generate_keys/main.swift)
- [Sparkle 2.9.6 sign_update](https://github.com/sparkle-project/Sparkle/blob/2.9.6/sign_update/main.swift)
- [Sparkle 2.9.6 generate_appcast](https://github.com/sparkle-project/Sparkle/blob/2.9.6/generate_appcast/main.swift)

Local checks covered Python syntax, the copied core hash, invalid-input
rejection, stdin routing, suppression of echoed tool errors, restoration
control flow and rejection outside the intended runner. They used stubs and a
deliberately unusable marker; no signing key was generated. Native Keychain,
Sparkle execution, the macOS build and end-to-end update installation still
require their actual macOS/Actions run.

Only the four top-level Python helpers are needed in CI. `research/` and `qa/`
are review inputs and fixtures, not release artifacts.
