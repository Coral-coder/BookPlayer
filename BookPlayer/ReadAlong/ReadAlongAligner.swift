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

    guard let segmentStart = try await writeSegment(of: part.fileURL, from: fileStart, length: length, to: segmentURL) else {
      return []
    }

    return try await transcribe(
      part: AudioPart(fileURL: segmentURL, bookOffset: part.bookOffset + segmentStart),
      locale: locale
    ) { _ in }
  }

  /// Copies `length` seconds of the file from `fileStart` into an uncompressed 16 kHz mono file;
  /// returns where the copy really starts in the file, or nil past its end.
  ///
  /// Read with `AVAssetReader` on an asset opened with precise timing, as the player opens it, so
  /// both use one timeline: decoding a compressed file by frame count (`AVAudioFile`) can land
  /// seconds away from the player's clock, and the highlight then follows the wrong moment
  private static func writeSegment(
    of fileURL: URL,
    from fileStart: TimeInterval,
    length: TimeInterval,
    to segmentURL: URL
  ) async throws -> TimeInterval? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { throw ReadAlongError.audioNotOnDevice }

    let asset = AVURLAsset(url: fileURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw ReadAlongError.audioUnreadable
    }
    let duration = try await asset.load(.duration).seconds
    guard fileStart < duration else { return nil }

    guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)
    else { throw ReadAlongError.audioUnreadable }

    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(
      start: CMTime(seconds: max(0, fileStart), preferredTimescale: 44_100),
      duration: CMTime(seconds: max(length, 0.1), preferredTimescale: 44_100)
    )
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16_000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw ReadAlongError.audioUnreadable }
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? ReadAlongError.audioUnreadable }

    let file = try AVAudioFile(
      forWriting: segmentURL,
      settings: format.settings,
      commonFormat: .pcmFormatInt16,
      interleaved: true
    )
    var firstTime: TimeInterval?
    while let sampleBuffer = output.copyNextSampleBuffer() {
      let frames = CMSampleBufferGetNumSamples(sampleBuffer)
      guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
      else { continue }
      let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
        sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
      )
      guard status == noErr else { continue }
      buffer.frameLength = AVAudioFrameCount(frames)
      if firstTime == nil {
        /// Where the decoded audio really starts, on the player's timeline
        let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        firstTime = start.isFinite ? start : fileStart
      }
      try file.write(from: buffer)
    }
    file.close()

    guard reader.status != .failed else { throw reader.error ?? ReadAlongError.audioUnreadable }
    return firstTime
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
/// audiobook needn't match word for word. The anchors are four-word phrases the narration and the
/// ebook share that occur only once in the part of the ebook searched; of those, only the longest
/// run that's in the same order in both counts, so a phrase that happens to match elsewhere can't
/// move the highlight. Words between two anchors are matched in order, and words the ebook doesn't
/// have are skipped.
struct ReadAlongMatcher: Sendable {
  struct Placement: Equatable, Sendable {
    let word: Int
    let time: TimeInterval
  }

  let book: [String]
  /// Where each four-word phrase starts in the ebook
  private let phrases: [String: [Int]]

  static let phraseLength = 4

  init(bookWords: [String]) {
    let book = bookWords.map(ReadAlongAligner.normalize)
    var phrases = [String: [Int]]()
    var index = 0
    /// Phrases are built from the words that have letters or digits, so "—" between two words
    /// doesn't break one
    let indexed = book.indices.filter { !book[$0].isEmpty }
    while index + Self.phraseLength <= indexed.count {
      let key = indexed[index..<(index + Self.phraseLength)].map { book[$0] }.joined(separator: " ")
      phrases[key, default: []].append(indexed[index])
      index += 1
    }
    self.book = book
    self.phrases = phrases
  }

  /// The ebook words this narration covers, with when each is spoken. Empty when the stretch
  /// isn't in the ebook, or too little of it was heard to be sure. `near`: the word the reader is
  /// at; the stretch is looked for just around it first, then anywhere in the ebook
  func place(_ spoken: [SpokenWord], near: Int?) -> [Placement] {
    let heard = spoken
      .map { (word: ReadAlongAligner.normalize($0.text), start: $0.start) }
      .filter { !$0.word.isEmpty }
    guard heard.count >= Self.phraseLength else { return [] }

    if let near {
      let region = max(0, near - 1_500)..<min(book.count, near + 5_000)
      let placements = place(heard, in: region, minimumAnchors: 2)
      if !placements.isEmpty { return placements }
    }
    return place(heard, in: 0..<book.count, minimumAnchors: 3)
  }

  private func place(
    _ heard: [(word: String, start: TimeInterval)],
    in region: Range<Int>,
    minimumAnchors: Int
  ) -> [Placement] {
    /// Anchors: a heard phrase found exactly once in the region
    var anchors = [(heard: Int, book: Int)]()
    for index in 0...(heard.count - Self.phraseLength) {
      let key = heard[index..<(index + Self.phraseLength)].map(\.word).joined(separator: " ")
      guard let positions = phrases[key] else { continue }
      let inRegion = positions.filter { region.contains($0) }
      guard inRegion.count == 1 else { continue }
      anchors.append((index, inRegion[0]))
    }
    guard anchors.count >= minimumAnchors else { return [] }

    let chain = Self.longestOrderedChain(anchors)
    guard chain.count >= minimumAnchors else { return [] }

    /// The anchors' words, then the words between two anchors, matched in order
    var placed = [Int: TimeInterval]()
    var bookWordsByHeard = [Int: Int]()
    for anchor in chain {
      var bookIndex = anchor.book
      for offset in 0..<Self.phraseLength {
        /// Skip ebook words without letters, as the phrase index does
        while bookIndex < book.count, book[bookIndex].isEmpty { bookIndex += 1 }
        guard bookIndex < book.count else { break }
        bookWordsByHeard[anchor.heard + offset] = bookIndex
        bookIndex += 1
      }
    }
    for (previous, next) in zip(chain, chain.dropFirst()) {
      var bookIndex = (bookWordsByHeard[previous.heard + Self.phraseLength - 1] ?? previous.book) + 1
      let bookEnd = next.book
      for heardIndex in (previous.heard + Self.phraseLength)..<max(previous.heard + Self.phraseLength, next.heard) {
        guard bookIndex < bookEnd else { break }
        if let found = (bookIndex..<min(bookEnd, bookIndex + 6)).first(where: { book[$0] == heard[heardIndex].word }) {
          bookWordsByHeard[heardIndex] = found
          bookIndex = found + 1
        }
      }
    }
    for (heardIndex, bookIndex) in bookWordsByHeard where heardIndex < heard.count {
      placed[bookIndex] = heard[heardIndex].start
    }

    return placed
      .map { Placement(word: $0.key, time: $0.value) }
      .sorted { $0.word < $1.word }
  }

  /// The longest run of anchors in the same order in the narration and the ebook, keeping roughly
  /// the same distance between them (a narrator adds or drops a few words, not pages)
  static func longestOrderedChain(_ anchors: [(heard: Int, book: Int)]) -> [(heard: Int, book: Int)] {
    guard !anchors.isEmpty else { return [] }
    var length = [Int](repeating: 1, count: anchors.count)
    var previous = [Int](repeating: -1, count: anchors.count)
    for index in anchors.indices {
      for earlier in 0..<index {
        let a = anchors[earlier], b = anchors[index]
        guard b.heard > a.heard, b.book > a.book else { continue }
        let drift = abs((b.book - b.heard) - (a.book - a.heard))
        guard drift <= 40, length[earlier] + 1 > length[index] else { continue }
        length[index] = length[earlier] + 1
        previous[index] = earlier
      }
    }
    var end = length.indices.max { length[$0] < length[$1] }!
    var chain = [(heard: Int, book: Int)]()
    while end >= 0 {
      chain.append(anchors[end])
      end = previous[end]
    }
    return chain.reversed()
  }
}
