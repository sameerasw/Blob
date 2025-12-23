import Foundation
import CoreGraphics
import AppKit
import SwiftUI
import Combine

class MouseMonitor: ObservableObject {
    @Published var isTrusted: Bool = false
    
    // Scroll Customization Persistence Keys
    private let reverseScrollKey = "reverseScroll"
    private let scrollSensitivityKey = "scrollSensitivity"
    
    // Scroll Customization
    @Published var reverseScroll: Bool {
        didSet {
            UserDefaults.standard.set(reverseScroll, forKey: reverseScrollKey)
        }
    }
    
    @Published var scrollSensitivity: Double {
        didSet {
            UserDefaults.standard.set(scrollSensitivity, forKey: scrollSensitivityKey)
        }
    }
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let overlayController = OverlayWindowController()
    private var permissionCheckTimer: Timer?
    
    // Mouse button 5 is index 4 in CGEvent data
    private let targetButtonNumber: Int64 = 4
    private var isButton5Down: Bool = false
    
    // Dynamic workspace names from AeroSpace
    @Published var workspaces: [String] = ["1", "2", "3", "4", "5", "6", "7"] // Fallback
    @Published var currentWorkspace: String = "1"
    private var initialWorkspace: String?
    
    // Smooth scrolling accumulator
    private var scrollAccumulator: Double = 0.0
    
    // Stationary overlay tracking
    private var triggerPoint: CGPoint?
    private var pendingGesture: GestureDirection?
    
    init() {
        // Load persisted settings
        self.reverseScroll = UserDefaults.standard.bool(forKey: reverseScrollKey)
        
        let savedSensitivity = UserDefaults.standard.double(forKey: scrollSensitivityKey)
        self.scrollSensitivity = savedSensitivity > 0 ? savedSensitivity : 1.0
        
        // Start fetches on background queues to avoid blocking initialization
        DispatchQueue.global(qos: .userInitiated).async {
            self.fetchAllWorkspaces()
        }
        
        checkPermissions()
        startPermissionCheckTimer()
    }
    
    private func fetchAllWorkspaces() {
        let executablePath = "/opt/homebrew/bin/aerospace"
        guard FileManager.default.fileExists(atPath: executablePath) else { return }
        
        let process = Process()
        let pipe = Pipe()
        
        var env = ProcessInfo.processInfo.environment
        env["AEROSPACE_WINDOW_ID"] = "null"
        env["AEROSPACE_WORKSPACE"] = "null"
        process.environment = env
        
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["list-workspaces", "--all"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            
            // Read data before/during wait to avoid pipe buffer deadlocks
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                
                if !lines.isEmpty {
                    DispatchQueue.main.async {
                        self.workspaces = lines
                        print("DEBUG: Fetched AeroSpace workspaces: \(lines)")
                    }
                }
            }
        } catch {
            print("ERROR: Failed to fetch all workspaces: \(error.localizedDescription)")
        }
    }
    
    func checkPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
        let accessEnabled = AXIsProcessTrustedWithOptions(options as CFDictionary)
        
        if accessEnabled != isTrusted {
            DispatchQueue.main.async {
                print("DEBUG: Accessibility trusted state changed to \(accessEnabled)")
                self.isTrusted = accessEnabled
                if accessEnabled {
                    print("DEBUG: Starting event tap...")
                    self.startEventTap()
                } else {
                    print("DEBUG: Stopping event tap...")
                    self.stopEventTap()
                }
            }
        }
    }
    
    func requestPermissions() {
        print("DEBUG: Requesting accessibility permissions...")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }
    
    func openAccessibilitySettings() {
        print("DEBUG: Opening Accessibility Settings...")
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
    
    private func startPermissionCheckTimer() {
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkPermissions()
        }
    }
    
    private func stopEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        eventTap = nil
    }
    
    private func startEventTap() {
        guard eventTap == nil else { 
            print("DEBUG: Event tap already active")
            return 
        }
        
        var eventMask: Int64 = 0
        eventMask |= (1 << CGEventType.otherMouseDown.rawValue)
        eventMask |= (1 << CGEventType.otherMouseUp.rawValue)
        eventMask |= (1 << CGEventType.otherMouseDragged.rawValue)
        eventMask |= (1 << CGEventType.mouseMoved.rawValue)
        eventMask |= (1 << CGEventType.scrollWheel.rawValue)
        
        let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let monitor = Unmanaged<MouseMonitor>.fromOpaque(refcon!).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: observer
        ) else {
            print("ERROR: Failed to create event tap")
            return
        }
        
        print("DEBUG: Event tap created successfully")
        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Handle Scroll Events
        if type == .scrollWheel {
            if isButton5Down {
                // Determine direction based on raw delta
                var delta = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
                if delta == 0 {
                    delta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
                }
                
                // RESTRICT SCROLL: Only allow if mouse is moved UP far enough
                let location = self.convertPoint(event.location)
                if let trigger = triggerPoint {
                    let offsetY = -(location.y - trigger.y)
                    // If mouse is not far enough UP (beyond threshold), convert to horizontal scroll
                    if offsetY > -100 { // UP is negative offsetY
                        let vDelta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                        let vDeltaFixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
                        
                        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: vDelta)
                        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: vDeltaFixed)
                        
                        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
                        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
                        
                        return Unmanaged.passRetained(event)
                    } else {
                        // In workspace switching zone - ensure badge is visible
                        DispatchQueue.main.async {
                            self.overlayController.setBadgeVisible(true)
                        }
                    }
                }
                
                if reverseScroll {
                    delta = -delta
                }
                
                scrollAccumulator += (delta / scrollSensitivity)
                
                if abs(scrollAccumulator) >= 1.0 {
                    let steps = Int(floor(abs(scrollAccumulator)))
                    let direction = scrollAccumulator > 0 ? 1 : -1
                    
                    // Cycle through workspace names
                    if let currentIndex = workspaces.firstIndex(of: currentWorkspace) {
                        let newIndex = currentIndex + (steps * direction)
                        let clampedIndex = max(0, min(newIndex, workspaces.count - 1))
                        currentWorkspace = workspaces[clampedIndex]
                    }
                    
                    scrollAccumulator -= Double(steps * direction)
                    
                    DispatchQueue.main.async {
                        self.overlayController.setWorkspaceName(self.currentWorkspace, direction: direction)
                    }
                }
                return nil // Consume
            }
        }
        
        // Handle Mouse Buttons
        if type == .otherMouseDown || type == .otherMouseUp {
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            
            if buttonNumber == targetButtonNumber {
                let location = event.location
                if type == .otherMouseDown {
                    isButton5Down = true
                    
                    // ON-DEMAND SYNC: Fetch current workspace before showing
                    fetchCurrentWorkspace()
                    
                    initialWorkspace = currentWorkspace
                    scrollAccumulator = 0
                    
                    print("DEBUG: Showing overlay at \(location). Current Workspace: \(currentWorkspace)")
                    let point = self.convertPoint(location)
                    self.triggerPoint = point
                    DispatchQueue.main.async {
                        self.overlayController.setWorkspaceName(self.currentWorkspace)
                        self.overlayController.setBadgeVisible(false) // ENSURE HIDDEN AT START
                        self.overlayController.show(at: point)
                    }
                } else {
                    isButton5Down = false
                    print("DEBUG: Hiding overlay")
                    self.triggerPoint = nil
                    
                    // Trigger pending gesture or final workspace switch on hide
                    let gestureToFire = self.pendingGesture
                    self.pendingGesture = nil
                    
                    DispatchQueue.main.async {
                        self.overlayController.updateMouseOffset(CGSize.zero)
                        self.overlayController.setIndicatorIcon(nil as String?)
                        self.overlayController.hide()
                    }
                    
                    if let gesture = gestureToFire, gesture != .scroll {
                        triggerWorkspaceGesture(direction: gesture)
                    } else if let initial = initialWorkspace, currentWorkspace != initial {
                        // Regular scroll-based switch
                        print("DEBUG: Workspace changed via scroll from \(initial) to \(currentWorkspace). Running AeroSpace command.")
                        runAeroSpaceCommand(for: currentWorkspace)
                    }
                    initialWorkspace = nil
                }
            }
        } else if type == .otherMouseDragged || type == .mouseMoved {
            let location = self.convertPoint(event.location)
            
            if let trigger = triggerPoint {
                // Calculate offset relative to stationary trigger point
                let offset = CGSize(
                    width: location.x - trigger.x,
                    height: -(location.y - trigger.y) // Invert Y for SwiftUI offset
                )
                DispatchQueue.main.async {
                    self.overlayController.updateMouseOffset(offset)
                }
                
                // Gesture Detection
                let distance = sqrt(pow(offset.width, 2) + pow(offset.height, 2))
                let exitThreshold: CGFloat = 160 // Distance to "select"
                let resetThreshold: CGFloat = 80 // Distance to "clear/reset"
                let badgeThreshold: CGFloat = 60 // Distance to show workspace name
                
                if distance > badgeThreshold {
                    DispatchQueue.main.async {
                        self.overlayController.setBadgeVisible(true)
                    }
                } else if distance < 30 {
                    DispatchQueue.main.async {
                        self.overlayController.setBadgeVisible(false)
                    }
                }

                if distance > exitThreshold {
                    // Update pending gesture based on direction
                    if abs(offset.width) > abs(offset.height) { // horizontal focus
                        let newGesture: GestureDirection = offset.width > 0 ? .next : .prev
                        if pendingGesture != newGesture {
                            pendingGesture = newGesture
                            let icon = newGesture == .next ? "arrow.right.circle.fill" : "arrow.left.circle.fill"
                            
                            // PREVIEW TARGET WORKSPACE
                            let direction = newGesture == .next ? 1 : -1
                            if let targetWorkspace = self.workspaceAt(offset: direction) {
                                DispatchQueue.main.async {
                                    self.overlayController.setWorkspaceName(targetWorkspace, direction: direction)
                                    self.overlayController.setIndicatorIcon(icon)
                                }
                            }
                        }
                    } else if offset.height < -120 { // Vertical UP focus (Scroll Zone)
                        if pendingGesture != .scroll {
                            pendingGesture = .scroll
                            DispatchQueue.main.async {
                                self.overlayController.setIndicatorIcon("arrow.up.and.down.circle.fill")
                            }
                        }
                    }
                } else if distance < resetThreshold {
                    if pendingGesture != nil {
                        pendingGesture = nil
                        DispatchQueue.main.async {
                            self.overlayController.setWorkspaceName(self.currentWorkspace) // Reset to current
                            self.overlayController.setIndicatorIcon(nil as String?)
                        }
                    }
                }
                
                // Visual Feedback (Pre-selection arrows)
                if pendingGesture == nil {
                    if distance > 40 {
                        let icon: String?
                        if abs(offset.width) > abs(offset.height) {
                            icon = offset.width > 0 ? "arrow.right" : "arrow.left"
                        } else {
                            // If moving UP, show scroll icon if close to zone
                            if offset.height < -60 {
                                icon = "arrow.up.and.down.circle"
                            } else {
                                icon = offset.height > 0 ? "arrow.down" : "arrow.up"
                            }
                        }
                        DispatchQueue.main.async {
                            self.overlayController.setIndicatorIcon(icon)
                        }
                    } else {
                        DispatchQueue.main.async {
                            self.overlayController.setIndicatorIcon(nil as String?)
                        }
                    }
                }
            }
        }
        
        return Unmanaged.passRetained(event)
    }
    
    enum GestureDirection {
        case next, prev, scroll
    }
    
    private func workspaceAt(offset: Int) -> String? {
        guard let currentIndex = workspaces.firstIndex(of: currentWorkspace) else { return nil }
        let count = workspaces.count
        let newIndex = (currentIndex + offset + count) % count
        return workspaces[newIndex]
    }
    
    private func triggerWorkspaceGesture(direction: GestureDirection) {
        let command: String
        switch direction {
        case .next:
            command = "workspace next --wrap-around"
        case .prev:
            command = "workspace prev --wrap-around"
        case .scroll:
            return
        }
        
        print("DEBUG: Executing deferred gesture: \(command)")
        
        DispatchQueue.global(qos: .userInitiated).async {
            let aerospacePath = "/opt/homebrew/bin/aerospace"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: aerospacePath)
            process.arguments = command.components(separatedBy: " ")
            
            do {
                try process.run()
                process.waitUntilExit()
                
                // Refresh current workspace name after gesture
                self.fetchCurrentWorkspace()
            } catch {
                print("ERROR: Failed to run AeroSpace gesture command: \(error)")
            }
        }
    }
    
    private func fetchCurrentWorkspace() {
        DispatchQueue.global(qos: .userInitiated).async {
            let executablePath = "/opt/homebrew/bin/aerospace"
            guard FileManager.default.fileExists(atPath: executablePath) else { return }
            
            let process = Process()
            let pipe = Pipe()
            
            var env = ProcessInfo.processInfo.environment
            env["AEROSPACE_WINDOW_ID"] = "null"
            env["AEROSPACE_WORKSPACE"] = "null"
            process.environment = env
            
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["list-workspaces", "--focused"]
            process.standardOutput = pipe
            process.standardError = Pipe() 
            
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                
                if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    if !output.isEmpty {
                        print("DEBUG: Fetched current AeroSpace workspace: \(output)")
                        DispatchQueue.main.async {
                            self.currentWorkspace = output
                            self.overlayController.setWorkspaceName(output)
                        }
                    }
                }
            } catch {
                print("ERROR: Failed to fetch current workspace: \(error.localizedDescription)")
            }
        }
    }
    
    private func runAeroSpaceCommand(for workspace: String) {
        let executablePath = "/opt/homebrew/bin/aerospace"
        guard FileManager.default.fileExists(atPath: executablePath) else {
            print("ERROR: AeroSpace executable not found at \(executablePath)")
            return
        }
        
        let process = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()
        
        // Silence the "incomplete JSON request" warning
        var env = ProcessInfo.processInfo.environment
        env["AEROSPACE_WINDOW_ID"] = "null"
        env["AEROSPACE_WORKSPACE"] = "null"
        process.environment = env
        
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["workspace", workspace]
        process.standardOutput = pipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus != 0 {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                // Only log real errors, not the IPC warnings
                if !errorOutput.contains("incomplete JSON request") {
                    print("ERROR: AeroSpace command failed (status \(process.terminationStatus)): \(errorOutput)")
                }
            }
        } catch {
            print("ERROR: Failed to run AeroSpace process: \(error.localizedDescription)")
        }
    }
    
    private func convertPoint(_ cgPoint: CGPoint) -> CGPoint {
        if let mainScreen = NSScreen.screens.first {
            let screenHeight = mainScreen.frame.height
            return CGPoint(x: cgPoint.x, y: screenHeight - cgPoint.y)
        }
        return cgPoint
    }
    
    deinit {
        permissionCheckTimer?.invalidate()
        stopEventTap()
    }
}
