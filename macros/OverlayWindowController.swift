import SwiftUI
import AppKit
import Combine

class RingViewModel: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var scale: CGFloat = 0.5
    @Published var opacity: Double = 0.0
    
    func show() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            isVisible = true
            scale = 1.0
            opacity = 1.0
        }
    }
    
    func hide(completion: @escaping () -> Void) {
        withAnimation(.easeIn(duration: 0.2)) {
            scale = 0.5
            opacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.isVisible = false
            completion()
        }
    }
}

struct RingView: View {
    @ObservedObject var viewModel: RingViewModel
    
    var body: some View {
        ZStack {
            // Main Ring
            Circle()
                .stroke(Color.black, lineWidth: 6)
                .frame(width: 80, height: 80)
            
            // Badge (Number 1)
            HStack {
                Text("1")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.black))
            }
            // Position the badge above the circle's top edge.
            // Circle is 80x80, so top edge is at -40. 
            // We'll add some spacing (e.g., 10px).
            .offset(y: -60) 
        }
        .scaleEffect(viewModel.scale)
        .opacity(viewModel.opacity)
        .frame(width: 200, height: 200) // Large frame to accommodate badge and animation
    }
}

class OverlayWindowController {
    var window: NSPanel?
    private let viewModel = RingViewModel()
    private let windowSize: CGFloat = 200
    
    init() {
        setupWindow()
    }
    
    private func setupWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: windowSize, height: windowSize),
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
        
        let hostingView = NSHostingView(rootView: RingView(viewModel: viewModel))
        hostingView.alphaValue = 1.0
        panel.contentView = hostingView
        
        self.window = panel
    }
    
    func show(at point: CGPoint) {
        print("DEBUG: WindowController.show(at: \(point))")
        guard let window = window else { 
            print("ERROR: Window is nil")
            return 
        }
        
        // Centering logic: The center of the 200x200 window should be at 'point'
        let x = point.x - (windowSize / 2)
        let y = point.y - (windowSize / 2)
        
        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        
        viewModel.show()
    }
    
    func hide() {
        print("DEBUG: WindowController.hide()")
        viewModel.hide {
            self.window?.orderOut(nil)
        }
    }
    
    func updatePosition(to point: CGPoint) {
        // Maintain centering during movement
        let x = point.x - (windowSize / 2)
        let y = point.y - (windowSize / 2)
        window?.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
