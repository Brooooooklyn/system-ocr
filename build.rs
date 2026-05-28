extern crate napi_build;

fn main() {
  napi_build::setup();

  #[cfg(target_os = "macos")]
  compile_swift();

  // Allow the custom cfg flag on all platforms
  println!("cargo:rustc-check-cfg=cfg(has_recognize_documents)");
}

#[cfg(target_os = "macos")]
fn compile_swift() {
  let out_dir = std::env::var("OUT_DIR").unwrap();
  let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
  let swift_src = format!("{manifest_dir}/src/macos/recognize_documents.swift");

  if !std::path::Path::new(&swift_src).exists() {
    return;
  }

  let arch = std::env::var("CARGO_CFG_TARGET_ARCH").unwrap();
  let target_arch = match arch.as_str() {
    "x86_64" => "x86_64",
    "aarch64" => "arm64",
    _ => {
      eprintln!("cargo:warning=Unsupported architecture for Swift bridge: {arch}");
      return;
    }
  };
  println!("cargo:rerun-if-env-changed=MACOSX_DEPLOYMENT_TARGET");
  let deployment_target =
    std::env::var("MACOSX_DEPLOYMENT_TARGET").unwrap_or_else(|_| "11.0".to_string());
  let target = format!("{target_arch}-apple-macosx{deployment_target}");

  // Build the Swift bridge as a standalone dylib. It is NOT linked into the
  // main `.node` addon — that way the addon stays free of Swift runtime
  // dependencies and remains loadable on older macOS versions (< 10.14.4)
  // which do not ship `/usr/lib/swift`. At runtime, Rust will `dlopen` this
  // sidecar when (and only when) the user is on macOS 26+ and the file is
  // present. If the open fails for any reason we fall back to the legacy
  // VNRecognizeTextRequest path.
  let dylib_name = "librecognize_documents.dylib";
  let dylib_out = format!("{out_dir}/{dylib_name}");

  let output = match std::process::Command::new("swiftc")
    .args([
      "-emit-library",
      "-parse-as-library",
      "-whole-module-optimization",
      "-target",
      &target,
      // Set the install name to @loader_path so consumers of the dylib can
      // discover it via the directory of whoever loaded them. We always
      // dlopen by absolute path at runtime so this is mostly documentation,
      // but it keeps the dylib relocatable.
      "-Xlinker",
      "-install_name",
      "-Xlinker",
      &format!("@loader_path/{dylib_name}"),
      "-o",
      &dylib_out,
      &swift_src,
    ])
    .output()
  {
    Ok(output) => output,
    Err(err) => {
      // `swiftc` is not on PATH (no Xcode / no command-line tools, or some
      // other spawn failure). The Rust addon can still build the legacy
      // VNRecognizeTextRequest path, so warn and skip the Swift bridge.
      eprintln!(
        "cargo:warning=Skipping RecognizeDocumentsRequest Swift bridge: failed to spawn swiftc ({err}). Install Xcode or the command-line tools to enable the macOS 26+ structured-document path."
      );
      return;
    }
  };

  if !output.status.success() {
    let stderr = String::from_utf8_lossy(&output.stderr);
    // If the SDK doesn't have RecognizeDocumentsRequest, skip gracefully
    if stderr.contains("cannot find") || stderr.contains("has no member") {
      eprintln!(
        "cargo:warning=Skipping RecognizeDocumentsRequest Swift bridge: macOS 26 SDK not available"
      );
      return;
    }
    panic!("Swift compilation failed:\n{stderr}");
  }

  // Copy the freshly built dylib next to the `.node` so it can be discovered
  // via `dladdr` at runtime. The cargo target directory is the great-grand-
  // parent of `OUT_DIR` (OUT_DIR = $target/$profile/build/<pkg-hash>/out).
  let out_path = std::path::PathBuf::from(&out_dir);
  if let Some(target_root) = out_path
    .ancestors()
    .nth(3)
    .map(std::path::Path::to_path_buf)
  {
    let dest = target_root.join(dylib_name);
    if let Err(err) = std::fs::copy(&dylib_out, &dest) {
      eprintln!(
        "cargo:warning=Failed to copy {dylib_name} to {}: {err}",
        dest.display()
      );
    }
    // Also drop a copy in the workspace root so napi-rs's post-build step
    // (which moves the `.node` next to package.json) finds the sidecar in
    // the same directory. Build scripts cannot reliably know the final
    // destination, so we mirror napi-rs's convention of placing artifacts
    // beside CARGO_MANIFEST_DIR.
    let manifest_dest = std::path::PathBuf::from(&manifest_dir).join(dylib_name);
    if let Err(err) = std::fs::copy(&dylib_out, &manifest_dest) {
      eprintln!(
        "cargo:warning=Failed to copy {dylib_name} to {}: {err}",
        manifest_dest.display()
      );
    }
  }

  // NOTE: PACKAGING — `napi prepublish` currently only ships `.node` (and
  // `.wasm`) artifacts when assembling per-platform npm packages. The Darwin
  // packages (`@napi-rs/system-ocr-darwin-arm64` and `-darwin-x64`) need to
  // include the sidecar `librecognize_documents.dylib` next to the `.node`
  // for the runtime `dladdr`-based discovery in `src/macos/documents.rs` to
  // succeed. Possible paths:
  //   1. Add a `files`/post-build hook in CI that copies the dylib into the
  //      generated `npm/darwin-arm64` and `npm/darwin-x64` directories before
  //      `npm publish`.
  //   2. Wait for/contribute napi-rs CLI support for additional binary
  //      artifacts in the `napi` block of package.json.
  // This change is out of scope for this iteration — the local build path is
  // the priority. Without the sidecar, runtime simply falls back to the
  // legacy VNRecognizeTextRequest path (which is the desired behaviour on
  // older macOS).
  //
  // Deliberately NO link directives here. The main `.node` addon must not
  // depend on the Swift bridge, Swift runtime, or the Apple frameworks that
  // only the bridge uses (Vision/CoreGraphics/Foundation/ImageIO). Those
  // dependencies travel with the sidecar dylib.

  // Set cfg flag so Rust code knows the sidecar was produced at build time.
  // Runtime presence is still verified via dlopen.
  println!("cargo:rustc-cfg=has_recognize_documents");

  println!("cargo:rerun-if-changed=src/macos/recognize_documents.swift");
}
