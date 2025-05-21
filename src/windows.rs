use std::fs;

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

use crate::{OcrAccuracy, OcrError};

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
) -> std::result::Result<(String, f32), OcrError> {
  perform_ocr_win(image, _accuracy, preferred_langs)
    .map_err(|e| OcrError::WindowsError(e.to_string()))
}

pub(crate) fn perform_ocr_win(
  image: Either<String, Uint8Array>,
  _accuracy: OcrAccuracy,
  preferred_langs: Vec<String>,
) -> Result<(String, f32)> {
  let bitmap = open_image_as_bitmap(image)?;
  let engine = if let Some(lang) = preferred_langs.first() {
    let lang = Language::CreateLanguage(&HSTRING::from(lang))?;
    OcrEngine::TryCreateFromLanguage(&lang)?
  } else {
    OcrEngine::TryCreateFromUserProfileLanguages()?
  };

  let result = engine
    .RecognizeAsync(&bitmap)?
    .get()?
    .Text()?
    .to_string_lossy();

  Ok((result, 1.0))
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

      let file = StorageFile::GetFileFromPathAsync(&HSTRING::from(path))?.get()?;

      let bitmap = BitmapDecoder::CreateWithIdAsync(
        BitmapDecoder::PngDecoderId()?,
        &file.OpenAsync(FileAccessMode::Read)?.get()?,
      )?
      .get()?;

      bitmap.GetSoftwareBitmapAsync()?.get()
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
      let bitmap = BitmapDecoder::CreateWithIdAsync(bitmap_decoder_id, &stream)?.get()?;

      bitmap.GetSoftwareBitmapAsync()?.get()
    }
  }
}

#[cfg(test)]
mod tests {
  use crate::*;

  #[test]
  fn ocr_works() {
    let ocr_text: String = ocr("sample/sample.png").unwrap();
    assert_eq!(ocr_text, "Sample Text");
  }
}
