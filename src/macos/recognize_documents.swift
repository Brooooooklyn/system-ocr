import CoreGraphics
import Dispatch
import Foundation
import Vision

// MARK: - C-compatible entry points
//
// ABI version. Returned by `recognize_documents_abi_version` so the Rust
// loader can refuse to call into a sidecar whose `@_cdecl` signatures don't
// match what it was compiled against (stale dylib left over from a partial
// upgrade, cache restore, manual bundle, etc.). BUMP whenever any other
// `@_cdecl` in this file changes signature (parameter count, parameter
// types, return type). Pair every bump with a matching bump of
// `EXPECTED_ABI_VERSION` in `src/macos/documents.rs`.
@_cdecl("recognize_documents_abi_version")
public func recognizeDocumentsAbiVersion() -> UInt32 {
  return 1
}

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
/// transcript. Each block carries the rendered text plus the set of
/// `RecognizedTextObservation.uuid`s it owns. The UUID set drives the
/// reading-order walk in Phase 4 (`container.text.lines` is column-aware
/// reading order; we emit a block the first time any of its lines surfaces in
/// that walk).
@available(macOS 26, *)
private struct DocumentBlock {
  let text: String
  /// All `RecognizedTextObservation.uuid`s owned by this block. Empty for
  /// stray lines that aren't tied to any structured surface.
  let lineIDs: Set<UUID>
}

@available(macOS 26, *)
private func formatDocument(_ container: DocumentObservation.Container) -> String {
  // Render every text surface that `DocumentObservation.Container` exposes —
  // title, paragraphs, lists, tables — while keying dedup on
  // `RecognizedTextObservation.uuid` so that two distinct observations whose
  // transcripts happen to match (a repeated label, status, date, etc.) are
  // not silently dropped.
  //
  // Reading-order strategy: instead of sorting blocks by their bounding-box
  // top/left (which interleaves columns in multi-column prose, e.g.
  // LR-LR-LR rather than LL-RR), we walk `container.text.lines` — Vision's
  // own column-aware natural reading order — and emit each top-level block
  // the FIRST time any line it owns is encountered. Tables and lists fall
  // into place naturally because their constituent line UUIDs also appear
  // in `container.text.lines`.

  // Vision sometimes reports a title whose `lines` array is empty (e.g. a
  // single styled heading that is also surfaced as a paragraph). When that
  // happens we can't dedup the title against paragraphs by UUID, so the same
  // text gets emitted twice (once as the orphan title block, once as the
  // paragraph). Resolve the title's line UUIDs by matching its transcript
  // against `container.text.lines` so the title joins the normal UUID dedup
  // path. If nothing matches (a genuinely standalone title), the set stays
  // empty and the existing defensive append still preserves it.
  let titleLineIDs: Set<UUID> = {
    guard let title = container.title else { return [] }
    let direct = Set(title.lines.map { $0.uuid })
    if !direct.isEmpty { return direct }
    let titleText = title.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    if titleText.isEmpty { return [] }
    return Set(
      container.text.lines
        .filter { $0.transcript.trimmingCharacters(in: .whitespacesAndNewlines) == titleText }
        .map { $0.uuid })
  }()

  // Phase 1: pre-collect every line UUID owned by nested structures
  // (tables/lists/title) so plain paragraph emission can skip them. Doing
  // this in a separate pass keeps dedup deterministic regardless of the
  // order in which blocks happen to be rendered.
  var consumedLineIDs: Set<UUID> = []
  consumedLineIDs.formUnion(titleLineIDs)
  for table in container.tables {
    collectContainerLineIDs(table.cellsContainerLineIDs, into: &consumedLineIDs)
  }
  for list in container.lists {
    for item in list.items {
      collectContainerLineIDs(allLineIDs(in: item.content), into: &consumedLineIDs)
    }
  }

  // Phase 2: build the block list. Each block records the line UUIDs it
  // owns so Phase 4 can place it in reading order.
  var blocks: [DocumentBlock] = []

  if let title = container.title {
    let titleText = title.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    if !titleText.isEmpty {
      let ids = titleLineIDs
      blocks.append(DocumentBlock(text: titleText, lineIDs: ids))
    }
  }

  for paragraph in container.paragraphs {
    let paragraphLineIDs = Set(paragraph.lines.map { $0.uuid })
    let alreadyConsumed = paragraphLineIDs.intersection(consumedLineIDs)
    // Skip paragraphs whose every line was already claimed by a
    // table/list/title surface (dedup against nested structures).
    if alreadyConsumed.count == paragraphLineIDs.count { continue }

    // Two joining policies:
    //   * No filter applied -> emit `paragraph.transcript` verbatim so
    //     Vision's own intra-paragraph joining (typically spaces for prose,
    //     newlines for poetry/addresses) is preserved.
    //   * Some lines suppressed -> rebuild from the surviving lines and
    //     join with a single space, mirroring the legacy
    //     `VNRecognizeTextRequest` path which concatenates per-observation
    //     transcripts with spaces.
    let text: String
    let keptIDs: Set<UUID>
    if alreadyConsumed.isEmpty {
      text = paragraph.transcript
      keptIDs = paragraphLineIDs
    } else {
      let kept = paragraph.lines.filter { !consumedLineIDs.contains($0.uuid) }
      text = kept.map { $0.transcript }.joined(separator: " ")
      keptIDs = Set(kept.map { $0.uuid })
    }

    for id in keptIDs {
      consumedLineIDs.insert(id)
    }
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
    blocks.append(DocumentBlock(text: text, lineIDs: keptIDs))
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
    var ids: Set<UUID> = []
    for item in list.items {
      ids.formUnion(allLineIDs(in: item.content))
    }
    blocks.append(DocumentBlock(text: lines.joined(separator: "\n"), lineIDs: ids))
  }

  for table in container.tables {
    let rendered = formatTable(table)
    if rendered.isEmpty { continue }
    blocks.append(DocumentBlock(text: rendered, lineIDs: table.cellsContainerLineIDs))
  }

  // Phase 3: emit blocks in reading order by walking `container.text.lines`
  // — Vision returns these in natural reading order, including column-aware
  // ordering for multi-column layouts. Each block is emitted the first time
  // ANY of its owned lines is encountered. Stray lines (no owning block) are
  // emitted in place as standalone transcripts.
  let blockIndexByLine: [UUID: Int] = {
    var map: [UUID: Int] = [:]
    for (i, block) in blocks.enumerated() {
      for id in block.lineIDs {
        // First writer wins; a line nominally owned by two structures
        // (rare — typically only happens when nested dedup missed) is
        // attributed to the earlier-collected structure.
        if map[id] == nil { map[id] = i }
      }
    }
    return map
  }()

  var emitted = Array(repeating: false, count: blocks.count)
  var sections: [String] = []
  for line in container.text.lines {
    if let idx = blockIndexByLine[line.uuid] {
      if !emitted[idx] {
        emitted[idx] = true
        sections.append(blocks[idx].text)
      }
    } else {
      // Stray line not owned by any structured block — emit it in place.
      let transcript = line.transcript
      if !transcript.isEmpty {
        sections.append(transcript)
      }
    }
  }

  // Defensive: append any block that owned UUIDs not present in
  // `container.text.lines` (shouldn't happen, but a structure synthesised
  // without a matching line surface would otherwise be dropped).
  for (i, block) in blocks.enumerated() where !emitted[i] {
    sections.append(block.text)
  }

  return sections.joined(separator: "\n\n")
}

/// Collect every `RecognizedTextObservation.uuid` owned by a nested container.
///
/// `Container.text.lines` is already the flattened text surface for that
/// container. Do not recurse through `tables` or `lists` here: Vision can
/// expose an item's owning list again through `item.content.lists`, so treating
/// the structure as an acyclic tree causes unbounded recursion.
@available(macOS 26, *)
private func allLineIDs(in container: DocumentObservation.Container) -> Set<UUID> {
  Set(container.text.lines.map { $0.uuid })
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
  // Merged cells (macOS 26 Vision exposes `Cell.rowRange` /
  // `Cell.columnRange` as `ClosedRange<Int>` — see Vision.swiftinterface
  // lines 2461 and 2464) span multiple `(row, col)` coordinates and
  // `table.cell(row:col:)` returns the same `Cell` for every coordinate the
  // merged region covers. Naively transcribing `cell.content.text.transcript`
  // at every coordinate would duplicate the merged text across the TSV.
  // Emit the transcript only at the cell's top-left anchor
  // (`rowRange.lowerBound`, `columnRange.lowerBound`) and leave the other
  // coordinates the merged cell covers as empty strings so TSV column
  // alignment stays consistent for downstream parsers.
  var rows: [String] = []
  for row in 0..<rowCount {
    var cells: [String] = []
    for col in 0..<colCount {
      let cell = table.cell(row: row, col: col)
      let text: String
      if let cell,
        row == cell.rowRange.lowerBound,
        col == cell.columnRange.lowerBound
      {
        // Cell transcripts can contain CR/LF/TAB which would break the TSV grid shape.
        text = cell.content.text.transcript
          .replacingOccurrences(of: "\r", with: " ")
          .replacingOccurrences(of: "\n", with: " ")
          .replacingOccurrences(of: "\t", with: " ")
      } else {
        text = ""
      }
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
