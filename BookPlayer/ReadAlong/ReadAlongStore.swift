//
//  ReadAlongStore.swift
//  BookPlayer
//
//  Where read-along keeps its files, in Application Support/ReadAlong (this device only):
//  - Ebooks/            EPUBs imported like audiobooks, waiting to be paired with a book
//  - Books/<book id>/   a paired book: book.epub, text.json (its words) and timing.json
//

import Foundation

/// An ebook's text, split into paragraphs of words
struct ReadAlongText: Codable {
  var title: String?
  var language: String?
  var paragraphs: [[String]]

  var wordCount: Int { paragraphs.reduce(0) { $0 + $1.count } }

  init(contents: EpubContents) {
    title = contents.title
    language = contents.language
    paragraphs = contents.paragraphs
      .map { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
      .filter { !$0.isEmpty }
  }
}

/// When each word of the text is spoken, in seconds into the book
struct ReadAlongTiming: Codable {
  var wordTimes: [TimeInterval]
  var localeIdentifier: String
  var createdAt: Date
  /// How the sync went (nil in timings saved before these were kept)
  var matchedWords: Int?
  var heardWords: Int?
  var isEstimated: Bool?
}

/// An EPUB on the ebooks shelf
struct ImportedEbook: Identifiable, Hashable {
  let url: URL
  let title: String

  var id: URL { url }
}

enum ReadAlongStore {
  private static var rootURL: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return support.appendingPathComponent("ReadAlong", isDirectory: true)
  }

  static var ebooksFolderURL: URL {
    rootURL.appendingPathComponent("Ebooks", isDirectory: true)
  }

  /// A book's folder, by `PlayableItem.id` (its uuid, or its path when it has none)
  static func folderURL(forBookId bookId: String) -> URL {
    let safe = bookId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? bookId
    return rootURL.appendingPathComponent("Books", isDirectory: true).appendingPathComponent(safe, isDirectory: true)
  }

  // MARK: - The ebooks shelf

  static func isEbook(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == "epub"
  }

  /// Copies an EPUB that came in through Import, Share or Transfer from Computer onto the shelf.
  /// Called by `ImportOperation` with security-scoped access already started
  @discardableResult
  static func addToShelf(_ sourceURL: URL) throws -> URL {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: ebooksFolderURL, withIntermediateDirectories: true)

    let name = sourceURL.deletingPathExtension().lastPathComponent
    var destination = ebooksFolderURL.appendingPathComponent("\(name).epub")
    var counter = 1
    while fileManager.fileExists(atPath: destination.path) {
      counter += 1
      destination = ebooksFolderURL.appendingPathComponent("\(name)-\(counter).epub")
    }

    try fileManager.copyItem(at: sourceURL, to: destination)
    return destination
  }

  static func shelf() -> [ImportedEbook] {
    let files = (try? FileManager.default.contentsOfDirectory(
      at: ebooksFolderURL,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )) ?? []

    return files
      .filter(isEbook)
      .map { ImportedEbook(url: $0, title: $0.deletingPathExtension().lastPathComponent) }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  /// The shelf's ebook that looks like this audiobook: one name holds the other, once both are
  /// reduced to letters and digits ("Dune" and "Frank Herbert - Dune (2005)")
  static func likelyEbook(forTitle title: String, fileName: String) -> ImportedEbook? {
    let keys = [title, fileName].map(ReadAlongAligner.normalizedTitle).filter { $0.count >= 3 }
    guard !keys.isEmpty else { return nil }

    return shelf().first { ebook in
      let ebookKey = ReadAlongAligner.normalizedTitle(ebook.title)
      guard ebookKey.count >= 3 else { return false }
      return keys.contains { $0 == ebookKey || $0.contains(ebookKey) || ebookKey.contains($0) }
    }
  }

  // MARK: - A paired book

  /// Moves the ebook off the shelf into the book's folder (or copies a file picked in Files) and
  /// stores its text. Any earlier ebook and timing of the book are replaced
  static func pair(ebookAt sourceURL: URL, withBookId bookId: String, fromShelf: Bool) throws -> ReadAlongText {
    let contents = try EpubTextExtractor.extract(from: sourceURL)
    let text = ReadAlongText(contents: contents)
    guard text.wordCount > 0 else { throw EpubError.noText }

    let fileManager = FileManager.default
    let folder = folderURL(forBookId: bookId)
    try? fileManager.removeItem(at: folder)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

    let epubURL = folder.appendingPathComponent("book.epub")
    if fromShelf {
      try fileManager.moveItem(at: sourceURL, to: epubURL)
    } else {
      try fileManager.copyItem(at: sourceURL, to: epubURL)
    }
    try JSONEncoder().encode(text).write(to: folder.appendingPathComponent("text.json"), options: .atomic)
    return text
  }

  static func text(forBookId bookId: String) -> ReadAlongText? {
    let url = folderURL(forBookId: bookId).appendingPathComponent("text.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(ReadAlongText.self, from: data)
  }

  static func timing(forBookId bookId: String) -> ReadAlongTiming? {
    let url = folderURL(forBookId: bookId).appendingPathComponent("timing.json")
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(ReadAlongTiming.self, from: data)
  }

  static func saveTiming(_ timing: ReadAlongTiming, forBookId bookId: String) throws {
    let url = folderURL(forBookId: bookId).appendingPathComponent("timing.json")
    try JSONEncoder().encode(timing).write(to: url, options: .atomic)
  }

  /// Unpairs the ebook: it goes back on the shelf, and the timing is deleted
  static func unpair(bookId: String, title: String?) {
    let folder = folderURL(forBookId: bookId)
    let epubURL = folder.appendingPathComponent("book.epub")
    if FileManager.default.fileExists(atPath: epubURL.path) {
      let name = (title?.isEmpty == false ? title! : "Ebook").replacingOccurrences(of: "/", with: "-")
      let shelved = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).epub")
      try? FileManager.default.removeItem(at: shelved)
      if (try? FileManager.default.moveItem(at: epubURL, to: shelved)) != nil {
        try? addToShelf(shelved)
        try? FileManager.default.removeItem(at: shelved)
      }
    }
    try? FileManager.default.removeItem(at: folder)
  }
}
