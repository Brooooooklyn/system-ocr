#![deny(clippy::all)]

use std::mem;

use napi::bindgen_prelude::{AbortSignal, AsyncTask, Either, Env, Result, Task, Uint8Array};
use napi_derive::napi;
use thiserror::Error;

#[cfg(target_os = "macos")]
mod macos;

#[cfg(target_os = "macos")]
use macos::perform_ocr;

#[cfg(target_os = "windows")]
mod windows;

#[cfg(target_os = "windows")]
use windows::perform_ocr;

#[napi(object)]
pub struct OcrResult {
  pub text: String,
  /// always 1.0 on Windows
  pub confidence: f64,
}

#[napi]
#[derive(Debug, Clone, Copy)]
pub enum OcrAccuracy {
  Fast,
  Accurate,
}

#[derive(Error, Debug)]
pub enum OcrError {
  #[error("Failed to allocate VNRecognizeTextRequest")]
  VNRecognizeTextRequest,
  #[error("Failed to initialize VNRecognizeTextRequest")]
  VNRecognizeTextRequestInit,
  #[error("No text recognized")]
  NoTextRecognized,
  #[error("Unknown Vision error")]
  UnknownVisionError,
  #[error("Error {0}")]
  ErrorWithDesc(String),
  #[error("Failed to get localized description")]
  LocalizedDescription,
  #[error("Failed to get string from first object")]
  StringFromFirstObject,
  #[error("Windows error {0}")]
  WindowsError(String),
}

pub struct RecognizeTask {
  image: Either<String, Uint8Array>,
  accuracy: OcrAccuracy,
  preferred_langs: Option<Vec<String>>,
}

#[napi]
impl Task for RecognizeTask {
  type Output = OcrResult;
  type JsValue = OcrResult;

  fn compute(&mut self) -> Result<Self::Output> {
    let (text, confidence) = perform_ocr(
      mem::replace(&mut self.image, Either::A(String::new())),
      self.accuracy,
      self.preferred_langs.take().unwrap_or_default(),
    )
    .map_err(anyhow::Error::from)?;
    Ok(OcrResult {
      text,
      confidence: confidence as f64,
    })
  }

  fn resolve(&mut self, _: Env, output: Self::Output) -> Result<Self::JsValue> {
    Ok(output)
  }
}

#[napi]
/// @param image - The image file path or Buffer
/// @param accuracy - The accuracy of the OCR. Default is `Accurate`. Ignored on Windows.
/// @param preferredLangs - The preferred languages for the OCR. Default is `["en-US"]`. On Windows, only the first language is used.
/// @param signal - The signal to abort the OCR.
pub fn recognize(
  image: Either<String, Uint8Array>,
  accuracy: Option<OcrAccuracy>,
  preferred_langs: Option<Vec<String>>,
  signal: Option<AbortSignal>,
) -> AsyncTask<RecognizeTask> {
  AsyncTask::with_optional_signal(
    RecognizeTask {
      image,
      accuracy: accuracy.unwrap_or(OcrAccuracy::Accurate),
      preferred_langs,
    },
    signal,
  )
}
