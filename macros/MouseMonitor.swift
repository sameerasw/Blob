import Foundation
import CoreGraphics
import AppKit
import SwiftUI
import Combine

class MouseMonitor: ObservableObject {
    @Published var isTrusted: Bool = false
    
    // Scroll Customization
    @Published var reverseScroll: Bool = false
    @Published var scrollSensitivity: Double = 1.0 // 1.0 (fast) to 5.0 (slow)
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let overlayController = OverlayWindowController()
    private var permissionCheckTimer: Timer?
    
    // Mouse button 5 is index 4 in CGEvent data
    private let targetButtonNumber: Int64 = 4
    private var isButton5Down: Bool = false
    private var currentMacroNumber: Int = 1
    private var initialMacroNumber: Int?
    
    // Smooth scrolling accumulator
    private var scrollAccumulator: Double = 0.0
    
    init() {
        checkPermissions()
        startPermissionCheckTimer()
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
                
                if reverseScroll {
                    delta = -delta
                }
                
                scrollAccumulator += (delta / scrollSensitivity)
                
                if abs(scrollAccumulator) >= 1.0 {
                    let steps = Int(floor(abs(scrollAccumulator)))
                    let direction = scrollAccumulator > 0 ? 1 : -1
                    currentMacroNumber = max(1, min(7, currentMacroNumber + (steps * direction)))
                    scrollAccumulator -= Double(steps * direction)
                    
                    DispatchQueue.main.async {
                        self.overlayController.setMacroNumber(self.currentMacroNumber)
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
                    
                    initialMacroNumber = currentMacroNumber
                    scrollAccumulator = 0
                    
                    print("DEBUG: Showing overlay at \(location). Current Number: \(currentMacroNumber)")
                    DispatchQueue.main.async {
                        self.overlayController.setMacroNumber(self.currentMacroNumber)
                        self.overlayController.show(at: self.convertPoint(location))
                    }
                } else {
                    isButton5Down = false
                    print("DEBUG: Hiding overlay")
                    DispatchQueue.main.async {
                        self.overlayController.hide()
                    }
                    
                    // Trigger AeroSpace if number changed
                    if let initial = initialMacroNumber, currentMacroNumber != initial {
                        print("DEBUG: Number changed from \(initial) to \(currentMacroNumber). Running AeroSpace command.")
                        runAeroSpaceCommand(for: currentMacroNumber)
                    }
                    initialMacroNumber = nil
                }
            }
        } else if type == .otherMouseDragged || type == .mouseMoved {
            let location = event.location
            DispatchQueue.main.async {
                self.overlayController.updatePosition(to: self.convertPoint(location))
            }
        }
        
        return Unmanaged.passRetained(event)
    }
    
    private func fetchCurrentWorkspace() {
        let executablePath = "/opt/homebrew/bin/aerospace"
        guard FileManager.default.fileExists(atPath: executablePath) else { return }
        
        let process = Process()
        let pipe = Pipe()
        
        // Silence the "incomplete JSON request" warning by providing empty env vars
        var env = ProcessInfo.processInfo.environment
        env["AEROSPACE_WINDOW_ID"] = "null"
        env["AEROSPACE_WORKSPACE"] = "null"
        process.environment = env
        
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["list-workspaces", "--focused"]
        process.standardOutput = pipe
        // Ignore stderr for the sync check to keep logs clean
        process.standardError = Pipe() 
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let workspaceNumber = Int(output) {
                print("DEBUG: Fetched current AeroSpace workspace: \(workspaceNumber)")
                self.currentMacroNumber = workspaceNumber
            }
        } catch {
            print("ERROR: Failed to fetch workspace: \(error.localizedDescription)")
        }
    }
    
    private func runAeroSpaceCommand(for number: Int) {
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
        process.arguments = ["workspace", String(number)]
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
