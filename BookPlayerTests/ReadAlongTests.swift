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
    let times = ReadAlongAligner.align(bookWords: words, spoken: spoken("The lantern keeper climbed the long stair."))
    XCTAssertEqual(times, [0, 1, 2, 3, 4, 5, 6])
  }

  func testSpreadsTimesOverWordsTheRecognizerMissed() {
    let words = ["a", "quiet", "harbor", "town", "slept"]
    let times = ReadAlongAligner.align(
      bookWords: words,
      spoken: [SpokenWord(text: "a", start: 10), SpokenWord(text: "slept", start: 14)]
    )
    XCTAssertEqual(times, [10, 11, 12, 13, 14])
  }

  func testSkipsANarratorIntroTheEbookDoesNotHave() {
    let book = "chapter one the river ran north past the mill".split(separator: " ").map(String.init)
    let narration = spoken("this audiobook is read for you by a narrator today chapter one the river ran north past the mill")
    let times = ReadAlongAligner.align(bookWords: book, spoken: narration)
    XCTAssertEqual(times.first, 10)
    XCTAssertEqual(times.last, 18)
  }

  func testResyncsAfterFrontMatterTheNarratorSkips() {
    let frontMatter = Array(repeating: "copyright notice text", count: 30).joined(separator: " ")
    let book = (frontMatter + " the storm reached the coast at dawn and the boats stayed home")
      .split(separator: " ").map(String.init)
    let narration = spoken("the storm reached the coast at dawn and the boats stayed home", from: 100)
    let times = ReadAlongAligner.align(bookWords: book, spoken: narration)
    let stormIndex = book.firstIndex(of: "storm")!
    XCTAssertEqual(times[stormIndex], 101)
    XCTAssertEqual(times.last, 111)
  }

  func testTimesNeverGoBackwards() {
    let times = ReadAlongAligner.fillGaps([5, nil, 3, nil, 8])
    XCTAssertEqual(times, times.sorted())
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
}
