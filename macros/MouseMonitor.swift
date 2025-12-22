import Foundation
import CoreGraphics
import AppKit
import SwiftUI
import Combine

class MouseMonitor: ObservableObject {
    @Published var isTrusted: Bool = false
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let overlayController = OverlayWindowController()
    private var permissionCheckTimer: Timer?
    
    // Mouse button 5 is index 4 in CGEvent data
    private let targetButtonNumber: Int64 = 4
    private var isButton5Down: Bool = false
    private var currentMacroNumber: Int = 1
    
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
                // Adjust macro number (1-7) and CONSUME the event
                let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                if delta > 0 {
                    // Scroll up
                    currentMacroNumber = min(7, currentMacroNumber + 1)
                } else if delta < 0 {
                    // Scroll down
                    currentMacroNumber = max(1, currentMacroNumber - 1)
                }
                
                print("DEBUG: Macro Number Changed to: \(currentMacroNumber)")
                DispatchQueue.main.async {
                    self.overlayController.setMacroNumber(self.currentMacroNumber)
                }
                
                // Return nil to consume the event (prevent background scrolling)
                return nil
            }
        }
        
        // Handle Mouse Buttons
        if type == .otherMouseDown || type == .otherMouseUp {
            let buttonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
            
            if buttonNumber == targetButtonNumber {
                let location = event.location
                if type == .otherMouseDown {
                    isButton5Down = true
                    print("DEBUG: Showing overlay at \(location)")
                    DispatchQueue.main.async {
                        self.overlayController.show(at: self.convertPoint(location))
                    }
                } else {
                    isButton5Down = false
                    print("DEBUG: Hiding overlay")
                    DispatchQueue.main.async {
                        self.overlayController.hide()
                    }
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
