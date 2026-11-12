//
//  CoreServices.swift
//  BookPlayerWatch
//
//  Created by Gianni Carlo on 19/11/24.
//  Copyright © 2024 BookPlayer LLC. All rights reserved.
//

import BookPlayerWatchKit
import Foundation

class CoreServices: ObservableObject {
  let dataManager: DataManager
  let accountService: AccountServiceProtocol
  var syncService: SyncServiceProtocol
  var syncQueueService: SyncQueueServiceProtocol
  let libraryService: LibraryService
  let playbackService: PlaybackServiceProtocol
  let playerManager: PlayerManager
  let playerLoaderService: PlayerLoaderService
  let watchConnectivityService: WatchConnectivityService
  /// Pull-only on watchOS: resolves the sticky library sort so the list and
  /// playback navigation match the phone. Nothing on the watch writes sort
  /// preferences, and its pull is gated on the account's sync entitlement.
  let preferencesService: PreferencesSyncServiceProtocol

  @Published var hasSyncEnabled = false
  /// Whether the watch's own library has anything, e.g. books sent from the iPhone
  @Published var hasLocalBooks = false
  /// Received files being added right now (main actor), so a second hand-over can't add one twice
  private var receivedFilesBeingAdded = Set<String>()

  init(
    dataManager: DataManager,
    accountService: AccountServiceProtocol,
    syncService: SyncServiceProtocol,
    syncQueueService: SyncQueueServiceProtocol,
    libraryService: LibraryService,
    playbackService: PlaybackServiceProtocol,
    playerManager: PlayerManager,
    playerLoaderService: PlayerLoaderService,
    watchConnectivityService: WatchConnectivityService,
    preferencesService: PreferencesSyncServiceProtocol
  ) {
    self.dataManager = dataManager
    self.accountService = accountService
    self.syncService = syncService
    self.syncQueueService = syncQueueService
    self.libraryService = libraryService
    self.playbackService = playbackService
    self.hasSyncEnabled = accountService.hasSyncEnabled()
    self.playerManager = playerManager
    self.playerLoaderService = playerLoaderService
    self.watchConnectivityService = watchConnectivityService
    self.preferencesService = preferencesService
    self.hasLocalBooks = libraryService.getMaxItemsCount(at: nil) > 0
  }

  /// Adds a book file sent from the iPhone (already in the Processed folder) to the library
  @MainActor
  func addReceivedBook(at fileURL: URL) async {
    /// The launch sweep and a file handed over on arrival can name the same file
    let name = fileURL.lastPathComponent
    guard
      !receivedFilesBeingAdded.contains(name),
      libraryService.getSimpleItem(with: name) == nil
    else { return }

    receivedFilesBeingAdded.insert(name)
    defer { receivedFilesBeingAdded.remove(name) }

    await libraryService.insertItems(from: [fileURL])
    hasLocalBooks = true
    NotificationCenter.default.post(name: .watchLocalLibraryChanged, object: nil)
  }

  /// Adds files at the Processed folder's root that the library doesn't know: a book that
  /// arrived while the watch was woken in the background and suspended before it was added.
  /// Skipped while syncing, where the cloud owns what's in the library
  @MainActor
  func addUntrackedReceivedBooks() async {
    guard !syncService.isActive else { return }

    let folder = DataManager.getProcessedFolderURL()
    let files =
      (try? FileManager.default.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )) ?? []

    let untracked = files.filter { url in
      let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
      return !isDirectory && libraryService.getSimpleItem(with: url.lastPathComponent) == nil
    }

    guard !untracked.isEmpty else { return }

    for fileURL in untracked {
      await addReceivedBook(at: fileURL)
    }
  }

  func checkAndReloadIfSyncIsEnabled() {
    self.hasSyncEnabled = accountService.hasSyncEnabled()
    // SyncQueueService re-derives its own policy from .accountUpdate (posted by the
    // Shared AccountService update this flow just ran) — no manual forwarding needed.
  }

  func updateSyncEnabled(_ enabled: Bool) {
    hasSyncEnabled = enabled
    syncService.updateSyncEnabled(enabled)
  }

}
