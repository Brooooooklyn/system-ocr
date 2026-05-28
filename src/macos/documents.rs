use std::ffi::{CStr, CString, c_char, c_void};
use std::os::raw::c_int;
use std::path::PathBuf;
use std::ptr;
use std::sync::LazyLock;

use napi::bindgen_prelude::{Either, Uint8Array};

use crate::OcrError;

// `dlopen` flags. Defined inline so we don't pull in `libc`.
const RTLD_NOW: c_int = 2;
const RTLD_LOCAL: c_int = 4;

// Expected ABI version exported by the Swift sidecar. Must match the value
// returned by `recognize_documents_abi_version` in
// `src/macos/recognize_documents.swift`. BUMP whenever any of the
// operational `@_cdecl` signatures (`recognize_documents_from_path`,
// `recognize_documents_from_data`, `free_recognize_result`) change and pair
// every bump with a matching bump of the Swift function's return value. If
// the values disagree at runtime, `load_bridge` refuses to use the sidecar
// (and the caller falls through to the legacy path in non-strict mode).
const EXPECTED_ABI_VERSION: u32 = 1;

unsafe extern "C" {
  fn dlopen(filename: *const c_char, flag: c_int) -> *mut c_void;
  fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
  fn dladdr(addr: *const c_void, info: *mut DlInfo) -> c_int;
  fn dlerror() -> *mut c_char;
}

#[repr(C)]
struct DlInfo {
  dli_fname: *const c_char,
  dli_fbase: *mut c_void,
  dli_sname: *const c_char,
  dli_saddr: *mut c_void,
}

// New ABI: each entry point takes OUT pointers for the aggregated confidence
// and an error string, and returns either a non-NULL malloc'd C-string on
// success (empty string means "no text recognized") or NULL on failure, in
// which case `*error_out` will point to a malloc'd error description. The
// Swift bridge initialises `*confidence_out` to `0.0` at entry, so error paths
// never leave uninitialised memory visible to Rust.
type FromPathFn = unsafe extern "C" fn(
  path: *const c_char,
  langs: *const c_char,
  confidence_out: *mut f32,
  error_out: *mut *mut c_char,
) -> *mut c_char;
type FromDataFn = unsafe extern "C" fn(
  data: *const u8,
  len: usize,
  langs: *const c_char,
  confidence_out: *mut f32,
  error_out: *mut *mut c_char,
) -> *mut c_char;
type FreeFn = unsafe extern "C" fn(*mut c_char);
type AbiVersionFn = unsafe extern "C" fn() -> u32;

struct Bridge {
  from_path: FromPathFn,
  from_data: FromDataFn,
  free: FreeFn,
}

// SAFETY: `Bridge` only holds function pointers that are valid for the
// remainder of the process lifetime once the dylib has been loaded. The
// pointers are immutable after construction and are safe to use from any
// thread.
unsafe impl Send for Bridge {}
unsafe impl Sync for Bridge {}

static BRIDGE: LazyLock<Option<Bridge>> = LazyLock::new(load_bridge);

/// Read the current `dlerror()` message, if any. `dlerror` returns NULL when
/// no error is pending, or a pointer to a process-owned C string describing
/// the most recent failure (the call also clears the pending error).
fn take_dlerror() -> Option<String> {
  // SAFETY: `dlerror()` returns either NULL or a pointer to a NUL-terminated
  // C string owned by libdyld; copying it out before the next dl* call is
  // safe.
  let ptr = unsafe { dlerror() };
  if ptr.is_null() {
    None
  } else {
    Some(
      unsafe { CStr::from_ptr(ptr) }
        .to_string_lossy()
        .into_owned(),
    )
  }
}

fn load_bridge() -> Option<Bridge> {
  // Skip on macOS < 26 BEFORE touching the sidecar. The Swift entry points
  // weak-link Vision symbols and dyld will happily load the dylib on older
  // systems, but every call would return NULL with "requires macOS 26 or
  // later" — that would be treated as a sidecar-present runtime failure and
  // spam stderr on every call. Cached `None` here means pre-26 systems pay
  // the version check once and then take the legacy path silently.
  if !macos_supports_documents() {
    return None;
  }

  let dylib_path = sidecar_path()?;

  // "File not present" is the expected case on release builds where the
  // sidecar was intentionally omitted (e.g. the build-time gate skipped it).
  // Fall through silently; the caller will treat this as
  // `DocumentsSidecarUnavailable` and route to the legacy OCR path.
  if !dylib_path.exists() {
    return None;
  }

  let c_path = CString::new(dylib_path.to_str()?).ok()?;
  // Clear any stale dlerror state before our calls so the next `take_dlerror`
  // reflects only failures originating here.
  let _ = take_dlerror();
  // SAFETY: `c_path` is a valid NUL-terminated string for the duration of
  // the call; `dlopen` either returns a valid handle or null.
  let handle = unsafe { dlopen(c_path.as_ptr(), RTLD_NOW | RTLD_LOCAL) };
  if handle.is_null() {
    // Sidecar is physically present but failed to load (wrong architecture,
    // ABI skew, missing Swift runtime, signature mismatch, etc.). This is a
    // real release regression — surface it on stderr so operators see it in
    // production logs. Still return `None` so the caller falls through to the
    // legacy path and end-users keep getting OCR output.
    let msg = take_dlerror().unwrap_or_else(|| "unknown dlopen error".to_string());
    eprintln!(
      "system-ocr: sidecar at {} failed to load: {msg}",
      dylib_path.display()
    );
    return None;
  }
  // We intentionally never `dlclose` — the dylib stays loaded for the
  // remainder of the addon's lifetime.

  // ABI version handshake. Done BEFORE resolving the three operational
  // symbols so a sidecar built against a different FFI shape (cache restore,
  // stale manual bundle, partial upgrade) is rejected before any `transmute`
  // could materialise a function pointer with the wrong signature and
  // corrupt memory on first call.
  let abi_sym = CString::new("recognize_documents_abi_version").ok()?;
  let _ = take_dlerror();
  // SAFETY: `handle` is a valid dlopen handle; `abi_sym` is a valid
  // NUL-terminated string.
  let abi_ptr = unsafe { dlsym(handle, abi_sym.as_ptr()) };
  if abi_ptr.is_null() {
    let msg = take_dlerror().unwrap_or_else(|| "abi-version symbol missing".to_string());
    eprintln!(
      "system-ocr: sidecar at {} missing recognize_documents_abi_version: {msg}",
      dylib_path.display()
    );
    return None;
  }
  // SAFETY: The Swift `@_cdecl("recognize_documents_abi_version")` entry
  // point matches this signature (`() -> u32`).
  let abi_fn: AbiVersionFn = unsafe { std::mem::transmute::<*mut c_void, AbiVersionFn>(abi_ptr) };
  // SAFETY: `abi_fn` is a freshly-resolved Swift `@_cdecl` taking no
  // arguments; calling it is sound.
  let actual = unsafe { abi_fn() };
  if actual != EXPECTED_ABI_VERSION {
    eprintln!(
      "system-ocr: sidecar at {} ABI version {} doesn't match expected {} — refusing to use",
      dylib_path.display(),
      actual,
      EXPECTED_ABI_VERSION
    );
    return None;
  }

  let from_path_sym = CString::new("recognize_documents_from_path").ok()?;
  let from_data_sym = CString::new("recognize_documents_from_data").ok()?;
  let free_sym = CString::new("free_recognize_result").ok()?;

  // SAFETY: `handle` is a valid dlopen handle; symbol names are valid
  // NUL-terminated strings.
  let _ = take_dlerror();
  let from_path = unsafe { dlsym(handle, from_path_sym.as_ptr()) };
  let from_data = unsafe { dlsym(handle, from_data_sym.as_ptr()) };
  let free = unsafe { dlsym(handle, free_sym.as_ptr()) };

  if from_path.is_null() || from_data.is_null() || free.is_null() {
    // Loaded the dylib but couldn't resolve one of our `@_cdecl` symbols —
    // typically an export-list drift between the Rust caller and the Swift
    // sidecar. Treat exactly like the broken-load case above: log loudly and
    // fall through.
    let msg = take_dlerror().unwrap_or_else(|| "missing exported symbol".to_string());
    eprintln!(
      "system-ocr: sidecar at {} loaded but symbol lookup failed: {msg}",
      dylib_path.display()
    );
    return None;
  }

  // SAFETY: The Swift `@_cdecl` entry points match these signatures exactly.
  Some(Bridge {
    from_path: unsafe { std::mem::transmute::<*mut c_void, FromPathFn>(from_path) },
    from_data: unsafe { std::mem::transmute::<*mut c_void, FromDataFn>(from_data) },
    free: unsafe { std::mem::transmute::<*mut c_void, FreeFn>(free) },
  })
}

/// True when the current process is running on macOS 26 or later — the
/// minimum runtime for `RecognizeDocumentsRequest`.
fn macos_supports_documents() -> bool {
  use objc2_foundation::{NSOperatingSystemVersion, NSProcessInfo};
  let info = NSProcessInfo::processInfo();
  let required = NSOperatingSystemVersion {
    majorVersion: 26,
    minorVersion: 0,
    patchVersion: 0,
  };
  info.isOperatingSystemAtLeastVersion(required)
}

/// Locate the sidecar dylib by asking `dladdr` for the on-disk path of the
/// image that contains *this* function, then sibling-resolving the dylib name.
fn sidecar_path() -> Option<PathBuf> {
  let mut info = DlInfo {
    dli_fname: ptr::null(),
    dli_fbase: ptr::null_mut(),
    dli_sname: ptr::null(),
    dli_saddr: ptr::null_mut(),
  };
  let addr = sidecar_path as *const c_void;
  // SAFETY: `&mut info` points to a valid `DlInfo` struct for the duration of
  // the call; `addr` is the address of a real function in this image.
  let ok = unsafe { dladdr(addr, &mut info) };
  if ok == 0 || info.dli_fname.is_null() {
    return None;
  }
  // SAFETY: When `dladdr` succeeds with a non-null `dli_fname`, the pointer
  // refers to a NUL-terminated string owned by dyld.
  let fname = unsafe { CStr::from_ptr(info.dli_fname) }.to_str().ok()?;
  let dir = PathBuf::from(fname).parent()?.to_path_buf();
  Some(dir.join("librecognize_documents.dylib"))
}

pub(crate) fn perform_recognize_documents(
  image: &mut Either<String, Uint8Array>,
  preferred_langs: &[String],
) -> std::result::Result<(String, f32), OcrError> {
  let bridge = BRIDGE
    .as_ref()
    .ok_or(OcrError::DocumentsSidecarUnavailable)?;

  // Encode the language hints as a comma-separated UTF-8 string. The Swift
  // bridge will split on `,` and apply them via
  // `RecognizeDocumentsRequest.textRecognitionOptions.recognitionLanguages`.
  let langs_joined = preferred_langs.join(",");
  let langs_cstr =
    CString::new(langs_joined).map_err(|e| OcrError::ErrorWithDesc(e.to_string()))?;

  let mut error_ptr: *mut c_char = ptr::null_mut();
  // The Swift bridge always writes `*confidence_out` on entry (initialising it
  // to `0.0`) so this initial value is just a placeholder for the case where
  // dispatch itself fails before the Task runs (which it shouldn't).
  let mut confidence: f32 = 0.0;
  let raw_ptr = unsafe {
    match image {
      Either::A(path) => {
        let c_path =
          CString::new(path.as_str()).map_err(|e| OcrError::ErrorWithDesc(e.to_string()))?;
        (bridge.from_path)(
          c_path.as_ptr(),
          langs_cstr.as_ptr(),
          &mut confidence,
          &mut error_ptr,
        )
      }
      Either::B(buf) => {
        let data = buf.as_mut();
        (bridge.from_data)(
          data.as_ptr(),
          data.len(),
          langs_cstr.as_ptr(),
          &mut confidence,
          &mut error_ptr,
        )
      }
    }
  };

  if raw_ptr.is_null() {
    // Failure: error_ptr should be non-null with a description.
    let msg = if error_ptr.is_null() {
      "Swift bridge returned null without an error description".to_string()
    } else {
      // SAFETY: error_ptr is a malloc'd C string owned by the Swift bridge.
      let s = unsafe { CStr::from_ptr(error_ptr) }
        .to_string_lossy()
        .into_owned();
      unsafe { (bridge.free)(error_ptr) };
      s
    };
    return Err(OcrError::ErrorWithDesc(msg));
  }

  // Success path: take ownership of the text, then free it.
  let text = unsafe {
    let s = CStr::from_ptr(raw_ptr).to_string_lossy().into_owned();
    (bridge.free)(raw_ptr);
    s
  };

  // The bridge may also (defensively) set an error string even on success; if
  // so, free it but prefer the recognized text.
  if !error_ptr.is_null() {
    unsafe { (bridge.free)(error_ptr) };
  }

  if text.trim().is_empty() {
    return Err(OcrError::NoTextRecognized);
  }

  Ok((text, confidence))
}
