import Foundation
import CoreGraphics
import AppKit
import SwiftUI
import Foundation
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
    
    // Input Consumption State
    private var mouseDownTime: Date?
    private var actionTriggered: Bool = false
    private let swallowSourceID: Int64 = 777
    private var windowsFetchedThisSession = false
    private var isInteractiveMode = false
    private var clearIndicatorTimer: Timer?
    
    // Trackers for press duration and action consumption
    
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
        eventMask |= (1 << CGEventType.leftMouseDown.rawValue)
        
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
        // PREVENT FEEDBACK LOOP: If this is our re-posted event, pass it through
        if event.getIntegerValueField(.eventSourceUserData) == swallowSourceID {
            return Unmanaged.passRetained(event)
        }

        // Handle Left Click for Window Selection (Interactive Mode)
        if type == .leftMouseDown {
            if isInteractiveMode {
                let location = self.convertPoint(event.location)
                if let trigger = triggerPoint {
                    let offset = CGSize(
                        width: location.x - trigger.x,
                        height: -(location.y - trigger.y)
                    )
                    
                    let dist = sqrt(offset.width * offset.width + offset.height * offset.height)
                    
                    // Check if clicked ON Center Hub (Toggle Grouping)
                    if dist < 80 { // Expanded hub radius is 80 (frame 160)
                        print("DEBUG: Interactive Click on Center Hub - Toggling Grouping")
                        DispatchQueue.main.async {
                            self.overlayController.viewModel.toggleGrouping()
                        }
                        return nil // Consume click, keep overlay open
                    }
                    
                    // Check if clicked ON a window bubble
                    if let selectedWindow = self.overlayController.windowAtOffset(offset) {
                        print("DEBUG: Interactive Click on Window: \(selectedWindow.appName)")
                        self.focusWindow(id: "\(selectedWindow.id)", workspace: selectedWindow.workspace)
                        
                        // Dismiss after selecting window
                        DispatchQueue.main.async {
                            self.dismissOverlay()
                        }
                    } else {
                        print("DEBUG: Interactive Click Outside - Dismissing")
                        
                        // Dismiss if clicked outside everything
                        DispatchQueue.main.async {
                            self.dismissOverlay()
                        }
                    }
                }
                return nil // Consume the click
            }
        }

        // Handle Scroll Events
        if type == .scrollWheel {
            if isButton5Down || isInteractiveMode {
                let location = self.convertPoint(event.location)
                if let trigger = triggerPoint {
                    let offset = CGSize(
                        width: location.x - trigger.x,
                        height: -(location.y - trigger.y)
                    )
                    let dist = sqrt(offset.width * offset.width + offset.height * offset.height)
                    
                    // CENTER HUB SCROLL: Volume Control (Only in expanded/interactive mode)
                    if dist < 80 && (pendingGesture == .expand || isInteractiveMode) {
                        var delta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
                        if delta == 0 {
                            delta = Double(event.getIntegerValueField(.scrollWheelEventDeltaAxis1))
                        }
                        
                        if delta != 0 {
                            adjustVolume(delta: delta)
                            actionTriggered = true
                        }
                        return nil // Consume scroll
                    }
                }
                
                // Continue with regular workspace switching scroll if button 5 is held
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
                        
                        // IF EXPANDED: Disable workspace switching scroll zone
                        if pendingGesture == .expand {
                            let vDelta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                            let vDeltaFixed = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
                            
                            event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: vDelta)
                            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: vDeltaFixed)
                            
                            event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
                            event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
                            
                            return Unmanaged.passRetained(event)
                        }

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
                            actionTriggered = true // MARK AS ACTION TAKEN
                            DispatchQueue.main.async {
                                self.overlayController.setBadgeVisible(true)
                            }
                        }
                    }
                    
                    // Converting to horizontal scroll or switching workspace counts as action
                    actionTriggered = true
                    
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
        }
        
        // Handle Mouse Buttons
        if type == .otherMouseDown || type == .otherMouseUp {
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            
            if buttonNumber == targetButtonNumber {
                let location = event.location // Use raw screen location for re-posting
                if type == .otherMouseDown {
                    // TOGGLE LOGIC: If already in interactive mode, close it
                    if isInteractiveMode {
                        print("DEBUG: Toggling Interactive Mode OFF")
                        isInteractiveMode = false
                        triggerPoint = nil
                        pendingGesture = nil
                        initialWorkspace = nil
                        
                        DispatchQueue.main.async {
                            self.overlayController.updateMouseOffset(CGSize.zero)
                            self.overlayController.setIndicatorIcon(nil as String?)
                            self.overlayController.setHoveredWindow(nil)
                            self.overlayController.hide()
                        }
                        return nil // Swallow the toggle-off click
                    }
                    
                    isButton5Down = true
                    mouseDownTime = Date()
                    actionTriggered = false
                    
                    // ON-DEMAND SYNC: Fetch current workspace before showing
                    fetchCurrentWorkspace()
                    
                    initialWorkspace = currentWorkspace
                    scrollAccumulator = 0
                    
                    print("DEBUG: Showing overlay. Swallowing mouseDown.")
                    let point = self.convertPoint(location)
                    self.triggerPoint = point
                    DispatchQueue.main.async {
                        self.overlayController.setWorkspaceName(self.currentWorkspace)
                        self.overlayController.setBadgeVisible(false) // ENSURE HIDDEN AT START
                        
                        // Re-use windows: only fetch if empty
                        if !self.overlayController.hasWindows {
                            self.fetchWindows()
                        }
                        
                        // Fetch initial volume
                        self.fetchSystemVolume()
                        self.overlayController.show(at: point)
                    }
                    return nil // SWALLOW MOUSE DOWN
                } else {
                    isButton5Down = false
                    let duration = Date().timeIntervalSince(mouseDownTime ?? Date())
                    print("DEBUG: Hiding overlay. Duration: \(duration). Action Triggered: \(actionTriggered)")
                    
                    // IF EXPANDED: Enter Interactive Mode instead of hiding
                    if pendingGesture == .expand {
                        print("DEBUG: Entering Interactive Mode (Expanded)")
                        isInteractiveMode = true
                         // DO NOT Clear triggerPoint or pendingGesture yet
                        return nil // Swallow Mouse Up
                    }
                    
                    self.triggerPoint = nil
                    
                    // Trigger pending gesture or final workspace switch on hide
                    let gestureToFire = self.pendingGesture
                    self.pendingGesture = nil
                    
                    DispatchQueue.main.async {
                        self.overlayController.updateMouseOffset(CGSize.zero)
                        self.overlayController.setIndicatorIcon(nil as String?)
                        self.overlayController.hide()
                    }
                    
                    if let gesture = gestureToFire, gesture != .scroll && gesture != .expand {
                        triggerWorkspaceGesture(direction: gesture)
                    } else if gestureToFire != .expand, let initial = initialWorkspace, currentWorkspace != initial {
                        // Regular scroll-based switch
                        print("DEBUG: Workspace changed via scroll. Running AeroSpace command.")
                        runAeroSpaceCommand(for: currentWorkspace)
                    } else if !actionTriggered && duration < 1.0 {
                        // NO ACTION and SHORT PRESS: Re-post the click
                        print("DEBUG: Re-posting Button 5 Click")
                        
                        // Create Mouse Down
                        if let downEvent = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: location, mouseButton: .center) {
                            downEvent.setIntegerValueField(.mouseEventButtonNumber, value: targetButtonNumber)
                            downEvent.setIntegerValueField(.eventSourceUserData, value: swallowSourceID)
                            downEvent.post(tap: .cgSessionEventTap)
                        }
                        
                        // Create Mouse Up
                        if let upEvent = CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp, mouseCursorPosition: location, mouseButton: .center) {
                            upEvent.setIntegerValueField(.mouseEventButtonNumber, value: targetButtonNumber)
                            upEvent.setIntegerValueField(.eventSourceUserData, value: swallowSourceID)
                            upEvent.post(tap: .cgSessionEventTap)
                        }
                    }
                    
                    initialWorkspace = nil
                    return nil // SWALLOW MOUSE UP
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
                let expandThreshold: CGFloat = 80 // Distance to "expand"
                let resetThreshold: CGFloat = 80 // Distance to "clear/reset"
                
                // Calculation for interactive badge fade
                // Fade from distance 40 (edge of inner circle) to 80 (reset threshold)
                let progress = max(0, min(1, (distance - 40) / 40))
                let isMovingDown = offset.height > 40 && abs(offset.height) > abs(offset.width)
                
                if distance > 40 {
                    actionTriggered = true // Marking as action since user is moving away from center
                }
                
                if (pendingGesture == .expand || isMovingDown) {
                    DispatchQueue.main.async {
                        self.overlayController.setBadgeProgress(0)
                        
                        // Check for hover if already expanded
                        if self.pendingGesture == .expand {
                            if let window = self.overlayController.windowAtOffset(offset) {
                                self.overlayController.setHoveredWindow(window.id)
                            } else {
                                self.overlayController.setHoveredWindow(nil)
                            }
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self.overlayController.setBadgeProgress(progress)
                        self.overlayController.setHoveredWindow(nil)
                    }
                }

                if distance > exitThreshold && pendingGesture != .expand {
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
                    } else if offset.height > expandThreshold { // Vertical DOWN focus (Expand Zone)
                        if pendingGesture != .expand {
                            pendingGesture = .expand
                            
                            DispatchQueue.main.async {
                                self.overlayController.setExpanded(true)
                                self.overlayController.setBadgeProgress(0) // FORCE HIDE
                                self.overlayController.setIndicatorIcon("plus.circle.fill")
                            }
                        }
                    }
                } else if distance < 30 { // Closer reset for expansion specifically
                    // Only reset if NOT in interactive mode
                    if pendingGesture == .expand && !isInteractiveMode {
                        pendingGesture = nil
                        DispatchQueue.main.async {
                            self.overlayController.setExpanded(false)
                            self.overlayController.setIndicatorIcon(nil as String?)
                            self.overlayController.setHoveredWindow(nil)
                        }
                    }
                } else if distance < resetThreshold {
                    if pendingGesture != nil && pendingGesture != .expand {
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
        case next, prev, scroll, expand
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
        case .scroll, .expand:
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
    
    // MARK: - Helper Methods
    
    private func dismissOverlay() {
        self.isInteractiveMode = false
        self.triggerPoint = nil
        self.overlayController.updateMouseOffset(CGSize.zero)
        self.overlayController.setIndicatorIcon(nil as String?)
        self.overlayController.setHoveredWindow(nil as Int?)
        self.overlayController.hide()
    }

    private func adjustVolume(delta: Double) {
        // volumeStep is typically small (e.g., 5%).
        let volumeStep = delta > 0 ? 5 : -5
        let script = "set volume output volume (output volume of (get volume settings) + \(volumeStep))"
        let appleScript = NSAppleScript(source: script)
        appleScript?.executeAndReturnError(nil)
        
        fetchSystemVolume()
        
        // Update HUD feedback
        DispatchQueue.main.async {
            self.overlayController.setIndicatorIcon("speaker.wave.3.fill")
            self.clearIndicatorTimer?.invalidate()
            self.clearIndicatorTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                self.overlayController.setIndicatorIcon(nil)
            }
        }
    }

    private func fetchSystemVolume() {
        let getVolumeScript = "output volume of (get volume settings)"
        let getVolumeAppleScript = NSAppleScript(source: getVolumeScript)
        var volume: Int = 0
        if let output = getVolumeAppleScript?.executeAndReturnError(nil) {
            volume = Int(output.int32Value)
        }
        
        DispatchQueue.main.async {
            self.overlayController.viewModel.volumeLevel = Double(volume) / 100.0
        }
    }

    private func focusWindow(id: String, workspace: String? = nil) {
        let aerospacePath = "/opt/homebrew/bin/aerospace"
        
        func runCommand(_ args: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: aerospacePath)
            process.arguments = args
            
            // Standard environment setup
            var env = ProcessInfo.processInfo.environment
            env["AEROSPACE_WINDOW_ID"] = "null"
            env["AEROSPACE_WORKSPACE"] = "null"
            process.environment = env
            
            let pipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errorPipe
            
            do {
                try process.run()
                process.waitUntilExit()
                
                if process.terminationStatus != 0 {
                    let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                    let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
                    print("ERROR: AeroSpace command '\(args)' failed: \(errorOutput)")
                    return false
                }
                return true
            } catch {
                print("ERROR: Failed to run AeroSpace command '\(args)': \(error)")
                return false
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            print("DEBUG: Processing selection for window \(id)...")
            
            // User requested check: "switch to that window's workspace instead"
            // Prioritize workspace switch if available
            if let ws = workspace {
                print("DEBUG: Switching to workspace \(ws) for window \(id)")
                if runCommand(["workspace", ws]) {
                    print("DEBUG: Successfully switched to workspace \(ws)")
                    self.fetchCurrentWorkspace()
                    // Still try to focus the window *after* switching workspace, just in case
                     _ = runCommand(["focus", "--window-id", id])
                    return
                }
            }
            
            // Fallback: Try direct window focus if workspace switch failed or wasn't possible
            print("DEBUG: Attempting direct window focus for \(id)...")
            if runCommand(["focus", "--window-id", id]) {
                print("DEBUG: Successfully focused window \(id)")
            } else {
                print("DEBUG: Failed to focus window \(id) and no valid workspace switch occurred.")
            }
        }
    }
    
    private func convertPoint(_ cgPoint: CGPoint) -> CGPoint {
        if let mainScreen = NSScreen.screens.first {
            let screenHeight = mainScreen.frame.height
            return CGPoint(x: cgPoint.x, y: screenHeight - cgPoint.y)
        }
        return cgPoint
    }
    
    private func fetchWindows() {
        print("DEBUG: Fetching AeroSpace windows...")
        let executablePath = "/opt/homebrew/bin/aerospace"
        guard FileManager.default.fileExists(atPath: executablePath) else { return }
        
        DispatchQueue.global().async {
            let process = Process()
            let pipe = Pipe()
            
            var env = ProcessInfo.processInfo.environment
            env["AEROSPACE_WINDOW_ID"] = "null"
            env["AEROSPACE_WORKSPACE"] = "null"
            process.environment = env
            
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["list-windows", "--all", "--json", "--format", "%{window-id} %{app-name} %{window-title} %{workspace}"]
            process.standardOutput = pipe
            
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let windows: [WindowInfo] = try JSONDecoder().decode([WindowInfo].self, from: data)
                print("DEBUG: Fetched \(windows.count) windows")
                self.overlayController.setWindows(windows)
            } catch {
                print("ERROR: Failed to fetch windows: \(error.localizedDescription)")
            }
        }
    }
    
    deinit {
        permissionCheckTimer?.invalidate()
        stopEventTap()
    }
}
