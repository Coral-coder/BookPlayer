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
    /// The ebook is shown and follows the narration
    case following
  }

  /// What the live follower is doing, shown above the text
  enum Status: Equatable {
    case starting
    /// Waiting for playback of this book
    case waitingForPlayback
    /// Transcribing what's about to play, nothing placed yet
    case listening
    case following
    /// What's playing now isn't in the ebook
    case notInEbook
    case stopped
  }

  @Published private(set) var phase: Phase = .needsEbook
  @Published private(set) var status: Status = .starting
  @Published private(set) var paragraphs: [[String]] = []
  /// Index of the first word of each paragraph in the whole text
  @Published private(set) var paragraphStarts: [Int] = []
  @Published private(set) var currentWord: Int?
  @Published private(set) var isPlaying = false
  @Published private(set) var shelf: [ImportedEbook] = []
  @Published var error: Error?

  let bookTitle: String
  let playerManager: PlayerManager

  private let bookId: String
  private let item: PlayableItem
  private var ebookTitle: String?
  private var ebookLanguage: String?
  private var matcher: ReadAlongMatcher?
  private var wordCount = 0
  /// Ebook words placed in the narration so far, by time
  private var anchors = [ReadAlongMatcher.Placement]()
  /// Stretches of the book (seconds) already transcribed, and whether each was found in the ebook
  private var covered = [(start: TimeInterval, end: TimeInterval, found: Bool)]()
  private var followTask: Task<Void, Never>?
  private var clock: AnyCancellable?
  private var disposeBag = Set<AnyCancellable>()

  /// How much is transcribed at a time, and how far ahead of playback
  private static let segmentLength: TimeInterval = 20
  private static let lookAhead: TimeInterval = 25

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
    wordCount = count
    matcher = ReadAlongMatcher(bookWords: text.paragraphs.flatMap { $0 })
    anchors = ReadAlongStore.anchors(forBookId: bookId)
    covered = []
    phase = .following
    startFollowing()
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
      stopFollowing()
      show(text)
      refreshShelf()
    } catch {
      self.error = error
    }
  }

  func unpair() {
    stopFollowing()
    ReadAlongStore.unpair(bookId: bookId, title: ebookTitle)
    paragraphs = []
    paragraphStarts = []
    anchors = []
    covered = []
    matcher = nil
    currentWord = nil
    phase = .needsEbook
    refreshShelf()
  }

  // MARK: - Following the narration live

  /// The audio files that make up the book, each with where it starts in the book
  private lazy var audioParts: [ReadAlongAligner.AudioPart] = {
    var parts = [ReadAlongAligner.AudioPart]()
    var seen = Set<URL>()
    for chapter in item.chapters.sorted(by: { $0.start < $1.start }) {
      let url = chapter.fileURL
      guard !seen.contains(url) else { continue }
      seen.insert(url)
      parts.append(.init(fileURL: url, bookOffset: chapter.start - chapter.chapterOffset))
    }
    return parts
  }()

  /// The file playing at `time`, and where it ends in the book
  private func part(at time: TimeInterval) -> (part: ReadAlongAligner.AudioPart, end: TimeInterval)? {
    guard let index = audioParts.lastIndex(where: { $0.bookOffset <= time + 0.01 }) else { return nil }
    let end = index + 1 < audioParts.count ? audioParts[index + 1].bookOffset : item.duration
    return (audioParts[index], end)
  }

  private func startFollowing() {
    clock?.cancel()
    clock = Timer.publish(every: 0.15, on: .main, in: .common)
      .autoconnect()
      .sink { [weak self] _ in self?.tick() }

    followTask?.cancel()
    followTask = Task { [weak self] in
      await self?.followLoop()
    }
  }

  private func stopFollowing() {
    clock?.cancel()
    clock = nil
    followTask?.cancel()
    followTask = nil
    ReadAlongStore.saveAnchors(anchors, forBookId: bookId)
  }

  /// Transcribes what's about to play, a stretch at a time, and places it in the ebook
  private func followLoop() async {
    status = .starting
    let locale: Locale
    do {
      try await ReadAlongAligner.requestSpeechPermission()
      locale = try await ReadAlongAligner.transcriptionLocale(forLanguage: ebookLanguage)
    } catch {
      status = .stopped
      self.error = error
      return
    }

    while !Task.isCancelled {
      guard
        playerManager.currentItem?.id == bookId,
        let now = playerManager.preciseBookTime()
      else {
        status = .waitingForPlayback
        try? await Task.sleep(for: .milliseconds(500))
        continue
      }

      let next = nextUncovered(from: now)
      guard next - now < Self.lookAhead, next < item.duration - 0.5, let playing = part(at: next) else {
        updateStatus(at: now)
        try? await Task.sleep(for: .milliseconds(500))
        continue
      }
      let audioPart = playing.part

      let length = min(Self.segmentLength, playing.end - next)
      guard length >= 0.5 else {
        covered.append((start: next, end: playing.end, found: true))
        continue
      }

      if anchors.isEmpty { status = .listening }

      do {
        let spoken = try await ReadAlongAligner.transcribeSegment(
          of: audioPart,
          from: next - audioPart.bookOffset,
          length: length,
          locale: locale
        )
        try Task.checkCancellation()

        let near = nearWord(at: next)
        guard let matcher else { return }
        let placements = await Task.detached(priority: .userInitiated) {
          matcher.place(spoken, near: near)
        }.value

        covered.append((start: next, end: next + length, found: !placements.isEmpty))
        add(placements, from: next, to: next + length)
        updateStatus(at: playerManager.preciseBookTime() ?? now)
      } catch is CancellationError {
        return
      } catch {
        status = .stopped
        self.error = error
        return
      }
    }
  }

  /// The first moment from `time` on that hasn't been transcribed
  private func nextUncovered(from time: TimeInterval) -> TimeInterval {
    var point = time
    var moved = true
    while moved {
      moved = false
      for range in covered where range.start <= point + 0.01 && range.end > point {
        point = range.end
        moved = true
      }
    }
    return point
  }

  /// The ebook word the narration is likely at around `time`: the nearest one placed before it,
  /// else a guess from how far into the book it is
  private func nearWord(at time: TimeInterval) -> Int? {
    if let anchor = anchors.last(where: { $0.time <= time }) {
      return anchor.word
    }
    guard item.duration > 0, wordCount > 0 else { return nil }
    return Int(Double(wordCount) * time / item.duration)
  }

  private func add(_ placements: [ReadAlongMatcher.Placement], from start: TimeInterval, to end: TimeInterval) {
    guard !placements.isEmpty else { return }
    anchors.removeAll { $0.time >= start && $0.time < end }
    anchors.append(contentsOf: placements)
    anchors.sort { $0.time < $1.time }
  }

  private func updateStatus(at time: TimeInterval) {
    if let range = covered.last(where: { $0.start <= time && $0.end > time }), !range.found {
      status = .notInEbook
    } else if anchors.isEmpty {
      status = .listening
    } else {
      status = .following
    }
  }

  private func tick() {
    guard
      playerManager.currentItem?.id == bookId,
      let time = playerManager.preciseBookTime(),
      let word = Self.word(at: time, anchors: anchors)
    else { return }

    if word != currentWord { currentWord = word }
  }

  /// The word being read at `time`: between two placed words close together, the place between
  /// them by time; otherwise the last word placed before `time`
  nonisolated static func word(at time: TimeInterval, anchors: [ReadAlongMatcher.Placement]) -> Int? {
    guard let index = anchors.lastIndex(where: { $0.time <= time }) else { return nil }
    let previous = anchors[index]
    guard index + 1 < anchors.count else { return previous.word }

    let next = anchors[index + 1]
    guard next.time - previous.time < 6, next.word > previous.word, next.time > previous.time else {
      return previous.word
    }
    let fraction = (time - previous.time) / (next.time - previous.time)
    return previous.word + Int(Double(next.word - previous.word) * fraction)
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

  /// Plays from a paragraph: from where its words were heard, else an estimate from its place in
  /// the book
  func jump(toParagraph index: Int) {
    guard
      paragraphStarts.indices.contains(index),
      playerManager.currentItem?.id == bookId
    else { return }

    let word = paragraphStarts[index]
    let paragraphEnd = index + 1 < paragraphStarts.count ? paragraphStarts[index + 1] : wordCount
    let time: TimeInterval
    if let heard = anchors.filter({ $0.word >= word && $0.word < paragraphEnd }).min(by: { $0.word < $1.word }) {
      time = heard.time
    } else if wordCount > 0 {
      time = item.duration * Double(word) / Double(wordCount)
    } else {
      return
    }
    playerManager.jumpTo(max(time - 0.3, 0))
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

  func onDisappear() {
    stopFollowing()
  }

  func onAppear() {
    if phase == .following, followTask == nil { startFollowing() }
  }
}
