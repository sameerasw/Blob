//
//  macrosApp.swift
//  macros
//
//  Created by Sameera Sandakelum on 2025-12-22.
//

import SwiftUI

@main
struct macrosApp: App {
    @StateObject private var mouseMonitor = MouseMonitor()
    
    var body: some Scene {
        WindowGroup {
            ContentView(mouseMonitor: mouseMonitor)
        }
    }
}
