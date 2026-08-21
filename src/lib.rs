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
#[derive(Debug, Clone, PartialEq)]
pub struct OcrBoundingBox {
  /// Horizontal position relative to the input image, normalized to `0.0..=1.0`.
  pub x: f64,
  /// Vertical position from the top of the input image, normalized to `0.0..=1.0`.
  pub y: f64,
  /// Width relative to the input image, normalized to `0.0..=1.0`.
  pub width: f64,
  /// Height relative to the input image, normalized to `0.0..=1.0`.
  pub height: f64,
}

#[napi(object)]
#[derive(Debug, Clone, PartialEq)]
pub struct OcrLine {
  pub text: String,
  /// Always 1.0 on Windows.
  pub confidence: f64,
  /// Axis-aligned line bounds in normalized, top-left-origin image coordinates.
  pub bounding_box: OcrBoundingBox,
}

#[napi(object)]
pub struct OcrResult {
  pub text: String,
  /// Always 1.0 on Windows. On macOS, the averaged per-observation confidence
  /// returned by the Vision recognizer (either `RecognizeDocumentsRequest` on
  /// macOS 26+ or the legacy `VNRecognizeTextRequest` path).
  pub confidence: f64,
  /// Recognized lines in reading order. The formatted `text` is not guaranteed
  /// to equal these lines joined together.
  pub lines: Vec<OcrLine>,
}

pub(crate) struct OcrOutput {
  pub text: String,
  pub confidence: f64,
  pub lines: Vec<OcrLine>,
}

pub(crate) fn normalized_bounding_box(
  left: f64,
  top: f64,
  right: f64,
  bottom: f64,
) -> Option<OcrBoundingBox> {
  if ![left, top, right, bottom]
    .iter()
    .all(|value| value.is_finite())
    || right <= left
    || bottom <= top
  {
    return None;
  }

  let left = left.clamp(0.0, 1.0);
  let top = top.clamp(0.0, 1.0);
  let right = right.clamp(0.0, 1.0);
  let bottom = bottom.clamp(0.0, 1.0);
  if right <= left || bottom <= top {
    return None;
  }

  Some(OcrBoundingBox {
    x: left,
    y: top,
    width: right - left,
    height: bottom - top,
  })
}

#[cfg(any(target_os = "windows", test))]
pub(crate) fn normalized_rotated_bounding_box(
  left: f64,
  top: f64,
  right: f64,
  bottom: f64,
  image_width: f64,
  image_height: f64,
  clockwise_degrees: Option<f64>,
) -> Option<OcrBoundingBox> {
  if ![left, top, right, bottom, image_width, image_height]
    .iter()
    .all(|value| value.is_finite())
    || right <= left
    || bottom <= top
    || image_width <= 0.0
    || image_height <= 0.0
  {
    return None;
  }

  let mut corners = [(left, top), (right, top), (right, bottom), (left, bottom)];

  if let Some(angle) = clockwise_degrees.filter(|angle| angle.is_finite() && *angle != 0.0) {
    let radians = angle.to_radians();
    let (sin, cos) = radians.sin_cos();
    let center_x = image_width / 2.0;
    let center_y = image_height / 2.0;
    for (x, y) in &mut corners {
      let offset_x = *x - center_x;
      let offset_y = *y - center_y;
      *x = center_x + cos * offset_x - sin * offset_y;
      *y = center_y + sin * offset_x + cos * offset_y;
    }
  }

  let (left, top, right, bottom) = corners.iter().fold(
    (
      f64::INFINITY,
      f64::INFINITY,
      f64::NEG_INFINITY,
      f64::NEG_INFINITY,
    ),
    |(left, top, right, bottom), (x, y)| (left.min(*x), top.min(*y), right.max(*x), bottom.max(*y)),
  );

  normalized_bounding_box(
    left / image_width,
    top / image_height,
    right / image_width,
    bottom / image_height,
  )
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
  /// The RecognizeDocumentsRequest sidecar dylib could not be loaded
  /// (OS < macOS 26, missing sidecar file, or missing Swift runtime).
  /// Distinct from a sidecar-present runtime failure so the macOS dispatch
  /// can fall through silently here while surfacing other failures.
  #[error("RecognizeDocumentsRequest sidecar unavailable")]
  DocumentsSidecarUnavailable,
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
    let output = perform_ocr(
      mem::replace(&mut self.image, Either::A(String::new())),
      self.accuracy,
      self.preferred_langs.take().unwrap_or_default(),
    )
    .map_err(anyhow::Error::from)?;
    Ok(OcrResult {
      text: output.text,
      confidence: output.confidence,
      lines: output.lines,
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

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn normalized_box_clamps_edges() {
    let bounding_box = normalized_bounding_box(-0.1, 0.2, 1.1, 0.8).unwrap();
    assert_eq!(bounding_box.x, 0.0);
    assert_eq!(bounding_box.y, 0.2);
    assert_eq!(bounding_box.width, 1.0);
    assert!((bounding_box.height - 0.6).abs() < f64::EPSILON);
  }

  #[test]
  fn normalized_box_rejects_invalid_geometry() {
    assert_eq!(normalized_bounding_box(0.4, 0.2, 0.4, 0.8), None);
    assert_eq!(normalized_bounding_box(f64::NAN, 0.2, 0.8, 0.8), None);
  }

  fn assert_box_close(actual: OcrBoundingBox, expected: OcrBoundingBox) {
    assert!((actual.x - expected.x).abs() < 1e-10);
    assert!((actual.y - expected.y).abs() < 1e-10);
    assert!((actual.width - expected.width).abs() < 1e-10);
    assert!((actual.height - expected.height).abs() < 1e-10);
  }

  #[test]
  fn normalizes_unrotated_pixel_box() {
    let bounding_box =
      normalized_rotated_bounding_box(10.0, 20.0, 50.0, 40.0, 100.0, 200.0, None).unwrap();

    assert_box_close(
      bounding_box,
      OcrBoundingBox {
        x: 0.1,
        y: 0.1,
        width: 0.4,
        height: 0.1,
      },
    );
  }

  #[test]
  fn rotates_pixel_box_clockwise_around_image_center() {
    let bounding_box =
      normalized_rotated_bounding_box(10.0, 20.0, 30.0, 40.0, 100.0, 100.0, Some(90.0)).unwrap();

    assert_box_close(
      bounding_box,
      OcrBoundingBox {
        x: 0.6,
        y: 0.1,
        width: 0.2,
        height: 0.2,
      },
    );
  }

  #[test]
  fn clamps_rotated_pixel_box_to_image_edges() {
    let bounding_box =
      normalized_rotated_bounding_box(-20.0, 10.0, 20.0, 30.0, 100.0, 100.0, Some(90.0)).unwrap();

    assert!(bounding_box.x >= 0.0);
    assert!(bounding_box.y >= 0.0);
    assert!(bounding_box.x + bounding_box.width <= 1.0);
    assert!(bounding_box.y + bounding_box.height <= 1.0);
  }

  #[test]
  fn rejects_degenerate_pixel_box() {
    assert_eq!(
      normalized_rotated_bounding_box(10.0, 10.0, 10.0, 30.0, 100.0, 100.0, None),
      None
    );
  }
}
