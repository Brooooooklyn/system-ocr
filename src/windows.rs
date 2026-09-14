use std::fs;

#[cfg(target_os = "windows")]
use futures::executor::block_on;
use napi::bindgen_prelude::{Either, Uint8Array};
use windows::{
  Globalization::Language,
  Graphics::Imaging::{BitmapDecoder, SoftwareBitmap},
  Media::Ocr::OcrEngine,
  Storage::{
    FileAccessMode, StorageFile,
    Streams::{DataWriter, InMemoryRandomAccessStream},
  },
  core::{Error, HRESULT, HSTRING, Result},
};

use crate::{OcrAccuracy, OcrError, OcrLine, OcrOutput, normalized_rotated_bounding_box};

const E_ACCESSDENIED: HRESULT = HRESULT(0x80070005u32 as i32);

impl From<HRESULT> for OcrError {
  fn from(value: HRESULT) -> Self {
    OcrError::WindowsError(value.to_string())
  }
}

pub(crate) fn perform_ocr(
  image: Either<String, Uint8Array>,
  _accuracy: OcrAccuracy,
  preferred_langs: Vec<String>,
) -> std::result::Result<OcrOutput, OcrError> {
  perform_ocr_win(image, _accuracy, preferred_langs)
    .map_err(|e| OcrError::WindowsError(e.to_string()))
}

pub(crate) fn perform_ocr_win(
  image: Either<String, Uint8Array>,
  _accuracy: OcrAccuracy,
  preferred_langs: Vec<String>,
) -> Result<OcrOutput> {
  let bitmap = open_image_as_bitmap(image)?;
  let image_width = f64::from(bitmap.PixelWidth()?);
  let image_height = f64::from(bitmap.PixelHeight()?);
  let engine = if let Some(lang) = preferred_langs.first() {
    let lang = Language::CreateLanguage(&HSTRING::from(lang))?;
    OcrEngine::TryCreateFromLanguage(&lang)?
  } else {
    OcrEngine::TryCreateFromUserProfileLanguages()?
  };

  let result = block_on(async { engine.RecognizeAsync(&bitmap)?.await })?;
  let text = result.Text()?.to_string_lossy();
  let text_angle = result.TextAngle().ok().and_then(|angle| angle.Value().ok());
  let native_lines = result.Lines()?;
  let mut lines = Vec::with_capacity(native_lines.Size()? as usize);

  for index in 0..native_lines.Size()? {
    let native_line = native_lines.GetAt(index)?;
    let words = native_line.Words()?;
    let mut line_rect: Option<PixelRect> = None;

    for word_index in 0..words.Size()? {
      let rect = words.GetAt(word_index)?.BoundingRect()?;
      let word_rect = PixelRect {
        left: f64::from(rect.X),
        top: f64::from(rect.Y),
        right: f64::from(rect.X) + f64::from(rect.Width),
        bottom: f64::from(rect.Y) + f64::from(rect.Height),
      };
      line_rect = Some(match line_rect {
        Some(current) => current.union(word_rect),
        None => word_rect,
      });
    }

    if let Some(bounding_box) = line_rect.and_then(|rect| {
      normalized_rotated_bounding_box(
        rect.left,
        rect.top,
        rect.right,
        rect.bottom,
        image_width,
        image_height,
        text_angle,
      )
    }) {
      lines.push(OcrLine {
        text: native_line.Text()?.to_string_lossy(),
        confidence: 1.0,
        bounding_box,
      });
    }
  }

  Ok(OcrOutput {
    text,
    confidence: 1.0,
    lines,
  })
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct PixelRect {
  left: f64,
  top: f64,
  right: f64,
  bottom: f64,
}

impl PixelRect {
  fn union(self, other: Self) -> Self {
    Self {
      left: self.left.min(other.left),
      top: self.top.min(other.top),
      right: self.right.max(other.right),
      bottom: self.bottom.max(other.bottom),
    }
  }
}

/// Opens an PNG file as a `SoftwareBitmap`
pub fn open_image_as_bitmap(image: Either<String, Uint8Array>) -> Result<SoftwareBitmap> {
  match image {
    Either::A(path) => {
      let path = fs::canonicalize(path);
      let path = match path {
        Ok(path) => path.to_string_lossy().replace("\\\\?\\", ""),
        Err(_) => {
          return Err(Error::new(E_ACCESSDENIED, "Could not open file"));
        }
      };

      let file =
        block_on(async { StorageFile::GetFileFromPathAsync(&HSTRING::from(path))?.await })?;

      let bitmap = block_on(async {
        BitmapDecoder::CreateWithIdAsync(
          BitmapDecoder::PngDecoderId()?,
          &file.OpenAsync(FileAccessMode::Read)?.await?,
        )?
        .await
      })?;

      block_on(async { bitmap.GetSoftwareBitmapAsync()?.await })
    }
    Either::B(buffer) => {
      let image_buffer = buffer.as_ref();
      let file_type = file_type::FileType::from_bytes(image_buffer);
      let extensions = file_type.extensions();
      let bitmap_decoder_id = if extensions.contains(&"png") {
        BitmapDecoder::PngDecoderId()?
      } else if extensions.contains(&"jpg") || extensions.contains(&"jpeg") {
        BitmapDecoder::JpegDecoderId()?
      } else if extensions.contains(&"bmp") {
        BitmapDecoder::BmpDecoderId()?
      } else if extensions.contains(&"tiff") {
        BitmapDecoder::TiffDecoderId()?
      } else if extensions.contains(&"gif") {
        BitmapDecoder::GifDecoderId()?
      } else if extensions.contains(&"jxr") {
        BitmapDecoder::JpegXRDecoderId()?
      } else if extensions.contains(&"webp") {
        BitmapDecoder::WebpDecoderId()?
      } else if extensions.contains(&"heif") {
        BitmapDecoder::HeifDecoderId()?
      } else {
        return Err(Error::new(E_ACCESSDENIED, "Could not recognize file"));
      };
      let stream = InMemoryRandomAccessStream::new()?;
      let writer = DataWriter::CreateDataWriter(&stream)?;
      writer.WriteBytes(image_buffer)?;
      writer.StoreAsync()?; // flush buffer
      writer.FlushAsync()?;
      stream.Seek(0)?;
      let bitmap =
        block_on(async { BitmapDecoder::CreateWithIdAsync(bitmap_decoder_id, &stream)?.await })?;

      block_on(async { bitmap.GetSoftwareBitmapAsync()?.await })
    }
  }
}
