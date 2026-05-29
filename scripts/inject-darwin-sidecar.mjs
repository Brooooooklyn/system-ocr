// Inject the macOS Swift sidecar dylib into the per-platform npm packages.
//
// Publish flow (see .github/workflows/CI.yml `publish` job):
//   1. `napi create-npm-dirs`  -> creates npm/<platform-arch>/package.json
//   2. `napi artifacts`        -> moves the *.node binaries into those dirs
//   3. THIS SCRIPT             -> copies librecognize_documents.dylib next to
//                                 each darwin .node and adds it to that
//                                 package's `files` allow-list
//   4. `napi prepublish`       -> runs `npm publish` inside each npm/<dir>
//
// `napi create-npm-dirs` generates `files: ["system-ocr.<triple>.node"]` and
// `napi artifacts` only writes the .node — neither knows about the Swift
// sidecar, so without this step the dylib would never be packed. The runtime
// loader (src/macos/documents.rs) dlopens the dylib from the .node's own
// directory via `dladdr`, so co-locating the two files inside the platform
// package is all that is required.
//
// The dylib is darwin / macOS-26-only: on a build whose SDK predated
// RecognizeDocumentsRequest, build.rs emits no dylib and the artifact is
// absent. That is tolerated on ordinary commits (the package just ships
// without the structured-document path and falls back to VNRecognizeTextRequest
// at runtime) but is a hard error on release commits, which must not publish a
// half-built Darwin package.

import { execSync } from 'node:child_process'
import { copyFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'

const DYLIB = 'librecognize_documents.dylib'

// npm platform-arch dir -> cargo target triple used in the artifact name.
const DARWIN_TARGETS = {
  'darwin-arm64': 'aarch64-apple-darwin',
  'darwin-x64': 'x86_64-apple-darwin',
}

// Overridable so the script is testable outside CI.
const npmDir = process.env.NAPI_NPM_DIR ?? 'npm'
const artifactsDir = process.env.NAPI_ARTIFACTS_DIR ?? 'artifacts'

function isReleaseCommit() {
  try {
    const message = execSync('git log -1 --pretty=%B', { encoding: 'utf8' }).trim()
    // Mirrors the publish step's release detection: a leading semver tag
    // (optionally `v`-prefixed) marks a release/prerelease commit.
    return /^v?\d+\.\d+\.\d+/m.test(message)
  } catch {
    return false
  }
}

// Strict mode refuses to publish a Darwin package without its sidecar. Default
// to the release-commit heuristic; allow an explicit override for tests/CI.
function resolveStrict() {
  const override = process.env.SYSTEM_OCR_REQUIRE_SIDECAR
  if (override === '1' || override === 'true') return true
  if (override === '0' || override === 'false') return false
  return isReleaseCommit()
}

const strict = resolveStrict()
let injected = 0
const missing = []

for (const [platformDir, triple] of Object.entries(DARWIN_TARGETS)) {
  const pkgDir = join(npmDir, platformDir)
  const pkgJsonPath = join(pkgDir, 'package.json')
  // `create-npm-dirs` only emits packages for configured targets; skip any
  // darwin target that is not part of this build.
  if (!existsSync(pkgJsonPath)) {
    continue
  }

  const src = join(artifactsDir, `bindings-${triple}`, DYLIB)
  if (!existsSync(src)) {
    missing.push({ platformDir, src })
    continue
  }

  copyFileSync(src, join(pkgDir, DYLIB))
  const pkg = JSON.parse(readFileSync(pkgJsonPath, 'utf8'))
  pkg.files = Array.from(new Set([...(pkg.files ?? []), DYLIB]))
  writeFileSync(pkgJsonPath, `${JSON.stringify(pkg, null, 2)}\n`)
  injected += 1
  console.log(`Injected ${DYLIB} into ${platformDir} (files: ${pkg.files.join(', ')})`)
}

for (const { platformDir, src } of missing) {
  const detail = `No ${DYLIB} for ${platformDir} (expected ${src})`
  if (strict) {
    console.error(`::error::${detail}; refusing to publish Darwin package without it`)
  } else {
    console.warn(`::warning::${detail}; a real release on this commit would fail`)
  }
}

console.log(`Sidecar injection: ${injected} injected, ${missing.length} missing (strict=${strict}).`)

if (strict && missing.length) {
  process.exit(1)
}
