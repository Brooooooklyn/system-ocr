#![deny(clippy::all)]

use napi_derive::napi;

#[cfg(target_os = "macos")]
mod macos;

#[cfg(target_os = "macos")]
pub use macos::*;

#[napi]
#[derive(Debug, Clone, Copy)]
pub enum OcrAccuracy {
  Fast,
  Accurate,
}
