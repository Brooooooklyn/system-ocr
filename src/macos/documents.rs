use napi::bindgen_prelude::{Either, Uint8Array};

use crate::OcrError;

unsafe extern "C" {
  fn recognize_documents_from_path(path: *const std::ffi::c_char) -> *mut std::ffi::c_char;
  fn recognize_documents_from_data(data: *const u8, length: usize) -> *mut std::ffi::c_char;
  fn free_recognize_result(ptr: *mut std::ffi::c_char);
}

pub(crate) fn perform_recognize_documents(
  image: &mut Either<String, Uint8Array>,
) -> std::result::Result<String, OcrError> {
  let raw_ptr = unsafe {
    match image {
      Either::A(path) => {
        let c_path = std::ffi::CString::new(path.as_str())
          .map_err(|e| OcrError::ErrorWithDesc(e.to_string()))?;
        recognize_documents_from_path(c_path.as_ptr())
      }
      Either::B(buf) => {
        let data = buf.as_mut();
        recognize_documents_from_data(data.as_ptr(), data.len())
      }
    }
  };

  let text = unsafe {
    let s = std::ffi::CStr::from_ptr(raw_ptr)
      .to_string_lossy()
      .into_owned();
    free_recognize_result(raw_ptr);
    s
  };

  if let Some(err) = text.strip_prefix("ERROR:") {
    return Err(OcrError::ErrorWithDesc(err.to_owned()));
  }

  Ok(text)
}
