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
        textView
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
    HStack(spacing: 8) {
      if model.status == .listening || model.status == .starting {
        ProgressView()
          .controlSize(.small)
      }
      Text(statusText)
        .bpFont(.caption)
        .foregroundStyle(model.status == .notInEbook ? Color.orange : theme.secondaryColor)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal)
    .padding(.vertical, 6)
    .background(theme.secondarySystemBackgroundColor)
    .accessibilityElement(children: .combine)
  }

  // MARK: - The text

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
