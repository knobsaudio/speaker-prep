//
//  SpeakerPrepApp.swift
//  SpeakerPrep
//
//  Created by Ryan Brown on 8/3/26.
//

import SwiftUI

@main
struct SpeakerPrepApp: App {
    @StateObject private var stateMachine: StateMachine
    @State private var windowController: AudioUnitWindowController?

    init() {
        let sm = StateMachine()
        _stateMachine = StateObject(wrappedValue: sm)
        sm.setDesiredConfig(SettingsService.loadConfig())

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            shutdown(sm)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView(
                stateMachine: stateMachine,
                windowController: $windowController
            )
        } label: {
            Image(systemName: menuBarIcon())
        }
        .menuBarExtraStyle(.window)
    }

    private func menuBarIcon() -> String {
        switch stateMachine.publishedTapStatus {
        case .running:
            return stateMachine.publishedIsBypassed ? "smallcircle.filled.circle" : "circle.inset.filled"
        case .stopped, .starting, .failed:
            return "circle"
        }
    }
}

private func shutdown(_ stateMachine: StateMachine) {
    let settled = DispatchSemaphore(value: 0)
    stateMachine.setDesiredConfig(
        Config(
            deviceUID: nil,
            left: nil,
            effectID: nil,
            isTapping: false,
            isBypassed: false
        )
    ) {
        settled.signal()
    }
    if settled.wait(timeout: .now() + 2) == .timedOut {
        print("Error: timed out waiting for the state machine to settle.")
    }
}
