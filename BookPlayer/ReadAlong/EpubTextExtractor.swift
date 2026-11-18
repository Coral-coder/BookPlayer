//
//  EpubTextExtractor.swift
//  BookPlayer
//
//  Reads the text of an EPUB for read-along: its title, language and paragraphs, in reading order.
//

import Foundation
import ZipArchive

enum EpubError: LocalizedError {
  case unreadable
  case noText

  var errorDescription: String? {
    switch self {
    case .unreadable:
      return "read_along_epub_unreadable_error".localized
    case .noText:
      return "read_along_epub_no_text_error".localized
    }
  }
}

struct EpubContents {
  var title: String?
  /// BCP 47 code from the book's `dc:language`, when it has one
  var language: String?
  var paragraphs: [String]
}

enum EpubTextExtractor {
  static func extract(from epubURL: URL) throws -> EpubContents {
    let fileManager = FileManager.default
    let folder = fileManager.temporaryDirectory
      .appendingPathComponent("epub-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: folder) }

    guard SSZipArchive.unzipFile(atPath: epubURL.path, toDestination: folder.path) else {
      throw EpubError.unreadable
    }

    /// META-INF/container.xml names the package document (the OPF)
    let containerURL = folder.appendingPathComponent("META-INF/container.xml")
    guard
      let containerData = try? Data(contentsOf: containerURL),
      let opfPath = ContainerParser.rootfilePath(in: containerData)
    else {
      throw EpubError.unreadable
    }

    let opfURL = folder.appendingPathComponent(opfPath)
    guard let opfData = try? Data(contentsOf: opfURL) else { throw EpubError.unreadable }
    let package = PackageParser.parse(opfData)
    let baseURL = opfURL.deletingLastPathComponent()

    var paragraphs = [String]()
    for idref in package.spine {
      guard let item = package.manifest[idref] else { continue }
      guard item.mediaType.contains("html") || item.href.hasSuffix(".xhtml") || item.href.hasSuffix(".html") else {
        continue
      }

      let href = (item.href.components(separatedBy: "#").first ?? item.href)
      let decoded = href.removingPercentEncoding ?? href
      let fileURL = baseURL.appendingPathComponent(decoded)
      guard let data = try? Data(contentsOf: fileURL) else { continue }

      paragraphs.append(contentsOf: XHTMLTextParser.paragraphs(in: data))
    }

    guard !paragraphs.isEmpty else { throw EpubError.noText }

    return EpubContents(title: package.title, language: package.language, paragraphs: paragraphs)
  }
}

// MARK: - container.xml

private final class ContainerParser: NSObject, XMLParserDelegate {
  private var path: String?

  static func rootfilePath(in data: Data) -> String? {
    let delegate = ContainerParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.parse()
    return delegate.path
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    guard path == nil, localName(elementName) == "rootfile" else { return }
    path = attributeDict["full-path"]
  }
}

// MARK: - The package document (OPF)

private struct EpubPackage {
  struct Item {
    let href: String
    let mediaType: String
  }

  var title: String?
  var language: String?
  var manifest = [String: Item]()
  var spine = [String]()
}

private final class PackageParser: NSObject, XMLParserDelegate {
  private var package = EpubPackage()
  private var currentElement: String?
  private var text = ""

  static func parse(_ data: Data) -> EpubPackage {
    let delegate = PackageParser()
    let parser = XMLParser(data: data)
    parser.delegate = delegate
    parser.parse()
    return delegate.package
  }

  func parser(
    _ parser: XMLParser,
    didStartElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?,
    attributes attributeDict: [String: String] = [:]
  ) {
    let name = localName(elementName)
    switch name {
    case "item":
      if let id = attributeDict["id"], let href = attributeDict["href"] {
        package.manifest[id] = .init(href: href, mediaType: attributeDict["media-type"] ?? "")
      }
    case "itemref":
      if let idref = attributeDict["idref"], attributeDict["linear"] != "no" {
        package.spine.append(idref)
      }
    case "title", "language":
      currentElement = name
      text = ""
    default:
      break
    }
  }

  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if currentElement != nil { text += string }
  }

  func parser(
    _ parser: XMLParser,
    didEndElement elementName: String,
    namespaceURI: String?,
    qualifiedName qName: String?
  ) {
    let name = localName(elementName)
    guard name == currentElement else { return }
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if name == "title", package.title == nil, !value.isEmpty { package.title = value }
    if name == "language", package.language == nil, !value.isEmpty { package.language = value }
    currentElement = nil
  }
}

// MARK: - Chapter text (XHTML)

enum XHTMLTextParser {
  /// The text of one chapter file, split at block elements (paragraphs, headings, list items…)
  static func paragraphs(in data: Data) -> [String] {
    guard let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
      return []
    }

    let source = HTMLEntities.makeXMLSafe(raw)
    let delegate = Collector()
    let parser = XMLParser(data: Data(source.utf8))
    parser.delegate = delegate
    if parser.parse() {
      delegate.endBlock()
      return delegate.paragraphs
    }

    /// Not well-formed XML: fall back to stripping the tags
    return fallbackParagraphs(in: source)
  }

  static func fallbackParagraphs(in source: String) -> [String] {
    var text = source
    if let bodyStart = text.range(of: "<body", options: .caseInsensitive) {
      text = String(text[bodyStart.lowerBound...])
    }
    text = text.replacingOccurrences(
      of: "<(script|style)[^>]*>.*?</\\1>",
      with: " ",
      options: [.regularExpression, .caseInsensitive]
    )
    text = text.replacingOccurrences(
      of: "</?(p|div|h[1-6]|li|blockquote|br|tr|section)[^>]*>",
      with: "\n",
      options: [.regularExpression, .caseInsensitive]
    )
    text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
    text = HTMLEntities.decodeNumeric(text)

    return text.components(separatedBy: "\n")
      .map(collapseWhitespace)
      .filter { !$0.isEmpty }
  }

  static func collapseWhitespace(_ text: String) -> String {
    text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  private final class Collector: NSObject, XMLParserDelegate {
    private static let blockElements: Set<String> = [
      "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "br", "tr", "section",
      "article", "aside", "header", "footer", "figcaption", "dt", "dd", "pre", "hr",
    ]
    private static let skippedElements: Set<String> = ["head", "script", "style", "title", "rt"]

    var paragraphs = [String]()
    private var current = ""
    private var skipDepth = 0

    func endBlock() {
      let text = XHTMLTextParser.collapseWhitespace(current)
      if !text.isEmpty { paragraphs.append(text) }
      current = ""
    }

    func parser(
      _ parser: XMLParser,
      didStartElement elementName: String,
      namespaceURI: String?,
      qualifiedName qName: String?,
      attributes attributeDict: [String: String] = [:]
    ) {
      let name = localName(elementName).lowercased()
      if Self.skippedElements.contains(name) {
        skipDepth += 1
      } else if Self.blockElements.contains(name) {
        endBlock()
      }
    }

    func parser(
      _ parser: XMLParser,
      didEndElement elementName: String,
      namespaceURI: String?,
      qualifiedName qName: String?
    ) {
      let name = localName(elementName).lowercased()
      if Self.skippedElements.contains(name) {
        skipDepth = max(0, skipDepth - 1)
      } else if Self.blockElements.contains(name) {
        endBlock()
      }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
      guard skipDepth == 0 else { return }
      current += string
    }
  }
}

/// XHTML in EPUBs often uses HTML's named entities, which XML doesn't know
enum HTMLEntities {
  private static let named: [String: String] = [
    "nbsp": "&#160;", "ensp": "&#8194;", "emsp": "&#8195;", "thinsp": "&#8201;",
    "mdash": "&#8212;", "ndash": "&#8211;", "hellip": "&#8230;", "lsquo": "&#8216;",
    "rsquo": "&#8217;", "ldquo": "&#8220;", "rdquo": "&#8221;", "laquo": "&#171;",
    "raquo": "&#187;", "copy": "&#169;", "reg": "&#174;", "trade": "&#8482;", "shy": "&#173;",
    "eacute": "&#233;", "egrave": "&#232;", "aacute": "&#225;", "agrave": "&#224;",
    "iacute": "&#237;", "oacute": "&#243;", "uacute": "&#250;", "ntilde": "&#241;",
    "ccedil": "&#231;", "uuml": "&#252;", "ouml": "&#246;", "auml": "&#228;", "szlig": "&#223;",
    "bull": "&#8226;", "middot": "&#183;", "deg": "&#176;", "frac12": "&#189;",
  ]
  /// The five XML defines itself
  private static let xmlEntities: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

  static func makeXMLSafe(_ source: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "&([A-Za-z][A-Za-z0-9]*);") else { return source }

    var result = ""
    var lastEnd = source.startIndex
    let range = NSRange(source.startIndex..., in: source)
    for match in regex.matches(in: source, range: range) {
      guard
        let whole = Range(match.range, in: source),
        let nameRange = Range(match.range(at: 1), in: source)
      else { continue }

      result += source[lastEnd..<whole.lowerBound]
      let name = String(source[nameRange])
      if xmlEntities.contains(name) {
        result += source[whole]
      } else {
        result += named[name] ?? " "
      }
      lastEnd = whole.upperBound
    }
    result += source[lastEnd...]
    return result
  }

  /// For the fallback path, where nothing decodes entities for us
  static func decodeNumeric(_ text: String) -> String {
    var result = text
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&apos;", with: "'")
    guard let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") else { return result }

    let range = NSRange(result.startIndex..., in: result)
    for match in regex.matches(in: result, range: range).reversed() {
      guard
        let whole = Range(match.range, in: result),
        let hexRange = Range(match.range(at: 1), in: result),
        let numberRange = Range(match.range(at: 2), in: result)
      else { continue }
      let radix = result[hexRange].isEmpty ? 10 : 16
      let scalar = UInt32(result[numberRange], radix: radix).flatMap(Unicode.Scalar.init)
      result.replaceSubrange(whole, with: scalar.map { String(Character($0)) } ?? " ")
    }
    return result
  }
}

/// "dc:title" → "title"
private func localName(_ elementName: String) -> String {
  elementName.split(separator: ":").last.map(String.init) ?? elementName
}
