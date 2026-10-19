//
//  AppleStoreInventoryTrackerApp.swift
//  AppleStoreInventoryTracker
//
//  Created by Chenjun Ren on 2023/10/16.
//

import SwiftUI

@main
struct AppleStoreInventoryTrackerApp: App {
    @State private var viewModel = ContentViewModel()

    var body: some Scene {
        MenuBarExtra("AppleStoreInventoryTracker", systemImage: "storefront") {
            ContentView(vm: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
