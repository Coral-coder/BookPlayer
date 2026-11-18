//
//  ReadAlongTests.swift
//  BookPlayerTests
//

@testable import BookPlayer
import XCTest

final class ReadAlongTests: XCTestCase {
  private func spoken(_ text: String, every step: Double = 1, from start: Double = 0) -> [SpokenWord] {
    text.split(separator: " ").enumerated().map { index, word in
      SpokenWord(text: String(word), start: start + Double(index) * step)
    }
  }

  func testNormalizeIgnoresCaseAccentsAndPunctuation() {
    XCTAssertEqual(ReadAlongAligner.normalize("Don’t,"), "dont")
    XCTAssertEqual(ReadAlongAligner.normalize("Café!"), "cafe")
    XCTAssertEqual(ReadAlongAligner.normalize("—"), "")
  }

  func testAlignsAnExactNarration() {
    let words = "the lantern keeper climbed the long stair".split(separator: " ").map(String.init)
    let result = ReadAlongAligner.align(
      bookWords: words, spoken: spoken("The lantern keeper climbed the long stair."), duration: 10
    )
    XCTAssertEqual(result.times, [0, 1, 2, 3, 4, 5, 6])
    XCTAssertEqual(result.matchedWords, 7)
    XCTAssertFalse(result.isEstimated)
  }

  func testSpreadsTimesOverWordsTheRecognizerMissed() {
    let times = ReadAlongAligner.fillGaps([10, nil, nil, nil, 14], duration: 20)
    XCTAssertEqual(times, [10, 11, 12, 13, 14])
  }

  func testSkipsANarratorIntroTheEbookDoesNotHave() {
    let book = "chapter one the river ran north past the mill".split(separator: " ").map(String.init)
    let narration = spoken("this audiobook is read for you by a narrator today chapter one the river ran north past the mill")
    let times = ReadAlongAligner.align(bookWords: book, spoken: narration, duration: 30).times
    XCTAssertEqual(times.first, 10)
    XCTAssertEqual(times.last, 18)
  }

  func testResyncsAfterFrontMatterTheNarratorSkips() {
    let frontMatter = Array(repeating: "copyright notice text", count: 30).joined(separator: " ")
    let book = (frontMatter + " the storm reached the coast at dawn and the boats stayed home")
      .split(separator: " ").map(String.init)
    let narration = spoken("the storm reached the coast at dawn and the boats stayed home", from: 100)
    let times = ReadAlongAligner.align(bookWords: book, spoken: narration, duration: 120).times
    let stormIndex = book.firstIndex(of: "storm")!
    XCTAssertEqual(times[stormIndex], 101)
    XCTAssertEqual(times.last, 111)
  }

  func testTimesNeverGoBackwards() {
    let times = ReadAlongAligner.fillGaps([5, nil, 3, nil, 8], duration: 10)
    XCTAssertEqual(times, times.sorted())
  }

  /// The bug from the first TestFlight build: one match put every other word at its time, so the
  /// highlight jumped to the last word and stayed there
  func testOneMatchStillSpreadsTheBookOverItsDuration() {
    let times = ReadAlongAligner.fillGaps([nil, nil, 4, nil, nil], duration: 100)
    XCTAssertEqual(times.first, 0)
    XCTAssertEqual(times[2], 4)
    XCTAssertEqual(times.last, 100)
    XCTAssertEqual(ReadAlongViewModel.wordIndex(at: 60, in: times), 3)
  }

  func testNarrationThatMatchesNothingIsAnEstimate() {
    let book = (1...200).map { "word\($0)" }
    let result = ReadAlongAligner.align(
      bookWords: book, spoken: spoken("completely different words from another book entirely"), duration: 400
    )
    XCTAssertTrue(result.isEstimated)
    XCTAssertEqual(result.matchedWords, 0)
    XCTAssertEqual(result.times.first, 0)
    XCTAssertEqual(result.times.last, 400)
    XCTAssertEqual(ReadAlongViewModel.wordIndex(at: 200, in: result.times), 99)
  }

  func testWordIndexFindsTheWordBeingRead() {
    let times: [TimeInterval] = [0, 0.5, 1.2, 2.0, 3.5]
    XCTAssertEqual(ReadAlongViewModel.wordIndex(at: 0.1, in: times), 0)
    XCTAssertEqual(ReadAlongViewModel.wordIndex(at: 1.2, in: times), 2)
    XCTAssertEqual(ReadAlongViewModel.wordIndex(at: 99, in: times), 4)
  }

  func testParsesXHTMLParagraphsWithHTMLEntities() {
    let xhtml = """
      <?xml version="1.0" encoding="utf-8"?>
      <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Ignored</title></head>
      <body><h1>Chapter&nbsp;1</h1><p>First line &mdash; with <em>emphasis</em>.</p>
      <p>Second&#160;line &amp; more.</p><script>var x = 1;</script></body></html>
      """
    let paragraphs = XHTMLTextParser.paragraphs(in: Data(xhtml.utf8))
    XCTAssertEqual(paragraphs, ["Chapter 1", "First line — with emphasis.", "Second line & more."])
  }

  func testFallsBackWhenXHTMLIsNotWellFormed() {
    let html = "<html><body><p>One<br>Two</p><p>Three &amp; four</body>"
    XCTAssertEqual(XHTMLTextParser.paragraphs(in: Data(html.utf8)), ["One", "Two", "Three & four"])
  }

  // MARK: - Live following

  private let passage = """
    the keeper of the lantern climbed the long stair every evening and counted the steps \
    while the gulls argued on the rocks below and the tide pulled at the old pier \
    when the light was lit he wrote the weather in a small green book
    """

  func testPlacesNarrationThatDiffersFromTheEbook() {
    let book = (String(repeating: "front matter page ", count: 50) + passage).split(separator: " ").map(String.init)
    let matcher = ReadAlongMatcher(bookWords: book)
    /// The narrator skips "long" and says "seagulls": the rest still places
    let narration = spoken(
      "the keeper of the lantern climbed the stair every evening and counted the steps while the seagulls argued",
      from: 300
    )
    let placements = matcher.place(narration, near: nil)

    let keeper = book.firstIndex(of: "keeper")!
    XCTAssertEqual(placements.first?.word, keeper - 1)
    XCTAssertEqual(placements.first?.time, 300)
    XCTAssertTrue(placements.contains { $0.word == book.firstIndex(of: "counted")! })
    XCTAssertGreaterThan(placements.count, 12)
  }

  func testNarrationNotInTheEbookPlacesNothing() {
    let matcher = ReadAlongMatcher(bookWords: passage.split(separator: " ").map(String.init))
    let placements = matcher.place(spoken("chapter twelve the market opened before sunrise and nobody noticed"), near: 0)
    XCTAssertTrue(placements.isEmpty)
  }

  func testWordBetweenPlacedWordsFollowsTime() {
    let anchors = [
      ReadAlongMatcher.Placement(word: 10, time: 100),
      ReadAlongMatcher.Placement(word: 20, time: 104),
    ]
    XCTAssertNil(ReadAlongViewModel.word(at: 99, anchors: anchors))
    XCTAssertEqual(ReadAlongViewModel.word(at: 102, anchors: anchors), 15)
    XCTAssertEqual(ReadAlongViewModel.word(at: 500, anchors: anchors), 20)
  }
}
