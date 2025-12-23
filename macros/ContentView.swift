import SwiftUI

struct ContentView: View {
    @ObservedObject var mouseMonitor: MouseMonitor
    @AppStorage("showWindowTitles") private var showWindowTitles = false
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: mouseMonitor.isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .resizable()
                .frame(width: 50, height: 50)
                .foregroundColor(mouseMonitor.isTrusted ? .green : .orange)
            
            Text("Accessibility Permissions")
                .font(.headline)
            
            if mouseMonitor.isTrusted {
                VStack(spacing: 15) {
                    Text("Macro features active.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Selection Settings")
                            .font(.headline)
                        
                        Toggle("Reverse Scroll Direction", isOn: $mouseMonitor.reverseScroll)
                            .toggleStyle(.switch)
                            
                        Toggle("Show Window Titles", isOn: $showWindowTitles)
                            .toggleStyle(.switch)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Scroll Sensitivity")
                                Spacer()
                                Text(String(format: "%.1fx", mouseMonitor.scrollSensitivity))
                                    .foregroundStyle(.secondary)
                                    .font(.system(.body, design: .monospaced))
                            }
                            
                            Slider(value: $mouseMonitor.scrollSensitivity, in: 1.0...5.0, step: 0.1)
                            
                            Text("Higher value = slower number change (requires more scrolling).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                VStack(spacing: 12) {
                    Text("Macro features require Accessibility permissions to monitor mouse events globally.")
                        .multilineTextAlignment(.center)
                    
                    Button("Grant Permissions") {
                        mouseMonitor.requestPermissions()
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("Open System Settings") {
                        mouseMonitor.openAccessibilitySettings()
                    }
                    .buttonStyle(.bordered)
                    
                    Text("Manual: System Settings > Privacy & Security > Accessibility > Enable 'macros'")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Divider()
            
            VStack(alignment: .leading, spacing: 5) {
                Text("Instructions:")
                    .font(.caption.bold())
                Text("• Hold Button 5: Show Ring + Selection")
                    .font(.caption)
                Text("• Scroll (Held): Change Macro (1-7)")
                    .font(.caption)
                Text("• Release Button 5: Hide Overlay")
                    .font(.caption)
            }
        }
        .padding(30)
        .frame(width: 400)
    }
}
