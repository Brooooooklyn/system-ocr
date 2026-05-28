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
///
/// `confidenceOut` is written with the mean of every `DocumentObservation`'s
/// `confidence` value (see `DocumentObservation.confidence`, macOS 26 Vision
/// SDK). It is initialised to `0.0` at entry so error paths never leave
/// uninitialised memory visible to Rust.
@_cdecl("recognize_documents_from_path")
public func recognizeDocumentsFromPath(
  _ pathPtr: UnsafePointer<CChar>,
  _ langsPtr: UnsafePointer<CChar>?,
  _ confidenceOut: UnsafeMutablePointer<Float>,
  _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutablePointer<CChar>? {
  errorOut.pointee = nil
  confidenceOut.pointee = 0.0
  guard #available(macOS 26, *) else {
    errorOut.pointee = makeCString("RecognizeDocumentsRequest requires macOS 26 or later")
    return nil
  }

  let path = String(cString: pathPtr)
  let url = URL(fileURLWithPath: path)
  let langs = parseLangs(langsPtr)

  var resultPtr: UnsafeMutablePointer<CChar>? = nil
  var errorPtr: UnsafeMutablePointer<CChar>? = nil
  var confidence: Float = 0.0
  let semaphore = DispatchSemaphore(value: 0)

  Task {
    defer { semaphore.signal() }
    do {
      var request = RecognizeDocumentsRequest()
      applyLanguageHints(&request, langs: langs)
      applyDocumentOptions(&request)
      let observations = try await request.perform(on: url)
      confidence = averageConfidence(observations)
      resultPtr = makeCString(formatObservations(observations))
    } catch {
      errorPtr = makeCString(error.localizedDescription)
    }
  }

  semaphore.wait()
  errorOut.pointee = errorPtr
  confidenceOut.pointee = confidence
  return resultPtr
}

/// Perform document recognition on raw image bytes.
///
/// `confidenceOut` is written with the mean of every `DocumentObservation`'s
/// `confidence` value (see `DocumentObservation.confidence`, macOS 26 Vision
/// SDK). It is initialised to `0.0` at entry so error paths never leave
/// uninitialised memory visible to Rust.
@_cdecl("recognize_documents_from_data")
public func recognizeDocumentsFromData(
  _ dataPtr: UnsafePointer<UInt8>,
  _ length: Int,
  _ langsPtr: UnsafePointer<CChar>?,
  _ confidenceOut: UnsafeMutablePointer<Float>,
  _ errorOut: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
) -> UnsafeMutablePointer<CChar>? {
  errorOut.pointee = nil
  confidenceOut.pointee = 0.0
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
  var confidence: Float = 0.0
  let semaphore = DispatchSemaphore(value: 0)

  Task {
    defer { semaphore.signal() }
    do {
      var request = RecognizeDocumentsRequest()
      applyLanguageHints(&request, langs: langs)
      applyDocumentOptions(&request)
      let observations = try await request.perform(on: cgImage)
      confidence = averageConfidence(observations)
      resultPtr = makeCString(formatObservations(observations))
    } catch {
      errorPtr = makeCString(error.localizedDescription)
    }
  }

  semaphore.wait()
  errorOut.pointee = errorPtr
  confidenceOut.pointee = confidence
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

// MARK: - Document options
//
// `RecognizeDocumentsRequest` on macOS 26 ships with a default
// `textRecognitionOptions.minimumTextHeightFraction` of `0.03125` (3.125%) —
// roughly four times the legacy `VNRecognizeTextRequest` value used in the
// fallback path (`0.008`). Without this override, small text (footnotes,
// captions, table fine print) is silently dropped from the structured-document
// transcript even though `VNRecognizeTextRequest` would have picked it up.
// Match the legacy threshold so both code paths see the same text.
@available(macOS 26, *)
private func applyDocumentOptions(_ request: inout RecognizeDocumentsRequest) {
  var opts = request.textRecognitionOptions
  opts.minimumTextHeightFraction = 0.008
  request.textRecognitionOptions = opts
}

// MARK: - Confidence

/// Average per-line confidence across every `RecognizedTextObservation`
/// reachable from the returned documents.
///
/// We deliberately aggregate at the line level (`RecognizedTextObservation`,
/// see Vision.swiftinterface line ~1374 where `confidence: Swift.Float` is
/// declared) rather than at `DocumentObservation.confidence` (line ~2632) —
/// the document-level value collapses to a single number per page and on the
/// macOS 26 SDK is typically `0.0`, whereas the line-level values are the
/// same per-observation confidences that the legacy `VNRecognizeTextRequest`
/// path averages in `perform_ocr_legacy`. This keeps the two paths reporting
/// confidence values on the same scale.
@available(macOS 26, *)
private func averageConfidence(_ observations: [DocumentObservation]) -> Float {
  var total: Float = 0.0
  var count = 0
  for obs in observations {
    for line in obs.document.text.lines {
      total += line.confidence
      count += 1
    }
  }
  guard count > 0 else { return 0.0 }
  return total / Float(count)
}

// MARK: - Formatting

@available(macOS 26, *)
private func formatObservations(_ observations: [DocumentObservation]) -> String {
  observations.map { formatDocument($0.document) }.joined(separator: "\n\n")
}

/// Internal block produced by `formatDocument` before it joins to the final
/// transcript. Each block carries the rendered text plus the top-edge y of
/// its bounding region (in Vision's lower-left normalised coordinates) so we
/// can sort blocks into document reading order.
@available(macOS 26, *)
private struct DocumentBlock {
  let text: String
  /// Top edge of the block in Vision's normalised (lower-left origin)
  /// coordinate space. Larger values are HIGHER on the page, so sorting by
  /// `topEdge` descending yields top-to-bottom reading order.
  let topEdge: CGFloat
}

/// Compute the top-edge y of a `BoundingRegionProviding` block in
/// Vision's normalised (lower-left origin) coordinates. Vision exposes the
/// bounding region via `boundingRegion.boundingBox`, a `NormalizedRect`
/// whose `origin.y + height` corresponds to the top of the rect.
@available(macOS 26, *)
private func topEdge(of region: NormalizedRegion) -> CGFloat {
  let rect = region.boundingBox
  return rect.origin.y + rect.height
}

@available(macOS 26, *)
private func formatDocument(_ container: DocumentObservation.Container) -> String {
  // Render every text surface that `DocumentObservation.Container` exposes —
  // title, paragraphs, lists, tables — while keying dedup on
  // `RecognizedTextObservation.uuid` so that two distinct observations whose
  // transcripts happen to match (a repeated label, status, date, etc.) are
  // not silently dropped.
  //
  // The previous implementation bucketed by structure type (title, then
  // paragraphs, then lists, then tables), which destroyed document reading
  // order — a paragraph between two tables would jump to the prose section
  // ahead of both tables. We now collect every top-level block with its
  // bounding-region top edge (Vision exposes `boundingRegion: NormalizedRegion`
  // on `Container.Text`, `Container.Table`, and `Container.List` — see
  // Vision.swiftinterface lines 2455-2620) and re-emit them in spatial
  // (top-to-bottom) order. Each block type still uses its dedicated
  // formatter (TSV for tables, marker+text for list items, joined
  // transcripts for paragraphs/titles), and line-level UUID dedup still
  // prevents the same observation from being emitted twice when it appears
  // inside a nested structure.

  // Phase 1: pre-collect every line UUID owned by nested structures
  // (tables/lists/title) so plain paragraph emission can skip them. Doing
  // this in a separate pass keeps dedup deterministic regardless of the
  // order in which blocks happen to be rendered.
  var consumedLineIDs: Set<UUID> = []
  if let title = container.title {
    for line in title.lines {
      consumedLineIDs.insert(line.uuid)
    }
  }
  for table in container.tables {
    collectContainerLineIDs(table.cellsContainerLineIDs, into: &consumedLineIDs)
  }
  for list in container.lists {
    for item in list.items {
      collectContainerLineIDs(allLineIDs(in: item.content), into: &consumedLineIDs)
    }
  }

  // Phase 2: build the spatially-ordered block list.
  var blocks: [DocumentBlock] = []

  if let title = container.title {
    let titleText = title.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    if !titleText.isEmpty {
      blocks.append(DocumentBlock(text: titleText, topEdge: topEdge(of: title.boundingRegion)))
    }
  }

  for paragraph in container.paragraphs {
    let kept = paragraph.lines.filter { !consumedLineIDs.contains($0.uuid) }
    if kept.isEmpty { continue }
    for line in kept {
      consumedLineIDs.insert(line.uuid)
    }
    let text = kept.map { $0.transcript }.joined(separator: "\n")
    if text.isEmpty { continue }
    blocks.append(DocumentBlock(text: text, topEdge: topEdge(of: paragraph.boundingRegion)))
  }

  for list in container.lists {
    var lines: [String] = []
    for item in list.items {
      let body = item.itemString.isEmpty ? item.content.text.transcript : item.itemString
      let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedBody.isEmpty { continue }
      let marker = item.markerString.trimmingCharacters(in: .whitespacesAndNewlines)
      if marker.isEmpty {
        lines.append(trimmedBody)
      } else {
        lines.append("\(marker) \(trimmedBody)")
      }
    }
    if lines.isEmpty { continue }
    blocks.append(
      DocumentBlock(text: lines.joined(separator: "\n"), topEdge: topEdge(of: list.boundingRegion))
    )
  }

  for table in container.tables {
    let rendered = formatTable(table)
    if rendered.isEmpty { continue }
    blocks.append(DocumentBlock(text: rendered, topEdge: topEdge(of: table.boundingRegion)))
  }

  // Phase 3: sort top-to-bottom. Vision's normalised coordinate origin is
  // the LOWER-left of the image, so a larger `topEdge` value is higher up
  // on the page — descending order gives reading order. Use a stable sort
  // (via `enumerated()` tiebreaker on the original index) so blocks with
  // identical (or near-identical) top edges retain their emission order.
  let sortedBlocks = blocks.enumerated().sorted { lhs, rhs in
    if lhs.element.topEdge != rhs.element.topEdge {
      return lhs.element.topEdge > rhs.element.topEdge
    }
    return lhs.offset < rhs.offset
  }
  var sections = sortedBlocks.map { $0.element.text }

  // Phase 4: safety net — append any line surfaced only by the top-level
  //   `container.text.lines` and not yet rendered above. Vision occasionally
  //   exposes stray lines (captions, footnotes, etc.) that don't belong to
  //   any paragraph/list/table — without this fallback they would be
  //   dropped. The leftover bucket is intentionally placed at the end (its
  //   relative order to in-flow blocks can't be recovered without a bounding
  //   region per line group, and we already preserve per-line order within
  //   the bucket via `container.text.lines`).
  let leftover = container.text.lines.filter { !consumedLineIDs.contains($0.uuid) }
  if !leftover.isEmpty {
    sections.append(leftover.map { $0.transcript }.joined(separator: "\n"))
  }

  return sections.joined(separator: "\n\n")
}

/// Recursively collect every `RecognizedTextObservation.uuid` reachable from a
/// nested `Container` (covers `Container.text.lines` plus any tables/lists the
/// container itself nests, e.g. a table cell containing a list).
@available(macOS 26, *)
private func allLineIDs(in container: DocumentObservation.Container) -> Set<UUID> {
  var ids: Set<UUID> = []
  for line in container.text.lines {
    ids.insert(line.uuid)
  }
  for table in container.tables {
    let rowCount = table.rows.count
    let colCount = table.columns.count
    for row in 0..<rowCount {
      for col in 0..<colCount {
        if let cell = table.cell(row: row, col: col) {
          ids.formUnion(allLineIDs(in: cell.content))
        }
      }
    }
  }
  for list in container.lists {
    for item in list.items {
      ids.formUnion(allLineIDs(in: item.content))
    }
  }
  return ids
}

@available(macOS 26, *)
private func collectContainerLineIDs(_ ids: Set<UUID>, into sink: inout Set<UUID>) {
  sink.formUnion(ids)
}

@available(macOS 26, *)
extension DocumentObservation.Container.Table {
  /// All line UUIDs owned by every cell in this table, computed once so the
  /// caller can dedup paragraphs against the cells without a doubly-nested
  /// loop.
  fileprivate var cellsContainerLineIDs: Set<UUID> {
    var ids: Set<UUID> = []
    let rowCount = rows.count
    let colCount = columns.count
    for row in 0..<rowCount {
      for col in 0..<colCount {
        if let cell = cell(row: row, col: col) {
          ids.formUnion(allLineIDs(in: cell.content))
        }
      }
    }
    return ids
  }
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
