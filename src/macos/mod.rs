use napi::bindgen_prelude::{Either, Uint8Array};
use objc2_vision::VNRequestTextRecognitionLevel;

use crate::{OcrAccuracy, OcrError};

#[cfg(has_recognize_documents)]
mod documents;

impl From<OcrAccuracy> for VNRequestTextRecognitionLevel {
  fn from(value: OcrAccuracy) -> Self {
    match value {
      OcrAccuracy::Fast => VNRequestTextRecognitionLevel::Fast,
      OcrAccuracy::Accurate => VNRequestTextRecognitionLevel::Accurate,
    }
  }
}

pub(crate) fn perform_ocr(
  #[cfg_attr(not(has_recognize_documents), allow(unused_mut))] mut image: Either<
    String,
    Uint8Array,
  >,
  accuracy: OcrAccuracy,
  preferred_langs: Option<Vec<String>>,
) -> std::result::Result<(String, f32), OcrError> {
  // Distinguish "caller passed no `preferredLangs`" from "caller passed an
  // explicit list" BEFORE resolving the default. The presence of explicit
  // language hints is one of the documented escape hatches that forces the
  // legacy `VNRecognizeTextRequest` path so callers can recover the averaged
  // per-observation confidence score.
  let explicit_langs = preferred_langs.is_some();
  // Resolve the documented default once so both code paths apply the same
  // language hint policy: callers who don't pass `preferredLangs` get
  // `["en-US"]` as advertised in the public docs. Treat an explicit empty
  // list the same way (no useful hint, but keeps the explicit-langs gate
  // intact since the caller still chose to opt out of the documents path).
  let resolved_langs = match preferred_langs {
    Some(langs) if !langs.is_empty() => langs,
    _ => vec!["en-US".to_string()],
  };

  // On macOS 26+, prefer RecognizeDocumentsRequest for richer structured
  // output. The structured-document recognizer doesn't expose an accuracy
  // knob and synthesises a hardcoded 1.0 confidence, so only take this path
  // when the caller is happy with the default `Accurate` setting AND has not
  // supplied explicit `preferredLangs`. Both gates are part of the docstring
  // contract on `OcrResult::confidence`: either escape hatch routes through
  // the legacy `VNRecognizeTextRequest` path which honours `OcrAccuracy::Fast`
  // and surfaces averaged per-observation confidence.
  #[cfg(has_recognize_documents)]
  {
    if matches!(accuracy, OcrAccuracy::Accurate) && !explicit_langs {
      // Confidence is hardcoded to 1.0 because RecognizeDocumentsRequest does
      // not surface per-observation confidence scores.
      if let Ok(text) = documents::perform_recognize_documents(&mut image, &resolved_langs) {
        return Ok((text, 1.0));
      }
      // RecognizeDocumentsRequest failed (e.g. runtime < macOS 26, missing
      // sidecar dylib, or absent Swift runtime), fall through to the legacy
      // VNRecognizeTextRequest path.
    }
  }

  perform_ocr_legacy(image, accuracy, resolved_langs)
}

fn perform_ocr_legacy(
  mut image: Either<String, Uint8Array>,
  accuracy: OcrAccuracy,
  preferred_langs: Vec<String>,
) -> std::result::Result<(String, f32), OcrError> {
  use objc2::{
    AnyThread,
    rc::{Retained, autoreleasepool},
    runtime::AnyObject,
  };
  use objc2_core_foundation::CGRect;
  use objc2_foundation::{NSArray, NSData, NSDictionary, NSString, NSURL};
  use objc2_vision::{VNImageOption, VNImageRequestHandler, VNRecognizeTextRequest, VNRequest};
  unsafe {
    autoreleasepool(|pool| {
      let empty_options: Retained<NSDictionary<VNImageOption, AnyObject>> = NSDictionary::new();
      let handler = match &mut image {
        Either::A(path) => {
          let ns_path = NSString::from_str(path.as_str());
          let url: Retained<NSURL> = NSURL::fileURLWithPath(&ns_path);
          VNImageRequestHandler::initWithURL_options(
            VNImageRequestHandler::alloc(),
            &url,
            &empty_options,
          )
        }
        Either::B(image) => {
          let data = image.as_mut();
          let ns_data = NSData::initWithBytesNoCopy_length_freeWhenDone(
            NSData::alloc(),
            std::ptr::NonNull::new_unchecked(data.as_mut_ptr().cast()),
            data.len(),
            false,
          );
          VNImageRequestHandler::initWithData_options(
            VNImageRequestHandler::alloc(),
            &ns_data,
            &empty_options,
          )
        }
      };

      let request = VNRecognizeTextRequest::init(VNRecognizeTextRequest::alloc());
      request.setRecognitionLevel(accuracy.into());

      // `preferred_langs` is guaranteed non-empty here: `perform_ocr` resolves
      // the documented `["en-US"]` default before dispatching.
      let langs = preferred_langs
        .iter()
        .map(|lang| NSString::from_str(lang))
        .collect::<Vec<Retained<NSString>>>();
      let preferred_langs_arr: Retained<NSArray<NSString>> = NSArray::from_retained_slice(&langs);
      request.setRecognitionLanguages(&preferred_langs_arr);
      request.setUsesLanguageCorrection(true);
      request.setMinimumTextHeight(0.008);
      request.setAutomaticallyDetectsLanguage(true);
      let vn_request: Retained<VNRequest> = request.clone().into_super().into_super();
      handler
        .performRequests_error(&NSArray::from_retained_slice(&[vn_request]))
        .map_err(|err| OcrError::ErrorWithDesc(err.to_string()))?;

      if let Some(results) = request.results() {
        if results.is_empty() {
          return Err(OcrError::NoTextRecognized);
        }
        const MIN_CONFIDENCE: f32 = 0.0;
        let mut collected_text = String::new();
        let mut total_conf = 0.0f32;
        let mut used = 0usize;

        for result in results {
          // Fetch up to 5 candidates and pick the first that satisfies the confidence threshold
          let candidates = result.topCandidates(5);
          if candidates.is_empty() {
            continue;
          }

          let mut first_candidate = None;

          for candidate in candidates {
            let conf: f32 = candidate.confidence();
            if conf >= MIN_CONFIDENCE {
              first_candidate = Some(candidate);
              break;
            }
          }
          let Some(first_candidate) = first_candidate else {
            continue;
          };
          // Get string

          let rust_string = first_candidate.string();
          let rust_str = rust_string.to_str(pool);
          // Determine whether to insert space or newline depending on bounding box.
          let bbox: CGRect = result.boundingBox();
          if !rust_str.is_empty() {
            if !collected_text.is_empty() {
              if bbox.origin.y < 0.1 {
                collected_text.push('\n');
              } else {
                collected_text.push(' ');
              }
            }
            collected_text.push_str(rust_str);
          }
          total_conf += first_candidate.confidence();
          used += 1;
        }

        let avg_conf = if used > 0 {
          total_conf / used as f32
        } else {
          0.0
        };
        return Ok((collected_text, avg_conf));
      }
      Err(OcrError::NoTextRecognized)
    })
  }
}
