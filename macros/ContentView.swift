import SwiftUI

struct ContentView: View {
    @ObservedObject var mouseMonitor: MouseMonitor
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: mouseMonitor.isTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .resizable()
                .frame(width: 50, height: 50)
                .foregroundColor(mouseMonitor.isTrusted ? .green : .orange)
            
            Text("Accessibility Permissions")
                .font(.headline)
            
            if mouseMonitor.isTrusted {
                Text("Permissions granted. Holding Mouse Button 5 will show the ring overlay.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    Text("Macro features require Accessibility permissions to monitor mouse buttons globally.")
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
                Text("• Hold Button 5 (Forward): Show Ring")
                    .font(.caption)
                Text("• Release Button 5: Hide Ring")
                    .font(.caption)
            }
        }
        .padding(30)
        .frame(width: 350)
    }
}
