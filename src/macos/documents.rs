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

unsafe extern "C" {
  fn dlopen(filename: *const c_char, flag: c_int) -> *mut c_void;
  fn dlsym(handle: *mut c_void, symbol: *const c_char) -> *mut c_void;
  fn dladdr(addr: *const c_void, info: *mut DlInfo) -> c_int;
}

#[repr(C)]
struct DlInfo {
  dli_fname: *const c_char,
  dli_fbase: *mut c_void,
  dli_sname: *const c_char,
  dli_saddr: *mut c_void,
}

type FromPathFn = unsafe extern "C" fn(*const c_char) -> *mut c_char;
type FromDataFn = unsafe extern "C" fn(*const u8, usize) -> *mut c_char;
type FreeFn = unsafe extern "C" fn(*mut c_char);

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

fn load_bridge() -> Option<Bridge> {
  let dylib_path = sidecar_path()?;
  let c_path = CString::new(dylib_path.to_str()?).ok()?;
  // SAFETY: `c_path` is a valid NUL-terminated string for the duration of
  // the call; `dlopen` either returns a valid handle or null.
  let handle = unsafe { dlopen(c_path.as_ptr(), RTLD_NOW | RTLD_LOCAL) };
  if handle.is_null() {
    return None;
  }
  // We intentionally never `dlclose` — the dylib stays loaded for the
  // remainder of the addon's lifetime.

  let from_path_sym = CString::new("recognize_documents_from_path").ok()?;
  let from_data_sym = CString::new("recognize_documents_from_data").ok()?;
  let free_sym = CString::new("free_recognize_result").ok()?;

  // SAFETY: `handle` is a valid dlopen handle; symbol names are valid
  // NUL-terminated strings.
  let from_path = unsafe { dlsym(handle, from_path_sym.as_ptr()) };
  let from_data = unsafe { dlsym(handle, from_data_sym.as_ptr()) };
  let free = unsafe { dlsym(handle, free_sym.as_ptr()) };

  if from_path.is_null() || from_data.is_null() || free.is_null() {
    return None;
  }

  // SAFETY: The Swift `@_cdecl` entry points match these signatures exactly.
  Some(Bridge {
    from_path: unsafe { std::mem::transmute::<*mut c_void, FromPathFn>(from_path) },
    from_data: unsafe { std::mem::transmute::<*mut c_void, FromDataFn>(from_data) },
    free: unsafe { std::mem::transmute::<*mut c_void, FreeFn>(free) },
  })
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
) -> std::result::Result<String, OcrError> {
  let bridge = BRIDGE.as_ref().ok_or_else(|| {
    OcrError::ErrorWithDesc("RecognizeDocumentsRequest sidecar unavailable".into())
  })?;

  let raw_ptr = unsafe {
    match image {
      Either::A(path) => {
        let c_path =
          CString::new(path.as_str()).map_err(|e| OcrError::ErrorWithDesc(e.to_string()))?;
        (bridge.from_path)(c_path.as_ptr())
      }
      Either::B(buf) => {
        let data = buf.as_mut();
        (bridge.from_data)(data.as_ptr(), data.len())
      }
    }
  };

  if raw_ptr.is_null() {
    return Err(OcrError::ErrorWithDesc("Swift bridge returned null".into()));
  }

  let text = unsafe {
    let s = CStr::from_ptr(raw_ptr).to_string_lossy().into_owned();
    (bridge.free)(raw_ptr);
    s
  };

  if let Some(err) = text.strip_prefix("ERROR:") {
    return Err(OcrError::ErrorWithDesc(err.to_owned()));
  }

  if text.trim().is_empty() {
    return Err(OcrError::NoTextRecognized);
  }

  Ok(text)
}
