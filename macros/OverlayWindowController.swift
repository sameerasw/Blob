import SwiftUI
import AppKit

struct RingView: View {
    var body: some View {
        Circle()
            .stroke(Color.black, lineWidth: 4)
            .frame(width: 40, height: 40)
            .background(Color.clear)
    }
}

class OverlayWindowController {
    var window: NSPanel?
    
    init() {
        setupWindow()
    }
    
    private func setupWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 60, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        let contentView = NSHostingView(rootView: RingView())
        panel.contentView = contentView
        
        self.window = panel
    }
    
    func show(at point: CGPoint) {
        print("DEBUG: WindowController.show(at: \(point))")
        guard let window = window else { 
            print("ERROR: Window is nil")
            return 
        }
        
        // Adjust for center of the ring (assuming 60x60 window and 40x40 ring)
        let windowSize: CGFloat = 60
        let x = point.x - (windowSize / 2)
        let y = point.y - (windowSize / 2)
        
        // Note: macOS coordinates are bottom-left origin, but move(to:) usually handles screen coords correctly if using NSScreen frames
        // However, point from CGEvent is usually flipped compared to NSWindow.
        // We'll use a conversion helper if needed.
        
        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.makeKeyAndOrderFront(nil)
        panelOrderFront()
    }
    
    func hide() {
        print("DEBUG: WindowController.hide()")
        window?.orderOut(nil)
    }
    
    func updatePosition(to point: CGPoint) {
        let windowSize: CGFloat = 60
        let x = point.x - (windowSize / 2)
        let y = point.y - (windowSize / 2)
        window?.setFrameOrigin(NSPoint(x: x, y: y))
    }
    
    private func panelOrderFront() {
        // Ensure it's on top without stealing focus
        window?.orderFrontRegardless()
    }
}
