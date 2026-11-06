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
  static func align(bookWords: [String], spoken: [SpokenWord]) -> [TimeInterval] {
    let book = bookWords.map(normalize)
    let heard = spoken.map { (word: normalize($0.text), start: $0.start) }.filter { !$0.word.isEmpty }
    guard !book.isEmpty else { return [] }
    guard !heard.isEmpty else { return Array(repeating: 0, count: book.count) }

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

    return fillGaps(times)
  }

  /// Unmatched words get times spread evenly between their matched neighbours
  static func fillGaps(_ times: [TimeInterval?]) -> [TimeInterval] {
    let anchors = times.enumerated().compactMap { index, time in time.map { (index, $0) } }
    guard let first = anchors.first, let last = anchors.last else {
      return Array(repeating: 0, count: times.count)
    }

    var result = [TimeInterval](repeating: first.1, count: times.count)
    for (previous, next) in zip(anchors, anchors.dropFirst()) {
      let span = Double(next.0 - previous.0)
      for index in previous.0...next.0 {
        let fraction = Double(index - previous.0) / span
        result[index] = previous.1 + (next.1 - previous.1) * fraction
      }
    }
    for index in last.0..<times.count {
      result[index] = last.1
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
