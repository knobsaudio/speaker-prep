//
//  AudioUnitWindowController.swift
//  SpeakerPrep
//
//  Created by Ryan Brown on 8/4/26.
//

import AppKit
import AVFoundation
import CoreAudioKit

@MainActor
final class AudioUnitWindowController: NSWindowController, NSWindowDelegate {
    private var pluginViewController: NSViewController?
    private let auUnit: AUAudioUnit
    private var sizeObservation: NSKeyValueObservation?

    init(auUnit: AUAudioUnit, title: String) {
        self.auUnit = auUnit
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 200, height: 150)

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        // Menu bar (LSUIElement) apps aren't active, so their windows stay behind.
        NSApplication.shared.activate(ignoringOtherApps: true)

        if let window = window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        if pluginViewController != nil {
            window?.makeKeyAndOrderFront(nil)
            return
        }

        auUnit.requestViewController { [weak self] viewController in
            DispatchQueue.main.async {
                guard let self = self else { return }
                guard let viewController = viewController else {
                    print("Notice: Audio Unit returned nil for requestViewController.")
                    return
                }

                self.pluginViewController = viewController
                self.configureAndShowWindow(with: viewController)
            }
        }
    }

    private func configureAndShowWindow(with viewController: NSViewController) {
        guard let window = window else { return }

        window.contentViewController = viewController

        sizeObservation = viewController.observe(
            \.preferredContentSize,
            options: [.initial, .new]
        ) { [weak self, weak window] vc, _ in
            DispatchQueue.main.async {
                guard let self = self, let window = window else { return }
                self.resizeWindow(window, to: vc.preferredContentSize)
            }
        }

        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    
    private func resizeWindow(_ window: NSWindow, to newSize: NSSize) {
        guard newSize.width > 0 && newSize.height > 0 else { return }

        let currentFrame = window.frame
        let newContentRect = NSRect(origin: .zero, size: newSize)
        let newFrameRect = window.frameRect(forContentRect: newContentRect)

        let updatedFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y + (currentFrame.height - newFrameRect.height),
            width: newFrameRect.width,
            height: newFrameRect.height
        )

        window.setFrame(updatedFrame, display: true, animate: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Drop the plugin's view so the AU can tear down its UI resources.
        // present() requests a fresh one if the window is reopened.
        sizeObservation?.invalidate()
        sizeObservation = nil
        window?.contentViewController = nil
        pluginViewController = nil
    }
    
    deinit {
        sizeObservation?.invalidate()
    }
}
