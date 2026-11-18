//
//  RootView.swift
//  BookPlayerWatch Extension
//
//  Created by gianni.carlo on 22/2/22.
//  Copyright © 2022 BookPlayer LLC. All rights reserved.
//

import BookPlayerWatchKit
import SwiftUI

struct RootView: View {
  @ObservedObject var coreServices: CoreServices
  @ObservedObject var contextManager = ExtensionDelegate.contextManager
  @State var showSettings = false

  var body: some View {
    VStack {
      if coreServices.hasSyncEnabled || coreServices.hasLocalBooks {
        RemoteItemListView(model: .init(coreServices: coreServices))
      } else if contextManager.items.isEmpty && contextManager.isConnecting {
        ProgressView()
      } else {
        itemList
      }
    }
    .toolbar {
      /// Settings holds only the BookPlayer account sign-in, which a personal build doesn't have
      if !AppEnvironment.isPersonalBuild {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            showSettings = true
          } label: {
            Image(systemName: "gear")
          }
        }
      }
    }
    .fullScreenCover(isPresented: $showSettings) {
      let account = coreServices.accountService.getAccount()
      SettingsView(
        account:
          account?.hasId == true
          ? account
          : nil
      )
      .environment(\.coreServices, coreServices)
      .ignoresSafeArea(edges: .bottom)
    }
  }

  var itemList: some View {
    Group {
      if #available(watchOS 8.0, *) {
        ItemListView()
          .navigationTitle("recent_title")
          .navigationBarTitleDisplayMode(.inline)
          .environmentObject(contextManager)
      } else {
        ItemListView()
          .navigationTitle("recent_title")
          .environmentObject(contextManager)
      }
    }
  }
}
