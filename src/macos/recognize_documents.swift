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

  // Collect all line transcripts from table cells to exclude from paragraphs
  var tableCellLines: Set<String> = []
  for table in container.tables {
    let rowCount = table.rows.count
    let colCount = table.columns.count
    for row in 0..<rowCount {
      for col in 0..<colCount {
        if let cell = table.cell(row: row, col: col) {
          tableCellLines.insert(cell.content.text.transcript)
        }
      }
    }
  }

  // Keep only paragraph lines whose text is NOT found in any table cell
  let nonTableParagraphs: [String] = container.paragraphs.compactMap { paragraph in
    let kept = paragraph.lines.filter { line in
      !tableCellLines.contains(line.transcript)
    }
    if kept.isEmpty { return nil }
    return kept.map { $0.transcript }.joined(separator: "\n")
  }
  let paragraphText = nonTableParagraphs.joined(separator: "\n\n")
  if !paragraphText.isEmpty {
    sections.append(paragraphText)
  }

  // Tables: formatted as ASCII
  for table in container.tables {
    sections.append(formatTable(table))
  }

  return sections.joined(separator: "\n\n")
}

@available(macOS 26, *)
private func formatTable(_ table: DocumentObservation.Container.Table) -> String {
  let rowCount = table.rows.count
  let colCount = table.columns.count
  guard rowCount > 0, colCount > 0 else { return "" }

  // Collect cell text
  var grid: [[String]] = Array(
    repeating: Array(repeating: "", count: colCount),
    count: rowCount
  )
  for row in 0..<rowCount {
    for col in 0..<colCount {
      if let cell = table.cell(row: row, col: col) {
        grid[row][col] = cell.content.text.transcript
      }
    }
  }

  // Compute column widths
  var widths = Array(repeating: 0, count: colCount)
  for row in grid {
    for (col, text) in row.enumerated() {
      widths[col] = max(widths[col], text.count)
    }
  }

  // Render
  let separator = "+" + widths.map { String(repeating: "-", count: $0 + 2) }.joined(separator: "+") + "+"
  var lines: [String] = [separator]
  for (i, row) in grid.enumerated() {
    let cells = row.enumerated().map { (col, text) in
      " " + text.padding(toLength: widths[col], withPad: " ", startingAt: 0) + " "
    }
    lines.append("|" + cells.joined(separator: "|") + "|")
    // Add separator after header row and at the end
    if i == 0 || i == grid.count - 1 {
      lines.append(separator)
    }
  }
  return lines.joined(separator: "\n")
}

// MARK: - Helpers

private func makeCString(_ string: String) -> UnsafeMutablePointer<CChar> {
  let utf8 = Array(string.utf8CString)
  let buffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: utf8.count)
  _ = buffer.initialize(from: utf8)
  return buffer.baseAddress!
}
