import CoreGraphics
import Dispatch
import Foundation
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

  // Pass the bytes to Vision as `Data` end-to-end. The
  // `ImageProcessingRequest.perform(on data: Data, orientation:)` overload
  // (Vision.swiftinterface line 593) parses the file format internally and
  // honours EXIF orientation, matching the behaviour of the URL overload
  // (line 589). Decoding to a CGImage first would silently discard the
  // EXIF orientation tag and mis-rotate phone JPEG/HEIC buffers.
  let data = Data(bytes: dataPtr, count: length)
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
      let observations = try await request.perform(on: data)
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
/// transcript. Each block carries the rendered text plus enough of its
/// bounding region to place it in two-dimensional reading order.
///
/// Coordinates are stored in a TOP-LEFT origin space (top = `1.0 -
/// (rect.origin.y + rect.height)`, with the original `NormalizedRect`
/// reported by Vision living in a LOWER-LEFT origin space — see
/// Vision.swiftinterface line 1306 `public struct NormalizedRect` and lines
/// 1315–1322 exposing `origin: CGPoint`, `width: CGFloat`, `height:
/// CGFloat`). With top-left semantics a SMALLER `top` is HIGHER on the page,
/// which lets the comparator read like normal English reading order
/// (top-to-bottom, then left-to-right within a row).
@available(macOS 26, *)
private struct DocumentBlock {
  let text: String
  /// Top edge of the block in TOP-LEFT-origin normalised coordinates.
  /// Smaller = higher on the page.
  let top: CGFloat
  /// Left edge of the block in TOP-LEFT-origin normalised coordinates
  /// (same as Vision's `origin.x`, which is already left-origin).
  let left: CGFloat
}

/// Compute the top edge of a `BoundingRegionProviding` block in TOP-LEFT
/// origin normalised coordinates. Vision exposes the bounding region via
/// `boundingRegion.boundingBox` — a `NormalizedRect`
/// (Vision.swiftinterface line 1306) whose `origin: CGPoint`
/// (line 1315) is in the LOWER-LEFT corner of the rect. The TOP edge in
/// lower-left coordinates is `origin.y + height`, and converting to a
/// top-left origin is therefore `1.0 - (origin.y + height)`.
@available(macOS 26, *)
private func topEdge(of region: NormalizedRegion) -> CGFloat {
  let rect = region.boundingBox
  return 1.0 - (rect.origin.y + rect.height)
}

/// Left edge of a `BoundingRegionProviding` block in normalised coordinates.
/// `NormalizedRect.origin.x` (Vision.swiftinterface line 1306, fields
/// 1315–1322) is already a left-origin value so no conversion is needed.
@available(macOS 26, *)
private func leftEdge(of region: NormalizedRegion) -> CGFloat {
  region.boundingBox.origin.x
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
      blocks.append(
        DocumentBlock(
          text: titleText,
          top: topEdge(of: title.boundingRegion),
          left: leftEdge(of: title.boundingRegion)
        ))
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
    blocks.append(
      DocumentBlock(
        text: text,
        top: topEdge(of: paragraph.boundingRegion),
        left: leftEdge(of: paragraph.boundingRegion)
      ))
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
      DocumentBlock(
        text: lines.joined(separator: "\n"),
        top: topEdge(of: list.boundingRegion),
        left: leftEdge(of: list.boundingRegion)
      ))
  }

  for table in container.tables {
    let rendered = formatTable(table)
    if rendered.isEmpty { continue }
    blocks.append(
      DocumentBlock(
        text: rendered,
        top: topEdge(of: table.boundingRegion),
        left: leftEdge(of: table.boundingRegion)
      ))
  }

  // Phase 3: safety net — fold any line surfaced only by the top-level
  //   `container.text.lines` and not yet rendered above into the same
  //   spatial sort. Vision occasionally exposes stray lines (captions,
  //   footnotes, sidebars) that don't belong to any paragraph/list/table.
  //   Each `RecognizedTextObservation` exposes its own `boundingRegion`
  //   (Vision.swiftinterface line 1366), so we can place those leftovers in
  //   reading order alongside the in-flow blocks rather than dumping them at
  //   the end.
  for line in container.text.lines where !consumedLineIDs.contains(line.uuid) {
    let transcript = line.transcript
    if transcript.isEmpty { continue }
    blocks.append(
      DocumentBlock(
        text: transcript,
        top: topEdge(of: line.boundingRegion),
        left: leftEdge(of: line.boundingRegion)
      ))
  }

  // Phase 4: sort into reading order. Blocks whose top edges fall within a
  //   small vertical tolerance (`rowBandTolerance`) are treated as belonging
  //   to the SAME row band and ordered left-to-right within that band — this
  //   keeps multi-column layouts, side-by-side labels+values, and captions
  //   next to images from being interleaved across columns. Outside that
  //   tolerance the comparator falls back to top-to-bottom ordering.
  //   `enumerated()` provides a stable tiebreaker on the original emission
  //   order when both top AND left coincide exactly.
  //
  //   `0.015` (~1.5% of the normalised page height) is empirically the
  //   sweet spot for typical pages: small enough that two visually distinct
  //   rows aren't merged, large enough to absorb the per-block top-edge
  //   jitter Vision introduces when blocks of different heights share a row
  //   (e.g. a paragraph next to a single-line caption). Values in the
  //   0.005–0.02 range all work for common document layouts.
  let rowBandTolerance: CGFloat = 0.015
  // Sort by top first, then walk top-to-bottom assigning each block to a row
  // band: a new band starts whenever the next block's top exceeds the
  // current band's top by more than the tolerance. Bucketing first gives a
  // deterministic, transitive order — a single comparator that mixes the
  // tolerance check with a top-edge fallback would not be transitive (A and
  // B can share a band, B and C can share a band, while A and C don't).
  let byTopThenOffset = blocks.enumerated().sorted { lhs, rhs in
    if lhs.element.top != rhs.element.top {
      return lhs.element.top < rhs.element.top
    }
    return lhs.offset < rhs.offset
  }
  var banded: [(band: Int, block: DocumentBlock, offset: Int)] = []
  var currentBand = 0
  var bandTop: CGFloat = byTopThenOffset.first?.element.top ?? 0
  for entry in byTopThenOffset {
    if entry.element.top - bandTop > rowBandTolerance {
      currentBand += 1
      bandTop = entry.element.top
    }
    banded.append((currentBand, entry.element, entry.offset))
  }
  let sortedBlocks = banded.sorted { lhs, rhs in
    if lhs.band != rhs.band {
      return lhs.band < rhs.band
    }
    if lhs.block.left != rhs.block.left {
      return lhs.block.left < rhs.block.left
    }
    return lhs.offset < rhs.offset
  }
  let sections = sortedBlocks.map { $0.block.text }

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
