import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import Vision

// MARK: - C-compatible entry points
//
// ABI contract (shared by both `from_path` and `from_data` variants):
//   - Returns a non-NULL malloc'd C-string on success (the OCR text).
//     - An empty string signals "no text recognized"; callers should treat
//       it as a soft failure.
//     - `errorOut` is set to NULL on success.
//   - Returns NULL on failure. `errorOut` is set to a freshly-allocated
//     C-string with the error description. Callers MUST free both the
//     primary return value (if non-NULL) and `*errorOut` (if non-NULL) via
//     `free_recognize_result`.
//
// `langsPtr` is a NUL-terminated UTF-8 C string of comma-separated BCP-47
// language tags (e.g. "en-US" or "en-US,zh-Hans"). Passing NULL or an empty
// string leaves the recognizer to auto-detect.

/// Perform document recognition on an image at the given file path.
@_cdecl("recognize_documents_from_path")
public func recognizeDocumentsFromPath(
  _ pathPtr: UnsafePointer<CChar>,
  _ langsPtr: UnsafePointer<CChar>?,
  _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutablePointer<CChar>? {
  errorOut.pointee = nil
  guard #available(macOS 26, *) else {
    errorOut.pointee = makeCString("RecognizeDocumentsRequest requires macOS 26 or later")
    return nil
  }

  let path = String(cString: pathPtr)
  let url = URL(fileURLWithPath: path)
  let langs = parseLangs(langsPtr)

  var resultPtr: UnsafeMutablePointer<CChar>? = nil
  var errorPtr: UnsafeMutablePointer<CChar>? = nil
  let semaphore = DispatchSemaphore(value: 0)

  Task {
    defer { semaphore.signal() }
    do {
      var request = RecognizeDocumentsRequest()
      applyLanguageHints(&request, langs: langs)
      let observations = try await request.perform(on: url)
      resultPtr = makeCString(formatObservations(observations))
    } catch {
      errorPtr = makeCString(error.localizedDescription)
    }
  }

  semaphore.wait()
  errorOut.pointee = errorPtr
  return resultPtr
}

/// Perform document recognition on raw image bytes.
@_cdecl("recognize_documents_from_data")
public func recognizeDocumentsFromData(
  _ dataPtr: UnsafePointer<UInt8>,
  _ length: Int,
  _ langsPtr: UnsafePointer<CChar>?,
  _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutablePointer<CChar>? {
  errorOut.pointee = nil
  guard #available(macOS 26, *) else {
    errorOut.pointee = makeCString("RecognizeDocumentsRequest requires macOS 26 or later")
    return nil
  }

  let data = Data(bytes: dataPtr, count: length)
  guard let source = CGImageSourceCreateWithData(data as CFData, nil),
    let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else {
    errorOut.pointee = makeCString("Failed to create image from data")
    return nil
  }

  let langs = parseLangs(langsPtr)

  var resultPtr: UnsafeMutablePointer<CChar>? = nil
  var errorPtr: UnsafeMutablePointer<CChar>? = nil
  let semaphore = DispatchSemaphore(value: 0)

  Task {
    defer { semaphore.signal() }
    do {
      var request = RecognizeDocumentsRequest()
      applyLanguageHints(&request, langs: langs)
      let observations = try await request.perform(on: cgImage)
      resultPtr = makeCString(formatObservations(observations))
    } catch {
      errorPtr = makeCString(error.localizedDescription)
    }
  }

  semaphore.wait()
  errorOut.pointee = errorPtr
  return resultPtr
}

/// Free a C string previously returned by the recognize functions (either the
/// primary return value or the `errorOut` out-parameter).
@_cdecl("free_recognize_result")
public func freeRecognizeResult(_ ptr: UnsafeMutablePointer<CChar>?) {
  ptr?.deallocate()
}

// MARK: - Language hint plumbing

private func parseLangs(_ langsPtr: UnsafePointer<CChar>?) -> [String] {
  guard let langsPtr else { return [] }
  let raw = String(cString: langsPtr)
  if raw.isEmpty { return [] }
  return raw.split(separator: ",").map { String($0) }.filter { !$0.isEmpty }
}

@available(macOS 26, *)
private func applyLanguageHints(
  _ request: inout RecognizeDocumentsRequest, langs: [String]
) {
  guard !langs.isEmpty else { return }
  var opts = request.textRecognitionOptions
  opts.recognitionLanguages = langs.map { Locale.Language(identifier: $0) }
  request.textRecognitionOptions = opts
}

// MARK: - Formatting

@available(macOS 26, *)
private func formatObservations(_ observations: [DocumentObservation]) -> String {
  observations.map { formatDocument($0.document) }.joined(separator: "\n\n")
}

@available(macOS 26, *)
private func formatDocument(_ container: DocumentObservation.Container) -> String {
  var sections: [String] = []

  // Collect the per-line identities owned by table cells so we can suppress
  // those same observations when emitting paragraphs. We key on
  // `RecognizedTextObservation.uuid` (geometry-tied to the source observation)
  // instead of the raw transcript — otherwise a paragraph line whose text
  // happens to match a table cell value (a repeated label, date, status, etc.)
  // would be silently dropped.
  var tableCellLineIDs: Set<UUID> = []
  for table in container.tables {
    let rowCount = table.rows.count
    let colCount = table.columns.count
    for row in 0..<rowCount {
      for col in 0..<colCount {
        if let cell = table.cell(row: row, col: col) {
          for line in cell.content.text.lines {
            tableCellLineIDs.insert(line.uuid)
          }
        }
      }
    }
  }

  // Keep only paragraph lines whose observation identity is NOT owned by any
  // table cell.
  let nonTableParagraphs: [String] = container.paragraphs.compactMap { paragraph in
    let kept = paragraph.lines.filter { line in
      !tableCellLineIDs.contains(line.uuid)
    }
    if kept.isEmpty { return nil }
    return kept.map { $0.transcript }.joined(separator: "\n")
  }
  let paragraphText = nonTableParagraphs.joined(separator: "\n\n")
  if !paragraphText.isEmpty {
    sections.append(paragraphText)
  }

  // Tables: rendered as plain tab-separated rows
  for table in container.tables {
    let rendered = formatTable(table)
    if !rendered.isEmpty {
      sections.append(rendered)
    }
  }

  return sections.joined(separator: "\n\n")
}

@available(macOS 26, *)
private func formatTable(_ table: DocumentObservation.Container.Table) -> String {
  let rowCount = table.rows.count
  let colCount = table.columns.count
  guard rowCount > 0, colCount > 0 else { return "" }
  var rows: [String] = []
  for row in 0..<rowCount {
    var cells: [String] = []
    for col in 0..<colCount {
      let text = table.cell(row: row, col: col)?.content.text.transcript ?? ""
      cells.append(text)
    }
    rows.append(cells.joined(separator: "\t"))
  }
  return rows.joined(separator: "\n")
}

// MARK: - Helpers

private func makeCString(_ string: String) -> UnsafeMutablePointer<CChar> {
  let utf8 = Array(string.utf8CString)
  let buffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: utf8.count)
  _ = buffer.initialize(from: utf8)
  return buffer.baseAddress!
}
