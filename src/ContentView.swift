//
//  ContentView.swift
//  SpeakerPrep
//
//  Created by Ryan Brown on 8/3/26.
//

import AVFoundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var stateMachine: StateMachine
    @Binding var windowController: AudioUnitWindowController?
    @State private var deviceUID: String?
    @State private var leftChannel: Int?
    @State private var effectID: EffectID?
    // What the user has asked for, as opposed to publishedTapStatus, which is what
    // the state machine managed to do with it.
    @State private var isTapping: Bool
    @State private var isBypassed: Bool
    @State private var isVisible = false
    @State private var launchAtLogin = false

    // Seeded here rather than in onAppear so that the pickers' onChange
    // handlers don't fire (the device one clears the channel).
    init(
        stateMachine: StateMachine,
        windowController: Binding<AudioUnitWindowController?>
    ) {
        self.stateMachine = stateMachine
        _windowController = windowController
        let saved = SettingsService.loadConfig()
        _deviceUID = State(initialValue: saved.deviceUID)
        _leftChannel = State(initialValue: saved.left)
        _effectID = State(initialValue: saved.effectID)
        _isTapping = State(initialValue: saved.isTapping)
        _isBypassed = State(initialValue: saved.isBypassed)
    }

    private var isTapActive: Bool {
        switch stateMachine.publishedTapStatus {
        case .starting, .running: return true
        case .stopped, .failed: return false
        }
    }

    private var isTapStarting: Bool {
        if case .starting = stateMachine.publishedTapStatus { return true }
        return false
    }

    private var isEffectLoading: Bool {
        if case .loading = stateMachine.publishedEffectStatus { return true }
        return false
    }

    private var isEffectReady: Bool {
        if case .ready = stateMachine.publishedEffectStatus { return true }
        return false
    }

    private var isConfigComplete: Bool {
        deviceUID != nil && leftChannel != nil && effectID != nil
    }

    private func availableLefts() -> [Int] {
        // We only want left channel indices that actually have a right, so if
        // there's an odd number of channels in a stream the last channel can't
        // be selected.
        // TODO: we're assuming that a stream starts at a left channel, is that
        // ok?
        guard let device = stateMachine.publishedDevices.first(where: {
            $0.uid == deviceUID
        }) else { return [] }
        var lefts: [Int] = []
        for stream in device.outputStreams {
            let pairCount = (stream.hi - stream.lo) / 2
            for i in 0..<pairCount {
                lefts.append(stream.lo+i*2)
            }
        }
        return lefts
    }

    var body: some View {
        VStack(spacing: 20) {

            Picker("Device", selection: $deviceUID) {
                Text("Select Device").tag(nil as String?)
                ForEach(stateMachine.publishedDevices, id: \.uid) { device in
                    Text(device.name).tag(device.uid as String?)
                }
            }
            .disabled(isTapActive)
            .onChange(of: deviceUID) {
                // Clearing the channel fires its own onChange, so this can send
                // twice; the second send is a no-op in the state machine.
                leftChannel = nil
                sendConfig()
            }

            Picker("Channels", selection: $leftChannel) {
                Text("Select Channels").tag(nil as Int?)
                ForEach(availableLefts(), id: \.self) { left in
                    Text("\(left+1) & \(left+2)").tag(left as Int?)
                }
            }
            .disabled(isTapActive)
            .onChange(of: leftChannel) {
                sendConfig()
            }

            Picker("Effect", selection: $effectID) {
                Text("Select Effect").tag(nil as EffectID?)
                ForEach(stateMachine.publishedEffects, id: \.effectID) { effect in
                    Text(effect.name).tag(effect.effectID as EffectID?)
                }
            }
            .disabled(isTapActive || isEffectLoading)
            .onChange(of: effectID) {
                sendConfig()
            }

            Button("Open Plugin UI") {
                showEffectWindow()
            }
            .disabled(!isEffectReady)

            Button(isTapping ? "Stop Tap" : "Start Tap") {
                toggleTap()
            }
            .disabled(!isTapping && !(isConfigComplete && isEffectReady))

            Toggle("Bypass Effect", isOn: $isBypassed)
                .onChange(of: isBypassed) {
                    sendConfig()
                }

            //statusLine("Effect", effectStatusText(), busy: isEffectLoading)
            //statusLine("Tap", tapStatusText(), busy: isTapStarting)

            Divider()

            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) {
                    setLaunchAtLogin(launchAtLogin)
                }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(20)
        .frame(width: 320)
        .onAppear {
            isVisible = true
            launchAtLogin = SettingsService.isLaunchAtLogin()
            if isEffectReady {
                showEffectWindow()
            }
        }
        .onDisappear {
            isVisible = false
        }
        .onChange(of: stateMachine.publishedEffectStatus) {
            closeEffectWindow()
            if isEffectReady && isVisible {
                showEffectWindow()
            }
        }
    }

    private func statusLine(_ label: String, _ text: String, busy: Bool) -> some View {
        HStack(spacing: 8) {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            }
            Text("\(label): \(text)")
        }
        .frame(height: 18)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        if enabled == SettingsService.isLaunchAtLogin() { return }
        do {
            try SettingsService.setLaunchAtLogin(enabled)
        } catch {
            print("Error: unable to change launch at login: \(error)")
            launchAtLogin = SettingsService.isLaunchAtLogin()
        }
    }

    private func closeEffectWindow() {
        windowController?.close()
        windowController = nil
    }

    private func effectStatusText() -> String {
        switch stateMachine.publishedEffectStatus {
        case .none:
            return "No effect"
        case .loading(let name):
            return "Loading \(name)..."
        case .ready(let name):
            return "\(name) ready"
        case .failed(let message):
            return "Effect failed: \(message)"
        }
    }

    private func tapStatusText() -> String {
        switch stateMachine.publishedTapStatus {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting..."
        case .running:
            return stateMachine.publishedIsBypassed ? "Tapping (bypassed)" : "Tapping"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    private func toggleTap() {
        isTapping.toggle()
        sendConfig()
    }

    private func sendConfig() {
        let c = Config(
            deviceUID: deviceUID,
            left: leftChannel,
            effectID: effectID,
            isTapping: isTapping,
            isBypassed: isBypassed
        )
        SettingsService.saveConfig(c)
        stateMachine.setDesiredConfig(c)
    }

    private func showEffectWindow() {
        guard let e = stateMachine.publishedEffect,
              let auUnit = e.avAudioUnit?.auAudioUnit else { return }

        if windowController == nil {
            windowController = AudioUnitWindowController(
                auUnit: auUnit,
                title: e.name
            )
        }
        windowController?.present()
    }
}

#Preview {
    ContentView(stateMachine: StateMachine(), windowController: .constant(nil))
}
