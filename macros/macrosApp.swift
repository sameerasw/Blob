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
