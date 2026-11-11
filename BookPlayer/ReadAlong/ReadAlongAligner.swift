//
//  ReadAlongAligner.swift
//  BookPlayer
//
//  Gives every word of an ebook a time in its audiobook: the audio is transcribed on the device
//  with word timings (Speech's `SpeechTranscriber`), then the ebook's words are lined up with the
//  spoken ones.
//

import AVFoundation
import Foundation
import Speech

/// Times for the ebook's words, and how well the narration matched them
struct AlignmentResult: Equatable {
  var times: [TimeInterval]
  /// Ebook words matched to a spoken word
  var matchedWords: Int
  /// Spoken words the recognizer heard
  var heardWords: Int
  /// Too few matches to trust: the times are spread over the book by word count instead
  var isEstimated: Bool
}

struct SpokenWord: Equatable {
  let text: String
  /// Seconds into the whole book
  let start: TimeInterval
}

enum ReadAlongError: LocalizedError {
  case speechNotAllowed
  case languageNotSupported(String)
  case audioNotOnDevice
  case audioUnreadable
  case nothingHeard

  var errorDescription: String? {
    switch self {
    case .speechNotAllowed:
      return "read_along_speech_denied_error".localized
    case .languageNotSupported(let language):
      return String(format: "read_along_language_error".localized, language)
    case .audioNotOnDevice:
      return "read_along_audio_missing_error".localized
    case .audioUnreadable:
      return "read_along_audio_unreadable_error".localized
    case .nothingHeard:
      return "read_along_nothing_heard_error".localized
    }
  }
}

enum ReadAlongAligner {
  // MARK: - Matching the ebook to the narration

  /// Lowercased letters and digits only, without accents, so "Don’t," matches "don't"
  static func normalize(_ word: String) -> String {
    let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
  }

  /// A title reduced to letters and digits, for pairing an ebook with its audiobook
  static func normalizedTitle(_ title: String) -> String {
    normalize(title.replacingOccurrences(of: "_", with: " "))
  }

  /// A time for each of `bookWords`: when the narration says it, or, for words it skips or the
  /// recognizer missed, a time spread between the matched words around it. Never decreasing.
  ///
  /// Walks both lists in order. Each spoken word is looked for a few words ahead in the book; a
  /// match further than the very next word must be confirmed by the following word too, so a
  /// common word can't pull the position forward. After several spoken words in a row match
  /// nothing (an intro the ebook doesn't have, front matter the narrator skips), the position
  /// jumps to where the next four spoken words appear together in the book.
  static func align(bookWords: [String], spoken: [SpokenWord], duration: TimeInterval) -> AlignmentResult {
    let book = bookWords.map(normalize)
    let heard = spoken.map { (word: normalize($0.text), start: $0.start) }.filter { !$0.word.isEmpty }
    guard !book.isEmpty else {
      return AlignmentResult(times: [], matchedWords: 0, heardWords: heard.count, isEstimated: false)
    }
    guard !heard.isEmpty else {
      return AlignmentResult(
        times: fillGaps([TimeInterval?](repeating: nil, count: book.count), duration: duration),
        matchedWords: 0, heardWords: 0, isEstimated: true
      )
    }

    let lookahead = 40
    let missesBeforeResync = 8
    let resyncRange = 30_000

    var times = [TimeInterval?](repeating: nil, count: book.count)
    var position = 0
    var misses = 0
    /// The first spoken word of the current run of misses
    var firstMiss = 0
    var index = 0

    /// Where four spoken words from `from` appear together in the book, at or after `position`
    func findPhrase(from: Int) -> Int? {
      guard from + 3 < heard.count else { return nil }
      let phrase = heard[from...(from + 3)].map(\.word)
      let searchEnd = min(position + resyncRange, book.count - 3)
      guard searchEnd > position else { return nil }
      return (position..<searchEnd).first { start in
        book[start] == phrase[0] && book[start + 1] == phrase[1]
          && book[start + 2] == phrase[2] && book[start + 3] == phrase[3]
      }
    }

    while index < heard.count, position < book.count {
      let spokenWord = heard[index]
      let nextSpoken = index + 1 < heard.count ? heard[index + 1].word : nil
      let end = min(position + lookahead, book.count)
      var matched: Int?
      for candidate in position..<end where book[candidate] == spokenWord.word {
        let confirmed =
          candidate == position
          || nextSpoken == nil
          || candidate + 1 >= book.count
          || book[candidate + 1] == nextSpoken
        if confirmed {
          matched = candidate
          break
        }
      }

      if let matched {
        times[matched] = spokenWord.start
        position = matched + 1
        misses = 0
        index += 1
        continue
      }

      if misses == 0 { firstMiss = index }
      misses += 1

      if misses >= missesBeforeResync {
        if let found = findPhrase(from: firstMiss) {
          /// Found where the missed words are: match them again from there
          position = found
          index = firstMiss
          misses = 0
          continue
        }
        if let found = findPhrase(from: index) {
          times[found] = spokenWord.start
          position = found + 1
          misses = 0
          index += 1
          continue
        }
      }

      index += 1
    }

    let matched = times.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
    /// A real sync matches most of what was heard; a scatter of chance matches ("the", "and") from a
    /// different edition or language is no sync at all
    let isEstimated = matched < max(3, min(heard.count, book.count) / 4)
    let finalTimes = isEstimated
      ? fillGaps([TimeInterval?](repeating: nil, count: book.count), duration: duration)
      : fillGaps(times, duration: duration)
    return AlignmentResult(times: finalTimes, matchedWords: matched, heardWords: heard.count, isEstimated: isEstimated)
  }

  /// Unmatched words get times spread evenly between their matched neighbours; before the first
  /// match they're spread from the start of the book, after the last one to its end. With no
  /// match at all, every word gets an even share of the book.
  static func fillGaps(_ times: [TimeInterval?], duration: TimeInterval) -> [TimeInterval] {
    guard !times.isEmpty else { return [] }

    var anchors = times.enumerated().compactMap { index, time in time.map { (index, $0) } }
    let end = max(duration, anchors.last?.1 ?? 0)
    if anchors.first?.0 != 0 {
      anchors.insert((0, 0), at: 0)
    }
    if anchors.last?.0 != times.count - 1 {
      anchors.append((times.count - 1, end))
    }

    var result = [TimeInterval](repeating: 0, count: times.count)
    if anchors.count == 1 {
      result[0] = anchors[0].1
    }
    for (previous, next) in zip(anchors, anchors.dropFirst()) {
      let span = Double(max(next.0 - previous.0, 1))
      for index in previous.0...next.0 {
        let fraction = Double(index - previous.0) / span
        result[index] = previous.1 + (next.1 - previous.1) * fraction
      }
    }

    /// The narration can't go backwards: a mismatch can't be allowed to make the highlight jump back
    for index in result.indices.dropFirst() where result[index] < result[index - 1] {
      result[index] = result[index - 1]
    }
    return result
  }

  // MARK: - Transcribing the audiobook

  /// One audio file of the book and where it starts in the whole book
  struct AudioPart {
    let fileURL: URL
    let bookOffset: TimeInterval
  }

  static func requestSpeechPermission() async throws {
    let status = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    guard status == .authorized else { throw ReadAlongError.speechNotAllowed }
  }

  /// The recognizer's locale for the book's language (`en`, `en-GB`, `fr`…), else the device's
  static func transcriptionLocale(forLanguage language: String?) async throws -> Locale {
    let wanted = Locale(identifier: language ?? Locale.current.identifier)
    let supported = await SpeechTranscriber.supportedLocales

    if let exact = supported.first(where: { $0.identifier(.bcp47) == wanted.identifier(.bcp47) }) {
      return exact
    }
    let languageCode = wanted.language.languageCode
    let sameLanguage = supported.filter { $0.language.languageCode == languageCode }
    if let regional = sameLanguage.first(where: { $0.region == Locale.current.region }) ?? sameLanguage.first {
      return regional
    }
    throw ReadAlongError.languageNotSupported(
      Locale.current.localizedString(forIdentifier: wanted.identifier) ?? wanted.identifier
    )
  }

  /// Every word of the narration with its start time in the book. `progress` gets 0…1
  static func transcribe(
    parts: [AudioPart],
    locale: Locale,
    totalDuration: TimeInterval,
    progress: @escaping @MainActor (Double) -> Void
  ) async throws -> [SpokenWord] {
    var words = [SpokenWord]()

    for part in parts {
      try Task.checkCancellation()
      let partWords = try await transcribe(part: part, locale: locale) { seconds in
        let done = (part.bookOffset + seconds) / max(totalDuration, 1)
        Task { @MainActor in progress(min(done, 1)) }
      }
      words.append(contentsOf: partWords)
    }

    return words
  }

  private static func transcribe(
    part: AudioPart,
    locale: Locale,
    reachedSeconds: @escaping (TimeInterval) -> Void
  ) async throws -> [SpokenWord] {
    let transcriber = SpeechTranscriber(
      locale: locale,
      transcriptionOptions: [],
      reportingOptions: [],
      attributeOptions: [.audioTimeRange]
    )

    /// The on-device model for the language, downloaded once by the system
    if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
      try await installation.downloadAndInstall()
    }

    let (audioFile, cleanup) = try openAudioFile(part.fileURL)
    defer { cleanup() }

    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let offset = part.bookOffset

    let collector = Task { () -> [SpokenWord] in
      var words = [SpokenWord]()
      for try await result in transcriber.results {
        let text = result.text
        for run in text.runs {
          guard let timeRange = run.audioTimeRange else { continue }
          let piece = String(text[run.range].characters)
          let pieceWords = piece.split(whereSeparator: { $0.isWhitespace }).map(String.init)
          guard !pieceWords.isEmpty else { continue }

          /// A run is usually one word; when it holds several, spread them over its time
          let start = timeRange.start.seconds
          let step = timeRange.duration.seconds / Double(pieceWords.count)
          for (index, word) in pieceWords.enumerated() {
            let time = start + step * Double(index)
            guard time.isFinite else { continue }
            words.append(SpokenWord(text: word, start: offset + time))
          }
          reachedSeconds(timeRange.end.seconds)
        }
      }
      return words
    }

    do {
      if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
        try await analyzer.finalizeAndFinish(through: lastSample)
      } else {
        await analyzer.cancelAndFinishNow()
      }
    } catch {
      collector.cancel()
      await analyzer.cancelAndFinishNow()
      throw error
    }

    return try await withTaskCancellationHandler {
      try await collector.value
    } onCancel: {
      collector.cancel()
    }
  }

  /// The words in one stretch of one audio file, timed in the whole book. Read-along transcribes
  /// what's about to play this way, a stretch at a time, instead of the whole book up front
  static func transcribeSegment(
    of part: AudioPart,
    from fileStart: TimeInterval,
    length: TimeInterval,
    locale: Locale
  ) async throws -> [SpokenWord] {
    let segmentURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("read-along-segment-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at: segmentURL) }

    guard let segmentStart = try writeSegment(of: part.fileURL, from: fileStart, length: length, to: segmentURL) else {
      return []
    }

    return try await transcribe(
      part: AudioPart(fileURL: segmentURL, bookOffset: part.bookOffset + segmentStart),
      locale: locale
    ) { _ in }
  }

  /// Copies `length` seconds of the file from `fileStart` into an uncompressed file; returns where
  /// the copy starts in the file, or nil past its end. The written file closes when this returns
  private static func writeSegment(
    of fileURL: URL,
    from fileStart: TimeInterval,
    length: TimeInterval,
    to segmentURL: URL
  ) throws -> TimeInterval? {
    let (source, cleanup) = try openAudioFile(fileURL)
    defer { cleanup() }

    let format = source.processingFormat
    let rate = format.sampleRate
    let startFrame = AVAudioFramePosition(max(0, fileStart) * rate)
    guard startFrame < source.length else { return nil }

    let frames = AVAudioFrameCount(min(Double(source.length - startFrame), max(length, 0) * rate))
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }

    source.framePosition = startFrame
    try source.read(into: buffer, frameCount: frames)

    let output = try AVAudioFile(
      forWriting: segmentURL,
      settings: format.settings,
      commonFormat: format.commonFormat,
      interleaved: format.isInterleaved
    )
    try output.write(from: buffer)
    output.close()

    return Double(startFrame) / rate
  }

  /// `AVAudioFile` goes by the extension, and doesn't take `.m4b`: open those through an `.m4a` link
  private static func openAudioFile(_ url: URL) throws -> (AVAudioFile, () -> Void) {
    guard FileManager.default.fileExists(atPath: url.path) else { throw ReadAlongError.audioNotOnDevice }

    if let file = try? AVAudioFile(forReading: url) {
      return (file, {})
    }

    let link = FileManager.default.temporaryDirectory
      .appendingPathComponent("read-along-\(UUID().uuidString).m4a")
    do {
      try FileManager.default.linkItem(at: url, to: link)
    } catch {
      try FileManager.default.copyItem(at: url, to: link)
    }
    let cleanup = { try? FileManager.default.removeItem(at: link); return }
    do {
      return (try AVAudioFile(forReading: link), cleanup)
    } catch {
      cleanup()
      throw ReadAlongError.audioUnreadable
    }
  }
}

/// Finds where a stretch of narration is in the ebook, for live read-along. The ebook and the
/// audiobook needn't match word for word: runs of three words in a row that appear in both
/// vote for where the stretch is, then the words are matched one by one from there, and words
/// the ebook doesn't have are skipped.
struct ReadAlongMatcher: Sendable {
  struct Placement: Equatable, Sendable {
    let word: Int
    let time: TimeInterval
  }

  let book: [String]
  private let trigrams: [String: [Int]]

  init(bookWords: [String]) {
    let book = bookWords.map(ReadAlongAligner.normalize)
    var trigrams = [String: [Int]]()
    if book.count >= 3 {
      for index in 0..<(book.count - 2) {
        let a = book[index], b = book[index + 1], c = book[index + 2]
        guard !a.isEmpty, !b.isEmpty, !c.isEmpty else { continue }
        trigrams["\(a) \(b) \(c)", default: []].append(index)
      }
    }
    self.book = book
    self.trigrams = trigrams
  }

  /// The ebook words this narration covers, with when each is spoken. Empty when the stretch
  /// isn't in the ebook (or too little of it was heard to tell). `near`: the word the reader is
  /// at, preferred when several places match equally well
  func place(_ spoken: [SpokenWord], near: Int?) -> [Placement] {
    let heard = spoken
      .map { (word: ReadAlongAligner.normalize($0.text), start: $0.start) }
      .filter { !$0.word.isEmpty }
    guard heard.count >= 3, book.count >= 3 else { return [] }

    /// Each shared run of three words votes for an offset between the narration and the ebook
    var votes = [Int: Int]()
    for index in 0..<(heard.count - 2) {
      let key = "\(heard[index].word) \(heard[index + 1].word) \(heard[index + 2].word)"
      /// A phrase found all over the book ("and then he") says nothing about where this is
      guard let positions = trigrams[key], positions.count <= 25 else { continue }
      for position in positions {
        votes[position - index, default: 0] += 1
      }
    }
    guard !votes.isEmpty else { return [] }

    /// Offsets a few words apart are the same place (words added or dropped by the narrator)
    func score(_ offset: Int) -> Int {
      (offset - 4...offset + 4).reduce(0) { $0 + (votes[$1] ?? 0) }
    }
    let ranked = votes.keys.map { (offset: $0, score: score($0)) }
    let best = ranked.max { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score < rhs.score }
      guard let near else { return lhs.offset > rhs.offset }
      return abs(lhs.offset - near) > abs(rhs.offset - near)
    }
    /// Two or three shared phrases can be chance ("he said to her"); the real place shares many
    guard let best, best.score >= Self.minimumScore else { return [] }

    /// Another place that matches nearly as well makes this one a guess: unless it's the one next
    /// to where the reader is, wait for a clearer stretch rather than highlight the wrong passage
    let runnerUp = ranked
      .filter { abs($0.offset - best.offset) > 50 }
      .map(\.score)
      .max() ?? 0
    if runnerUp * 2 > best.score {
      guard let near, abs(best.offset - near) <= 1_500 else { return [] }
    }
    /// Far from where the reader is, only a strong match counts (the listener may have skipped, or
    /// a phrase repeats)
    if let near, abs(best.offset - near) > 1_500, best.score < 2 * Self.minimumScore { return [] }

    /// Match the words one by one from there
    var placements = [Placement]()
    var position = max(0, best.offset - 8)
    for (index, heardWord) in heard.enumerated() {
      guard position < book.count else { break }
      let next = index + 1 < heard.count ? heard[index + 1].word : nil
      let end = min(position + 25, book.count)
      for candidate in position..<end where book[candidate] == heardWord.word {
        let confirmed =
          candidate == position || next == nil || candidate + 1 >= book.count || book[candidate + 1] == next
        if confirmed {
          placements.append(Placement(word: candidate, time: heardWord.start))
          position = candidate + 1
          break
        }
      }
    }
    return placements.count >= max(4, heard.count / 4) ? placements : []
  }

  static let minimumScore = 4
}
