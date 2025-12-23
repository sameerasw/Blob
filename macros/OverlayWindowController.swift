import SwiftUI
import AppKit
import Combine

class RingViewModel: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var scale: CGFloat = 0.5
    @Published var opacity: Double = 0.0
    @Published var workspaceName: String = "1"
    @Published var mouseOffset: CGSize = .zero
    @Published var indicatorIcon: String? = nil
    @Published var badgeOpacity: Double = 0.0
    @Published var badgeOffset: CGFloat = 0.0
    @Published var hOffset: CGFloat = 0.0 // For gravitational shake
    @Published var scrollDirection: Int = 0 // For transition direction
    @Published var isExpanded: Bool = false
    @Published var isAtCenter: Bool = true
    
    func show() {
        // Reset badge state
        badgeOpacity = 0.0
        badgeOffset = 0.0
        isAtCenter = true
        indicatorIcon = nil
        isExpanded = false
        
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
            badgeOpacity = 0.0
            badgeOffset = 0.0
            isExpanded = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.isVisible = false
            completion()
        }
    }
    
    func setWorkspaceName(_ name: String, direction: Int = 0) {
        DispatchQueue.main.async {
            // Determine direction for transitions
            self.scrollDirection = direction
            
            // Trigger horizontal shake (gravitational pull)
            // User requested: increase -> shake left, decrease -> shake right
            let shakeAmount: CGFloat = direction > 0 ? -15 : 15
            
            if direction != 0 {
                withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.5)) {
                    self.hOffset = shakeAmount
                }
                
                // Spring back to center
                withAnimation(.spring(response: 0.4, dampingFraction: 0.4).delay(0.1)) {
                    self.hOffset = 0
                }
            }
            
            // Update name with slide transition
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                self.workspaceName = name
            }
        }
    }
    
    func setMouseOffset(_ offset: CGSize) {
        // We use immediate updates for the pointer to feel responsive,
        // but the merging effects are handled by the GlassEffectContainer
        DispatchQueue.main.async {
            self.mouseOffset = offset
        }
    }
    
    func setIndicatorIcon(_ icon: String?) {
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                self.indicatorIcon = icon
            }
        }
    }
    
    func setBadgeVisible(_ visible: Bool) {
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                self.badgeOpacity = visible ? 1.0 : 0.0
                self.badgeOffset = visible ? -55 : 0.0
            }
        }
    }
    
    func setExpanded(_ expanded: Bool) {
        DispatchQueue.main.async {
            if expanded {
                // FORCE badge opacity to 0 immediately when expanding
                self.badgeOpacity = 0.0
                self.badgeOffset = 0.0
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                self.isExpanded = expanded
            }
        }
    }
    
    func setBadgeProgress(_ progress: CGFloat) {
        DispatchQueue.main.async {
            // If moved enough, we are no longer "at center"
            if progress > 0.1 {
                self.isAtCenter = false
            } else if progress == 0 {
                self.isAtCenter = true
            }
            
            // Smother jitter with a very responsive spring
            withAnimation(.interactiveSpring(response: 0.2, dampingFraction: 0.8)) {
                self.badgeOpacity = Double(progress)
                self.badgeOffset = -55 * progress
            }
        }
    }
}

struct RingView: View {
    @ObservedObject var viewModel: RingViewModel
    
    private var shouldShowBadge: Bool {
        guard let icon = viewModel.indicatorIcon else { return false }
        if viewModel.isExpanded { return false }
        
        // Exclude icons that shouldn't show the workspace name (downward/expansion)
        let excludedIcons = ["arrow.down", "plus.circle.fill"]
        return !excludedIcons.contains(icon)
    }
    
    var body: some View {
        ZStack {
            GlassEffectContainer {
                ZStack {
                    // Main Stationary Macro (Centered in the 600x600 container)
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.1), lineWidth: 0)
                            .glassEffect(.regular)
                            .frame(width: viewModel.isExpanded ? 160 : 80, height: viewModel.isExpanded ? 160 : 80)
                        
                        if shouldShowBadge {
                            ZStack {
                                Text(viewModel.workspaceName)
                                    .id(viewModel.workspaceName)
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .foregroundColor(.primary)
                                    .transition(
                                        .asymmetric(
                                            insertion: .move(edge: viewModel.scrollDirection > 0 ? .trailing : .leading),
                                            removal: .move(edge: viewModel.scrollDirection > 0 ? .leading : .trailing)
                                        ).combined(with: .opacity)
                                    )
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .glassEffect()
                            .opacity(viewModel.badgeOpacity) 
                            .offset(x: viewModel.hOffset, y: viewModel.badgeOffset)
                        }
                    }
                    
                    // Mouse Pointer Circle (Following the cursor)
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 0)
                        .glassEffect(.regular)
                        .frame(width: 30, height: 30)
                        .offset(viewModel.mouseOffset)
                }
            }
            
            // Gesture Indicator Icon (Absolute Top Layer, outside glass container)
            if let icon = viewModel.indicatorIcon {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.3), radius: 5)
                    .transition(.scale.combined(with: .opacity))
                    .zIndex(1000)
                    .id(icon)
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
    
    func setWorkspaceName(_ name: String, direction: Int = 0) {
        viewModel.setWorkspaceName(name, direction: direction)
    }
    
    func setIndicatorIcon(_ icon: String?) {
        viewModel.setIndicatorIcon(icon)
    }
    
    func setBadgeVisible(_ visible: Bool) {
        viewModel.setBadgeVisible(visible)
    }
    
    func setExpanded(_ expanded: Bool) {
        viewModel.setExpanded(expanded)
    }
    
    func setBadgeProgress(_ progress: CGFloat) {
        viewModel.setBadgeProgress(progress)
    }
}
