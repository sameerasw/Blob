import SwiftUI
import AppKit
import Combine

class RingViewModel: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var scale: CGFloat = 0.5
    @Published var opacity: Double = 0.0
    @Published var workspaceName: String = "1"
    @Published var mouseOffset: CGSize = .zero
    
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
            mouseOffset = .zero // Reset offset for next show
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.isVisible = false
            completion()
        }
    }
    
    func setWorkspaceName(_ name: String) {
        // We can add a subtle animation if the number changes while shown
        DispatchQueue.main.async {
            self.workspaceName = name
        }
    }
    
    func setMouseOffset(_ offset: CGSize) {
        // We use immediate updates for the pointer to feel responsive,
        // but the merging effects are handled by the GlassEffectContainer
        DispatchQueue.main.async {
            self.mouseOffset = offset
        }
    }
}

struct RingView: View {
    @ObservedObject var viewModel: RingViewModel
    
    var body: some View {
        GlassEffectContainer {
            ZStack {
                // Main Stationary Macro (Centered in the 600x600 container)
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 0)
                        .glassEffect(.regular)
                        .frame(width: 80, height: 80)
                    
                    Text(viewModel.workspaceName)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassEffect()
                        .offset(y: -55)
                }
                
                // Mouse Pointer Circle (Following the cursor)
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 0)
                    .glassEffect(.regular)
                    .frame(width: 30, height: 30)
                    .offset(viewModel.mouseOffset)
            }
        }
        .scaleEffect(viewModel.scale)
        .opacity(viewModel.opacity)
        .frame(width: 600, height: 600)
    }
}

class OverlayWindowController {
    var window: NSPanel?
    private let viewModel = RingViewModel()
    private let windowSize: CGFloat = 600
    
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
        guard let window = window else { return }
        
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
        let x = point.x - (windowSize / 2)
        let y = point.y - (windowSize / 2)
        window?.setFrameOrigin(NSPoint(x: x, y: y))
    }
    
    func updateMouseOffset(_ offset: CGSize) {
        viewModel.setMouseOffset(offset)
    }
    
    func setWorkspaceName(_ name: String) {
        viewModel.setWorkspaceName(name)
    }
}
