//
//  ReadAlongViewModel.swift
//  BookPlayer
//

import BookPlayerKit
import Combine
import SwiftUI

@MainActor
final class ReadAlongViewModel: ObservableObject {
  enum Phase: Equatable {
    /// No ebook paired with this book yet
    case needsEbook
    /// The ebook's text is shown, without timing
    case textOnly
    /// Listening to the audiobook, 0…1
    case syncing(Double)
    /// Words follow the narration
    case following
  }

  @Published private(set) var phase: Phase = .needsEbook
  @Published private(set) var paragraphs: [[String]] = []
  /// Index of the first word of each paragraph in the whole text
  @Published private(set) var paragraphStarts: [Int] = []
  @Published private(set) var currentWord: Int?
  @Published private(set) var isPlaying = false
  @Published private(set) var shelf: [ImportedEbook] = []
  @Published var error: Error?
  /// How the last sync went, shown under the text
  @Published private(set) var syncSummary: String?
  /// The timing is spread by word count, not matched to the narration
  @Published private(set) var isEstimated = false

  let bookTitle: String
  let playerManager: PlayerManager

  private let bookId: String
  private let item: PlayableItem
  private var ebookTitle: String?
  private var ebookLanguage: String?
  private var wordTimes: [TimeInterval] = []
  private var syncTask: Task<Void, Never>?
  private var clock: AnyCancellable?
  private var disposeBag = Set<AnyCancellable>()
  private var idleTimerWasDisabled = false

  init(item: PlayableItem, playerManager: PlayerManager) {
    self.item = item
    self.bookId = item.id
    self.bookTitle = item.title
    self.playerManager = playerManager
    load()

    playerManager.isPlayingPublisher()
      .receive(on: DispatchQueue.main)
      .sink { [weak self] in self?.isPlaying = $0 }
      .store(in: &disposeBag)
  }

  // MARK: - Loading and pairing

  private func load() {
    guard let text = ReadAlongStore.text(forBookId: bookId) else {
      phase = .needsEbook
      refreshShelf()
      autoPairFromShelf()
      return
    }

    show(text)
    /// Timings saved before syncs recorded how they went could pile every word on one time (the
    /// highlight sat on the last word): those need syncing again
    if let timing = ReadAlongStore.timing(forBookId: bookId),
       timing.wordTimes.count == text.wordCount,
       timing.matchedWords != nil
    {
      wordTimes = timing.wordTimes
      describe(timing)
      startFollowing()
    } else {
      phase = .textOnly
    }
  }

  private func show(_ text: ReadAlongText) {
    ebookTitle = text.title
    ebookLanguage = text.language
    paragraphs = text.paragraphs
    var starts = [Int]()
    var count = 0
    for paragraph in text.paragraphs {
      starts.append(count)
      count += paragraph.count
    }
    paragraphStarts = starts
  }

  func refreshShelf() {
    shelf = ReadAlongStore.shelf()
  }

  /// An ebook imported for this book is paired without asking
  private func autoPairFromShelf() {
    let fileName = item.relativePath.components(separatedBy: "/").last ?? item.relativePath
    let fileTitle = (fileName as NSString).deletingPathExtension
    guard let match = ReadAlongStore.likelyEbook(forTitle: item.title, fileName: fileTitle) else { return }
    pair(with: match.url, fromShelf: true)
  }

  func pair(with url: URL, fromShelf: Bool) {
    let accessGranted = fromShelf ? false : url.startAccessingSecurityScopedResource()
    defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }

    do {
      let text = try ReadAlongStore.pair(ebookAt: url, withBookId: bookId, fromShelf: fromShelf)
      wordTimes = []
      show(text)
      phase = .textOnly
      refreshShelf()
    } catch {
      self.error = error
    }
  }

  func unpair() {
    cancelSync()
    stopFollowing()
    ReadAlongStore.unpair(bookId: bookId, title: ebookTitle)
    paragraphs = []
    paragraphStarts = []
    wordTimes = []
    currentWord = nil
    phase = .needsEbook
    refreshShelf()
  }

  // MARK: - Syncing with the audio

  /// The audio files that make up the book, each with where it starts in the book
  private func audioParts() -> [ReadAlongAligner.AudioPart] {
    var parts = [ReadAlongAligner.AudioPart]()
    var seen = Set<URL>()
    for chapter in item.chapters.sorted(by: { $0.start < $1.start }) {
      let url = chapter.fileURL
      guard !seen.contains(url) else { continue }
      seen.insert(url)
      parts.append(.init(fileURL: url, bookOffset: chapter.start - chapter.chapterOffset))
    }
    return parts
  }

  func startSync() {
    guard syncTask == nil else { return }

    let parts = audioParts()
    guard !parts.isEmpty, parts.allSatisfy({ FileManager.default.fileExists(atPath: $0.fileURL.path) }) else {
      error = ReadAlongError.audioNotOnDevice
      return
    }

    let bookWords = paragraphs.flatMap { $0 }
    let duration = item.duration
    let language = ebookLanguage
    let bookId = bookId

    stopFollowing()
    phase = .syncing(0)
    /// Transcribing a long book takes a while; the screen staying on keeps the app running
    idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true

    syncTask = Task { [weak self] in
      do {
        try await ReadAlongAligner.requestSpeechPermission()
        let locale = try await ReadAlongAligner.transcriptionLocale(forLanguage: language)
        let spoken = try await ReadAlongAligner.transcribe(
          parts: parts,
          locale: locale,
          totalDuration: duration
        ) { [weak self] progress in
          guard let self, case .syncing = self.phase else { return }
          self.phase = .syncing(progress)
        }
        try Task.checkCancellation()
        guard !spoken.isEmpty else { throw ReadAlongError.nothingHeard }

        let result = await Task.detached(priority: .userInitiated) {
          ReadAlongAligner.align(bookWords: bookWords, spoken: spoken, duration: duration)
        }.value
        let timing = ReadAlongTiming(
          wordTimes: result.times,
          localeIdentifier: locale.identifier,
          createdAt: Date(),
          matchedWords: result.matchedWords,
          heardWords: result.heardWords,
          isEstimated: result.isEstimated
        )
        try ReadAlongStore.saveTiming(timing, forBookId: bookId)

        self?.describe(timing)
        self?.finishSync(times: result.times)
      } catch is CancellationError {
        self?.finishSync(times: nil)
      } catch {
        self?.finishSync(times: nil)
        self?.error = error
      }
    }
  }

  private func describe(_ timing: ReadAlongTiming) {
    let total = max(timing.wordTimes.count, 1)
    let matched = timing.matchedWords ?? 0
    let percent = Int((Double(matched) / Double(total) * 100).rounded())
    isEstimated = timing.isEstimated ?? false
    syncSummary = String(
      format: (isEstimated ? "read_along_sync_estimated_summary" : "read_along_sync_summary").localized,
      timing.heardWords ?? 0, matched, percent
    )
  }

  private func finishSync(times: [TimeInterval]?) {
    syncTask = nil
    UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
    if let times {
      wordTimes = times
      startFollowing()
    } else {
      phase = paragraphs.isEmpty ? .needsEbook : .textOnly
    }
  }

  func cancelSync() {
    syncTask?.cancel()
  }

  // MARK: - Following the narration

  private func startFollowing() {
    phase = .following
    clock?.cancel()
    clock = Timer.publish(every: 0.15, on: .main, in: .common)
      .autoconnect()
      .sink { [weak self] _ in self?.tick() }
    tick()
  }

  private func stopFollowing() {
    clock?.cancel()
    clock = nil
  }

  private func tick() {
    guard
      !wordTimes.isEmpty,
      playerManager.currentItem?.id == bookId,
      let time = playerManager.preciseBookTime()
    else { return }

    let index = Self.wordIndex(at: time, in: wordTimes)
    if index != currentWord { currentWord = index }
  }

  /// The last word that starts at or before `time` (the first word before the narration reaches it)
  nonisolated static func wordIndex(at time: TimeInterval, in times: [TimeInterval]) -> Int {
    var low = 0
    var high = times.count - 1
    var found = 0
    while low <= high {
      let middle = (low + high) / 2
      if times[middle] <= time {
        found = middle
        low = middle + 1
      } else {
        high = middle - 1
      }
    }
    return found
  }

  /// Plays from a paragraph: from its first word with timing, or nothing without it
  func jump(toParagraph index: Int) {
    guard
      phase == .following,
      paragraphStarts.indices.contains(index),
      playerManager.currentItem?.id == bookId
    else { return }

    let word = paragraphStarts[index]
    guard wordTimes.indices.contains(word) else { return }
    playerManager.jumpTo(max(wordTimes[word] - 0.3, 0))
    currentWord = word
  }

  func paragraphIndex(ofWord word: Int) -> Int? {
    guard !paragraphStarts.isEmpty else { return nil }
    var low = 0
    var high = paragraphStarts.count - 1
    var found = 0
    while low <= high {
      let middle = (low + high) / 2
      if paragraphStarts[middle] <= word {
        found = middle
        low = middle + 1
      } else {
        high = middle - 1
      }
    }
    return found
  }

  func playPause() {
    playerManager.playPause()
  }

  /// Closing the screen stops a sync in progress (it says to keep the screen open)
  func onDisappear() {
    stopFollowing()
    if syncTask != nil {
      cancelSync()
      UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
    }
  }

  func onAppear() {
    if phase == .following, clock == nil { startFollowing() }
  }
}
