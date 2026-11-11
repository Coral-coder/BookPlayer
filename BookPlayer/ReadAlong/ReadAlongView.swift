//
//  ReadAlongView.swift
//  BookPlayer
//
//  The ebook beside its audiobook: the word being read is highlighted and the text follows it.
//

import BookPlayerKit
import SwiftUI
import UniformTypeIdentifiers

struct ReadAlongView: View {
  @StateObject var model: ReadAlongViewModel
  @EnvironmentObject private var theme: ThemeViewModel
  @Environment(\.dismiss) private var dismiss

  @State private var showsFilePicker = false
  @State private var followsNarration = true
  @State private var pageIndex = 0
  @StateObject private var pager = ReadAlongPager()
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var showsUnpairConfirmation = false

  init(initModel: @escaping () -> ReadAlongViewModel) {
    self._model = .init(wrappedValue: initModel())
  }

  var body: some View {
    NavigationStack {
      content
        .background(theme.systemBackgroundColor.ignoresSafeArea())
        .navigationTitle(model.bookTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .fileImporter(isPresented: $showsFilePicker, allowedContentTypes: [.epub]) { result in
          switch result {
          case .success(let url):
            model.pair(with: url, fromShelf: false)
          case .failure(let error):
            model.error = error
          }
        }
        .confirmationDialog(
          "read_along_remove_ebook_title",
          isPresented: $showsUnpairConfirmation,
          titleVisibility: .visible
        ) {
          Button("read_along_remove_ebook_title", role: .destructive) { model.unpair() }
          Button("cancel_button", role: .cancel) {}
        }
        .alert(
          "error_title",
          isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
        ) {
          Button("ok_button", role: .cancel) {}
        } message: {
          Text(model.error?.localizedDescription ?? "")
        }
    }
    .onAppear { model.onAppear() }
    .onDisappear { model.onDisappear() }
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .needsEbook:
      chooseEbookView
    case .following:
      VStack(spacing: 0) {
        statusBar
        pagedText
      }
    }
  }

  // MARK: - Choosing the ebook

  private var chooseEbookView: some View {
    List {
      Section {
        Text("read_along_intro_description")
          .bpFont(.body)
          .foregroundStyle(theme.secondaryColor)
      }

      if !model.shelf.isEmpty {
        Section {
          ForEach(model.shelf) { ebook in
            Button {
              model.pair(with: ebook.url, fromShelf: true)
            } label: {
              Label(ebook.title, systemImage: "book.closed")
                .bpFont(.body)
                .foregroundStyle(theme.primaryColor)
            }
          }
        } header: {
          Text("read_along_imported_ebooks_title")
        }
      }

      Section {
        Button {
          showsFilePicker = true
        } label: {
          Label("read_along_choose_file_title", systemImage: "folder")
            .bpFont(.body)
            .foregroundStyle(theme.linkColor)
        }
      } footer: {
        Text("read_along_import_hint")
      }
    }
    .scrollContentBackground(.hidden)
    .onAppear { model.refreshShelf() }
  }

  // MARK: - Status

  private var statusText: LocalizedStringKey {
    switch model.status {
    case .starting: return "read_along_status_starting"
    case .waitingForPlayback: return "read_along_status_waiting"
    case .listening: return "read_along_status_listening"
    case .following: return "read_along_status_following"
    case .notInEbook: return "read_along_status_not_found"
    case .stopped: return "read_along_status_stopped"
    }
  }

  private var statusBar: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        if model.status == .listening || model.status == .starting {
          ProgressView()
            .controlSize(.small)
        }
        Text(statusText)
          .bpFont(.caption)
          .foregroundStyle(model.status == .notInEbook ? Color.orange : theme.secondaryColor)
      }
      if let heard = model.lastHeard {
        Text(heardText(heard))
          .bpFont(.caption)
          .foregroundStyle(theme.secondaryColor)
          .lineLimit(2)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal)
    .padding(.vertical, 6)
    .background(theme.secondarySystemBackgroundColor)
    .accessibilityElement(children: .combine)
  }

  private func heardText(_ heard: String) -> String {
    if let paragraph = model.lastFoundParagraph {
      return String(format: "read_along_heard_found".localized, heard, paragraph + 1)
    }
    return String(format: "read_along_heard_not_found".localized, heard)
  }

  // MARK: - The text

  // MARK: - Pages

  /// The ebook laid out in pages the size of the screen. While following, the page turns when the
  /// narration reaches the next one; swiping to another page stops following until Follow along
  private var pagedText: some View {
    GeometryReader { geometry in
      let pageSize = CGSize(
        width: max(geometry.size.width - 40, 100),
        height: max(geometry.size.height - 56, 100)
      )

      ZStack(alignment: .bottom) {
        if let layout = pager.layout, layout.pageCount > 0 {
          TabView(selection: $pageIndex) {
            ForEach(0..<layout.pageCount, id: \.self) { index in
              ReadAlongPageView(container: layout.containers[index])
                .frame(width: pageSize.width, height: pageSize.height)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 16)
                .tag(index)
            }
          }
          .tabViewStyle(.page(indexDisplayMode: .never))

          HStack {
            Text(String(format: "read_along_page_number".localized, pageIndex + 1, layout.pageCount))
              .bpFont(.caption)
              .foregroundStyle(theme.secondaryColor)
            Spacer()
            if !followsNarration {
              Button {
                followsNarration = true
                turnToCurrentWord(animated: true)
              } label: {
                Label("read_along_follow_button", systemImage: "text.line.first.and.arrowtriangle.forward")
                  .bpFont(.headline)
              }
              .buttonStyle(.borderedProminent)
              .tint(theme.linkColor)
            }
          }
          .padding(.horizontal, 20)
          .padding(.bottom, 8)
        } else {
          ProgressView("read_along_preparing_pages")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
      }
      .task(id: PageKey(size: pageSize, paragraphs: model.paragraphs.count, typeSize: dynamicTypeSize)) {
        await pager.paginate(
          paragraphs: model.paragraphs,
          pageSize: pageSize,
          textColor: UIColor(theme.primaryColor),
          highlightColor: UIColor(theme.linkColor).withAlphaComponent(0.3)
        )
        pager.highlight(word: model.currentWord)
        turnToCurrentWord(animated: false)
      }
    }
    .onChange(of: model.currentWord) { _, word in
      pager.highlight(word: word)
      if followsNarration { turnToCurrentWord(animated: true) }
    }
    .onChange(of: pageIndex) { _, page in
      /// A swipe away from the word being read stops following; back onto its page resumes it
      guard let word = model.currentWord, let wordPage = pager.page(ofWord: word) else { return }
      followsNarration = page == wordPage
    }
  }

  private func turnToCurrentWord(animated: Bool) {
    guard let word = model.currentWord, let page = pager.page(ofWord: word), page != pageIndex else { return }
    if animated {
      withAnimation(.easeInOut(duration: 0.35)) { pageIndex = page }
    } else {
      pageIndex = page
    }
  }

  private var textView: some View {
    let currentParagraph = model.currentWord.flatMap(model.paragraphIndex(ofWord:))

    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 16) {
          ForEach(model.paragraphs.indices, id: \.self) { index in
            ReadAlongParagraphView(
              words: model.paragraphs[index],
              highlightedWord: highlightedWord(inParagraph: index, current: currentParagraph),
              textColor: theme.primaryColor,
              highlightColor: theme.linkColor
            )
            .id(index)
            .contentShape(Rectangle())
            .onTapGesture {
              model.jump(toParagraph: index)
              followsNarration = true
            }
            .accessibilityAddTraits(model.phase == .following ? .isButton : [])
            .accessibilityHint(model.phase == .following ? Text("read_along_paragraph_hint") : Text(""))
          }
        }
        .padding()
      }
      .simultaneousGesture(
        DragGesture(minimumDistance: 10).onChanged { _ in
          if model.phase == .following { followsNarration = false }
        }
      )
      .onChange(of: currentParagraph) { _, paragraph in
        guard followsNarration, let paragraph else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
          proxy.scrollTo(paragraph, anchor: UnitPoint(x: 0.5, y: 0.35))
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if model.phase == .following, !followsNarration {
          Button {
            followsNarration = true
            if let currentParagraph {
              withAnimation { proxy.scrollTo(currentParagraph, anchor: UnitPoint(x: 0.5, y: 0.35)) }
            }
          } label: {
            Label("read_along_follow_button", systemImage: "text.line.first.and.arrowtriangle.forward")
              .bpFont(.headline)
          }
          .buttonStyle(.borderedProminent)
          .tint(theme.linkColor)
          .padding()
        }
      }
    }
  }

  private func highlightedWord(inParagraph index: Int, current: Int?) -> Int? {
    guard model.phase == .following, index == current, let word = model.currentWord else { return nil }
    return word - model.paragraphStarts[index]
  }

  // MARK: - Toolbar

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .cancellationAction) {
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark")
      }
      .accessibilityLabel("close_button")
    }
    ToolbarItem(placement: .primaryAction) {
      Menu {
        Button {
          model.playPause()
        } label: {
          Label(
            model.isPlaying ? "pause_title" : "play_title",
            systemImage: model.isPlaying ? "pause.fill" : "play.fill"
          )
        }
        if model.phase == .following {
          Button {
            model.startOver()
          } label: {
            Label("read_along_start_over_button", systemImage: "arrow.counterclockwise")
          }
        }
        if model.phase != .needsEbook {
          Button(role: .destructive) {
            showsUnpairConfirmation = true
          } label: {
            Label("read_along_remove_ebook_title", systemImage: "trash")
          }
        }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .accessibilityLabel("more_title")
    }
    ToolbarItem(placement: .bottomBar) {
      Button {
        model.playPause()
      } label: {
        Image(systemName: model.isPlaying ? "pause.circle.fill" : "play.circle.fill")
          .font(.largeTitle)
      }
      .accessibilityLabel(model.isPlaying ? "pause_title" : "play_title")
    }
  }
}

/// One paragraph, with the word being read highlighted. Only the paragraph holding that word
/// changes as playback moves, so the rest of the text isn't redrawn
private struct ReadAlongParagraphView: View, Equatable {
  let words: [String]
  let highlightedWord: Int?
  let textColor: Color
  let highlightColor: Color

  var body: some View {
    Text(attributedText)
      .bpFont(.bodyStory)
      .foregroundStyle(textColor)
      .lineSpacing(4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .textSelection(.enabled)
  }

  private var attributedText: AttributedString {
    var text = AttributedString()
    for (index, word) in words.enumerated() {
      var piece = AttributedString(word)
      if index == highlightedWord {
        piece.backgroundColor = highlightColor.opacity(0.35)
        piece.underlineStyle = .single
      }
      text += piece
      if index < words.count - 1 { text += AttributedString(" ") }
    }
    return text
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.highlightedWord == rhs.highlightedWord && lhs.words == rhs.words
  }
}

private struct PageKey: Equatable {
  let size: CGSize
  let paragraphs: Int
  let typeSize: DynamicTypeSize
}

/// The ebook's text in pages: one TextKit layout over the whole book, with a text container per
/// page, so every page holds exactly what fits and a word's page is known from its characters.
/// The word being read gets a temporary background, which doesn't change the layout.
final class ReadAlongPageLayout: @unchecked Sendable {
  let storage: NSTextStorage
  let layoutManager: NSLayoutManager
  let containers: [NSTextContainer]
  /// Characters on each page
  let pageRanges: [NSRange]
  /// Characters of each word
  let wordRanges: [NSRange]

  var pageCount: Int { containers.count }

  private init(
    storage: NSTextStorage,
    layoutManager: NSLayoutManager,
    containers: [NSTextContainer],
    pageRanges: [NSRange],
    wordRanges: [NSRange]
  ) {
    self.storage = storage
    self.layoutManager = layoutManager
    self.containers = containers
    self.pageRanges = pageRanges
    self.wordRanges = wordRanges
  }

  static func make(paragraphs: [[String]], pageSize: CGSize, textColor: UIColor) -> ReadAlongPageLayout {
    var text = ""
    var wordRanges = [NSRange]()
    var length = 0
    for (paragraphIndex, paragraph) in paragraphs.enumerated() {
      if paragraphIndex > 0 {
        text += "\n"
        length += 1
      }
      for (index, word) in paragraph.enumerated() {
        if index > 0 {
          text += " "
          length += 1
        }
        let wordLength = (word as NSString).length
        wordRanges.append(NSRange(location: length, length: wordLength))
        text += word
        length += wordLength
      }
    }

    let style = NSMutableParagraphStyle()
    style.lineSpacing = 4
    style.paragraphSpacing = 12
    let storage = NSTextStorage(string: text, attributes: [
      .font: UIFont.preferredFont(forTextStyle: .title3),
      .foregroundColor: textColor,
      .paragraphStyle: style,
    ])

    let layoutManager = NSLayoutManager()
    storage.addLayoutManager(layoutManager)

    var containers = [NSTextContainer]()
    var pageRanges = [NSRange]()
    let glyphCount = layoutManager.numberOfGlyphs
    var laidOut = 0
    while laidOut < glyphCount || containers.isEmpty {
      let container = NSTextContainer(size: pageSize)
      container.lineFragmentPadding = 0
      layoutManager.addTextContainer(container)
      let glyphs = layoutManager.glyphRange(for: container)
      /// A page that takes nothing (a line taller than the page) would loop forever
      guard glyphs.length > 0 else {
        layoutManager.removeTextContainer(at: layoutManager.textContainers.count - 1)
        break
      }
      containers.append(container)
      pageRanges.append(layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
      laidOut = NSMaxRange(glyphs)
    }

    return ReadAlongPageLayout(
      storage: storage,
      layoutManager: layoutManager,
      containers: containers,
      pageRanges: pageRanges,
      wordRanges: wordRanges
    )
  }

  func page(ofWord word: Int) -> Int? {
    guard wordRanges.indices.contains(word) else { return nil }
    let location = wordRanges[word].location
    var low = 0
    var high = pageRanges.count - 1
    var found: Int?
    while low <= high {
      let middle = (low + high) / 2
      if pageRanges[middle].location <= location {
        found = middle
        low = middle + 1
      } else {
        high = middle - 1
      }
    }
    return found
  }
}

@MainActor
final class ReadAlongPager: ObservableObject {
  @Published private(set) var layout: ReadAlongPageLayout?
  private var highlighted: NSRange?
  private var highlightColor = UIColor.systemYellow.withAlphaComponent(0.3)

  /// Lays the book out off the main thread; a long book takes a moment
  func paginate(paragraphs: [[String]], pageSize: CGSize, textColor: UIColor, highlightColor: UIColor) async {
    guard !paragraphs.isEmpty else {
      layout = nil
      return
    }
    self.highlightColor = highlightColor
    highlighted = nil
    let built = await Task.detached(priority: .userInitiated) {
      ReadAlongPageLayout.make(paragraphs: paragraphs, pageSize: pageSize, textColor: textColor)
    }.value
    guard !Task.isCancelled else { return }
    layout = built
  }

  func page(ofWord word: Int) -> Int? {
    layout?.page(ofWord: word)
  }

  func highlight(word: Int?) {
    guard let layout else { return }
    if let highlighted {
      layout.layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: highlighted)
    }
    guard let word, layout.wordRanges.indices.contains(word) else {
      highlighted = nil
      return
    }
    let range = layout.wordRanges[word]
    layout.layoutManager.addTemporaryAttribute(.backgroundColor, value: highlightColor, forCharacterRange: range)
    highlighted = range
  }
}

/// One page: a text view showing one of the layout's text containers
private struct ReadAlongPageView: UIViewRepresentable {
  let container: NSTextContainer

  func makeUIView(context: Context) -> UITextView {
    let view = UITextView(frame: CGRect(origin: .zero, size: container.size), textContainer: container)
    view.isEditable = false
    view.isSelectable = false
    view.isScrollEnabled = false
    view.backgroundColor = .clear
    view.textContainerInset = .zero
    view.adjustsFontForContentSizeCategory = false
    return view
  }

  func updateUIView(_ view: UITextView, context: Context) {}
}
