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
  let target = format!("{target_arch}-apple-macosx15.0");

  let obj_path = format!("{out_dir}/recognize_documents.o");

  // Compile Swift source to object file
  let output = std::process::Command::new("swiftc")
    .args([
      "-emit-object",
      "-parse-as-library",
      "-whole-module-optimization",
      "-target",
      &target,
      "-o",
      &obj_path,
      &swift_src,
    ])
    .output()
    .expect("Failed to run swiftc. Is Xcode installed?");

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

  // Create static library from the object file
  let lib_path = format!("{out_dir}/librecognize_documents.a");
  let ar_output = std::process::Command::new("ar")
    .args(["crs", &lib_path, &obj_path])
    .output()
    .expect("Failed to run ar");

  if !ar_output.status.success() {
    panic!(
      "ar failed: {}",
      String::from_utf8_lossy(&ar_output.stderr)
    );
  }

  // Tell Cargo to link the static library
  println!("cargo:rustc-link-search=native={out_dir}");
  println!("cargo:rustc-link-lib=static=recognize_documents");

  // Link Apple frameworks used by the Swift code
  println!("cargo:rustc-link-lib=framework=Vision");
  println!("cargo:rustc-link-lib=framework=CoreGraphics");
  println!("cargo:rustc-link-lib=framework=Foundation");
  println!("cargo:rustc-link-lib=framework=ImageIO");

  // Link Swift runtime (ships with macOS)
  let toolchain_output = std::process::Command::new("xcrun")
    .args(["--toolchain", "default", "--find", "swiftc"])
    .output()
    .expect("xcrun failed");
  let swiftc_path = String::from_utf8(toolchain_output.stdout)
    .unwrap()
    .trim()
    .to_string();
  let toolchain_lib = std::path::Path::new(&swiftc_path)
    .parent()
    .unwrap()
    .parent()
    .unwrap()
    .join("lib/swift/macosx");
  println!(
    "cargo:rustc-link-search=native={}",
    toolchain_lib.display()
  );
  println!("cargo:rustc-link-search=native=/usr/lib/swift");

  // Set rpath so the dylib can find Swift runtime libraries at load time
  println!("cargo:rustc-cdylib-link-arg=-Wl,-rpath,/usr/lib/swift");
  println!(
    "cargo:rustc-cdylib-link-arg=-Wl,-rpath,{}",
    toolchain_lib.display()
  );

  // Set cfg flag so Rust code knows the Swift bridge is available
  println!("cargo:rustc-cfg=has_recognize_documents");

  println!("cargo:rerun-if-changed=src/macos/recognize_documents.swift");
}
