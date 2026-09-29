//
//  shiki_swiftApp.swift
//  shiki-swift
//
//  Created by Fayaz Ahmed Aralikatti on 14/08/26.
//

import SwiftUI

@main
struct shiki_swiftApp: App {
    @State private var appTheme = AppTheme()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appTheme)
        }
        .defaultSize(width: 1240, height: 820) // Clamped to the screen by macOS.
        .windowResizability(.contentMinSize)
        .commands { ThemeCommands(appTheme: appTheme) }
    }
}
