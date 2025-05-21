use napi::bindgen_prelude::{Either, Uint8Array};
use objc2_vision::VNRequestTextRecognitionLevel;

use crate::{OcrAccuracy, OcrError};

impl From<OcrAccuracy> for VNRequestTextRecognitionLevel {
  fn from(value: OcrAccuracy) -> Self {
    match value {
      OcrAccuracy::Fast => VNRequestTextRecognitionLevel::Fast,
      OcrAccuracy::Accurate => VNRequestTextRecognitionLevel::Accurate,
    }
  }
}

pub(crate) fn perform_ocr(
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
          let ns_data = NSData::initWithBytesNoCopy_length(
            NSData::alloc(),
            std::ptr::NonNull::new_unchecked(data.as_mut_ptr().cast()),
            data.len(),
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

      let langs = if preferred_langs.is_empty() {
        vec![NSString::from_str("en-US")]
      } else {
        preferred_langs
          .iter()
          .map(|lang| NSString::from_str(lang))
          .collect::<Vec<Retained<NSString>>>()
      };
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
