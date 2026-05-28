import CoreGraphics
import Dispatch
import Foundation
import ImageIO
import Vision

// MARK: - C-compatible entry points

/// Perform document recognition on an image at the given file path.
/// Returns a malloc'd C-string with the recognized text, or "ERROR:..." on failure.
/// Caller must free with `free_recognize_result`.
@_cdecl("recognize_documents_from_path")
public func recognizeDocumentsFromPath(
  _ pathPtr: UnsafePointer<CChar>
) -> UnsafeMutablePointer<CChar> {
  if #available(macOS 26, *) {
    let path = String(cString: pathPtr)
    let url = URL(fileURLWithPath: path)

    var resultPtr: UnsafeMutablePointer<CChar>? = nil
    let semaphore = DispatchSemaphore(value: 0)

    Task {
      defer { semaphore.signal() }
      do {
        let request = RecognizeDocumentsRequest()
        let observations = try await request.perform(on: url)
        resultPtr = makeCString(formatObservations(observations))
      } catch {
        resultPtr = makeCString("ERROR:" + error.localizedDescription)
      }
    }

    semaphore.wait()
    return resultPtr!
  } else {
    return makeCString("ERROR:RecognizeDocumentsRequest requires macOS 26 or later")
  }
}

/// Perform document recognition on raw image bytes.
/// Returns a malloc'd C-string with the recognized text, or "ERROR:..." on failure.
/// Caller must free with `free_recognize_result`.
@_cdecl("recognize_documents_from_data")
public func recognizeDocumentsFromData(
  _ dataPtr: UnsafePointer<UInt8>,
  _ length: Int
) -> UnsafeMutablePointer<CChar> {
  if #available(macOS 26, *) {
    let data = Data(bytes: dataPtr, count: length)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      return makeCString("ERROR:Failed to create image from data")
    }

    var resultPtr: UnsafeMutablePointer<CChar>? = nil
    let semaphore = DispatchSemaphore(value: 0)

    Task {
      defer { semaphore.signal() }
      do {
        let request = RecognizeDocumentsRequest()
        let observations = try await request.perform(on: cgImage)
        resultPtr = makeCString(formatObservations(observations))
      } catch {
        resultPtr = makeCString("ERROR:" + error.localizedDescription)
      }
    }

    semaphore.wait()
    return resultPtr!
  } else {
    return makeCString("ERROR:RecognizeDocumentsRequest requires macOS 26 or later")
  }
}

/// Free a result string previously returned by the recognize functions.
@_cdecl("free_recognize_result")
public func freeRecognizeResult(_ ptr: UnsafeMutablePointer<CChar>?) {
  ptr?.deallocate()
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
