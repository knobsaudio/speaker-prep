//
//  StateMachine.swift
//  SpeakerPrep
//
//  Created by Ryan Brown on 8/5/26.
//

import Foundation
import AVFoundation

struct EffectID: Equatable, Hashable {
    var componentType: UInt32
    var componentSubType: UInt32
    var componentManufacturer: UInt32
}

struct Config {
    var deviceUID: String?
    var left: Int? // 0-based, relative to entire device
    var effectID: EffectID?
    var isTapping: Bool
    var isBypassed: Bool
}

struct Stream: Equatable {
    var index: Int
    var lo: Int  // 0-based, relative to entire device
    var hi: Int
    var sampleRate: Double

    func contains(channel: Int) -> Bool {
        lo <= channel && channel < hi
    }
}

struct Device {
    var uid: String
    var name: String
    var outputStreams: [Stream]
}

struct Effect {
    var effectID: EffectID
    var name: String
    var manufacturer: String
    
    // The actual unit will not be present when polling current effects, but it
    // is a nice spot to hold the actual unit instatiated by the state machine.
    var avAudioUnit: AVAudioUnit?
}

struct TapLayout: Equatable {
    var deviceUID: String
    var outputStream: Stream
    var left: Int  // 0-based, relative to stream
    var effectID: EffectID
}

struct Tap {
    var layout: TapLayout
    var deviceID: AudioObjectID = kAudioObjectUnknown
    var tapID: AudioObjectID = kAudioObjectUnknown
    var aggregateID: AudioObjectID = kAudioObjectUnknown
    var outputUnit: AudioUnit? = nil
    var effectUnit: AUAudioUnit? = nil
    var leftBufferIndex: Int = -1
    var rightBufferIndex: Int = -1
    var maxFrames: Int = -1
    
    // The output unit's input for the current render cycle, borrowed so
    // that effectInputCallback can copy the stereo pair out of it.
    var pulledInput: UnsafeMutablePointer<AudioBufferList>?
    
    // If the effect's input buffers (ioData) are missing (e.g. for in-place
    // computation), we use ours. Either way the input data is the
    // target stereo pair copied from pulledInput. The output
    // buffers are always used.
    var effectInLeftBuf: UnsafeMutablePointer<Float32>? = nil
    var effectInRightBuf: UnsafeMutablePointer<Float32>? = nil
    var effectOutLeftBuf: UnsafeMutablePointer<Float32>? = nil
    var effectOutRightBuf: UnsafeMutablePointer<Float32>? = nil
    var effectOutBufList: UnsafeMutablePointer<AudioBufferList>? = nil
    
    var effectRenderBlock: AURenderBlock?
    
    // Built once at setup so that the render thread never has to heap-copy
    // a capturing closure. It captures the raw Tap pointer, not a reference,
    // so there is no cycle with the Tap that owns it.
    var pullInputBlock: AURenderPullInputBlock?
    
    // Atomic flag (0 = active, 1 = bypassed) shared with the render thread;
    // wetGain is owned exclusively by outputCallback for the 15ms crossfade.
    var isBypassed: Int32 = 0
    var wetGain: Float32 = 1.0
    var rampStep: Float32 = 0.0
}

enum LayoutResult {
    case ready(TapLayout)
    case incomplete           // user hasn't picked everything yet; not an error
    case unavailable(String)  // config is complete but can't be satisfied right now
}

func makeTapLayout(_ c: Config, _ devices: [Device]) -> LayoutResult
{
    guard let deviceUID = c.deviceUID,
          let left = c.left,
          let effectID = c.effectID
    else {
        return .incomplete
    }
    
    guard let device = devices.first(where: { $0.uid == deviceUID })
    else {
        print("Error: desired device not found \(deviceUID)")
        return .unavailable("The selected device is not available.")
    }
    
    let right = left+1

    guard
        let outputStream = device.outputStreams.first(where: {
            $0.contains(channel: left) && $0.contains(channel: right)
        })
    else {
        print("Error: no stream contains the desired stereo pair.")
        return .unavailable("The selected channels are not available on this device.")
    }

    let streamRelativeLeft = left - outputStream.lo

    return .ready(TapLayout(
        deviceUID: device.uid,
        outputStream: outputStream,
        left: streamRelativeLeft,
        effectID: effectID
    ))
}

enum EffectState {
    case none
    case ready(Effect)
    case failed(EffectID, String)

    func effectID() -> EffectID? {
        switch self {
        case .none: return nil
        case .ready(let e): return e.effectID
        case .failed(let id, _): return id
        }
    }
}

// Loading is published, never stored: the load is synchronous on the queue.
enum EffectStatus: Equatable {
    case none
    case loading(String)
    case ready(String)
    case failed(String)
}

enum TapState {
    case idle
    case failed(String)
    case running(UnsafeMutablePointer<Tap>)
}

// Starting is published, never stored, for the same reason as loading.
enum TapStatus {
    case stopped
    case starting
    case running
    case failed(String)
}

final class StateMachine: ObservableObject {
    @Published private(set) var publishedTapStatus: TapStatus = .stopped
    @Published private(set) var publishedIsBypassed: Bool = false
    @Published private(set) var publishedEffectStatus: EffectStatus = .none
    @Published private(set) var publishedEffect: Effect?
    @Published private(set) var publishedDevices: [Device] = []
    @Published private(set) var publishedEffects: [Effect] = []

    private let queue = DispatchQueue(label: "speakerprep.statemachine.queue")
    private var desiredConfig = Config(
        deviceUID: nil,
        left: nil,
        effectID: nil,
        isTapping: false,
        isBypassed: false
    )
    private var effectState: EffectState = .none
    private var tapState: TapState = .idle
    private var deviceListListener: HardwareListener?
    private var watchedDevice: (uid: String, listener: HardwareListener)?
    private var processListListener: HardwareListener?
    private var watchedProcesses: [AudioObjectID: HardwareListener] = [:]
    private var tappedProcesses: [AudioObjectID] = []

    init() {
        deviceListListener = HardwareService.listenForDeviceList(queue) {
            [weak self] in self?.reevaluate()
        }
        
        queue.async {
            self.evaluate()
        }
    }
    
    deinit {
        if let l = deviceListListener {
            HardwareService.stopListening(l, queue)
        }
        if let w = watchedDevice {
            HardwareService.stopListening(w.listener, queue)
        }
        if let l = processListListener {
            HardwareService.stopListening(l, queue)
        }
        for listener in watchedProcesses.values {
            HardwareService.stopListening(listener, queue)
        }
        if case .running(let p) = tapState {
            HardwareService.stopTap(p)
        }
    }

    // onSettled runs after attempt completes (no guarantee that the
    // state matches the desire).
    func setDesiredConfig(_ c: Config, onSettled: (() -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(DispatchQueue.main))
        
        queue.async {
            self.desiredConfig = c
            self.evaluate()
            onSettled?()
        }
    }
    
    func reevaluate() {
        dispatchPrecondition(condition: .onQueue(queue))
        self.evaluate()
    }
    
    private func evaluate() {
        dispatchPrecondition(condition: .onQueue(queue))
        
        defer { publish() }
        
        let effects: [Effect] = HardwareService.currentEffects()
        DispatchQueue.main.async {
            self.publishedEffects = effects
        }
        
        let effectMissing = !isCurrentEffectAvailable(in: effects)
        if effectState.effectID() != desiredConfig.effectID || effectMissing {
            stopEffect()
            if desiredConfig.effectID != nil {
                startEffect(effects)
            }
        }
        
        watchDevice(desiredConfig.deviceUID)
        
        guard let devices: [Device] = HardwareService.currentHardwareDevices()
        else {
            print("Error: current list of hardware devices is not available.")
            DispatchQueue.main.async {
                self.publishedDevices = []
            }
            fail("The audio devices are not available.")
            return
        }
        DispatchQueue.main.async {
            self.publishedDevices = devices
        }
        
        guard desiredConfig.isTapping else {
            stopTap()
            return
        }
        
        switch makeTapLayout(desiredConfig, devices) {
        case .incomplete:
            fail("The tap is not fully configured.")
        case .unavailable(let message):
            fail(message)
        case .ready(let desiredLayout):
            if case .running(let p) = tapState, p.pointee.layout == desiredLayout {
                HardwareService.setTapBypassed(p, desiredConfig.isBypassed)
                reconcileProcesses(for: p.pointee)
                return
            }
            startTap(desiredLayout)
        }
    }
    
    private func isCurrentEffectAvailable(in effects: [Effect]) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        
        if case .ready(let e) = effectState {
            return effects.contains(where: { $0.effectID == e.effectID })
        }
        return true
    }
    
    private func watchDevice(_ uid: String?) {
        dispatchPrecondition(condition: .onQueue(queue))
        
        if watchedDevice?.uid == uid { return }
        
        if let w = watchedDevice {
            HardwareService.stopListening(w.listener, queue)
            watchedDevice = nil
        }
        
        guard let uid = uid else { return }
        
        guard let listener = HardwareService.listenToDevice(uid, queue, {
            [weak self] in self?.reevaluate()
        }) else {
            print("Error: unable to watch device \(uid).")
            return
        }
        
        watchedDevice = (uid: uid, listener: listener)
    }
    
    private func reconcileProcesses(for tap: Tap) {
        dispatchPrecondition(condition: .onQueue(queue))
        
        if processListListener == nil {
            processListListener = HardwareService.listenForProcessList(queue) {
                [weak self] in self?.reevaluate()
            }
        }
        
        let current = Set(HardwareService.currentProcessIDs())
        for (procID, listener) in watchedProcesses where !current.contains(procID) {
            HardwareService.stopListening(listener, queue)
            watchedProcesses.removeValue(forKey: procID)
        }
        for procID in current where watchedProcesses[procID] == nil {
            watchedProcesses[procID] = HardwareService.listenToProcess(procID, queue) {
                [weak self] in self?.reevaluate()
            }
        }
        
        let target = HardwareService.outputProcessIDs(forDevice: tap.deviceID)
        if target != tappedProcesses {
            if HardwareService.updateTapProcesses(tap.tapID, target) {
                tappedProcesses = target
            }
        }
    }
    
    private func stopWatchingProcesses() {
        dispatchPrecondition(condition: .onQueue(queue))
        
        if let l = processListListener {
            HardwareService.stopListening(l, queue)
            processListListener = nil
        }
        for listener in watchedProcesses.values {
            HardwareService.stopListening(listener, queue)
        }
        watchedProcesses.removeAll()
        tappedProcesses = []
    }
    
    // Records a failure, but only when the user actually wants a tap: the same
    // paths run while stopping, and stopping successfully is not a failure.
    private func fail(_ message: String) {
        dispatchPrecondition(condition: .onQueue(queue))
        
        stopTap()
        
        if desiredConfig.isTapping {
            tapState = .failed(message)
        }
    }
    
    private func publish() {
        dispatchPrecondition(condition: .onQueue(queue))
        
        let effectStatus: EffectStatus
        let effect: Effect?
        switch effectState {
        case .none:
            effectStatus = .none
            effect = nil
        case .ready(let e):
            effectStatus = .ready(e.name)
            effect = e
        case .failed(_, let message):
            effectStatus = .failed(message)
            effect = nil
        }
        
        let tapStatus: TapStatus
        switch tapState {
        case .idle:
            tapStatus = .stopped
        case .running:
            tapStatus = .running
        case .failed(let message):
            tapStatus = .failed(message)
        }
        
        let isBypassed = desiredConfig.isBypassed
        DispatchQueue.main.async {
            self.publishedEffect = effect
            self.publishedEffectStatus = effectStatus
            self.publishedTapStatus = tapStatus
            self.publishedIsBypassed = isBypassed
        }
    }
    
    private func startEffect(_ effects: [Effect]) {
        dispatchPrecondition(condition: .onQueue(queue))
        
        guard let desiredEffectID = desiredConfig.effectID else {
            print("Error: Can't start effect until user has chosen one.")
            return
        }
        guard let desiredEffect = effects.first(where: { $0.effectID == desiredEffectID })
        else {
            print("Error: Can't find the desired effect.")
            effectState = .failed(desiredEffectID, "The selected effect is not available.")
            return
        }
        
        DispatchQueue.main.async {
            self.publishedEffectStatus = .loading(desiredEffect.name)
        }
        
        guard let avAudioUnit = HardwareService.instantiateEffect(desiredEffectID) else {
            print("Error: Can't create the effect.")
            effectState = .failed(desiredEffectID, "Failed to load \(desiredEffect.name).")
            return
        }
        
        if let state = SettingsService.loadEffectState(desiredEffectID) {
            avAudioUnit.auAudioUnit.fullState = state
        }
        
        print("Effect started \(desiredEffect.name).")
        
        effectState = .ready(Effect(
            effectID: desiredEffectID,
            name: desiredEffect.name,
            manufacturer: desiredEffect.manufacturer,
            avAudioUnit: avAudioUnit
        ))
    }
    
    private func stopEffect() {
        dispatchPrecondition(condition: .onQueue(queue))
        
        if case .none = effectState { return }
        
        stopTap()
        
        if case .ready(let e) = effectState,
           let avUnit = e.avAudioUnit,
           let state = avUnit.auAudioUnit.fullState {
            SettingsService.saveEffectState(e.effectID, state)
        }
        
        effectState = .none
        
        print("Effect stopped.")
    }
    
    private func startTap(_ desiredLayout: TapLayout) {
        dispatchPrecondition(condition: .onQueue(queue))
        
        stopTap()
        
        guard case .ready(let e) = effectState, let avUnit = e.avAudioUnit else {
            print("Error: can't start tap until effect is ready.")
            fail("The effect is not ready.")
            return
        }
        let auUnit = avUnit.auAudioUnit
        
        DispatchQueue.main.async {
            self.publishedTapStatus = .starting
        }
        
        guard let started = HardwareService.startTap(
            desiredLayout, auUnit, isBypassed: desiredConfig.isBypassed)
        else {
            print("Error: unable to create tap.")
            fail("Unable to capture audio from the device.")
            return
        }
        
        tapState = .running(started.tap)
        tappedProcesses = started.processes
        reconcileProcesses(for: started.tap.pointee)
        
        print("Tap started.")
    }
    
    // Leaves the machine idle whether or not a tap was running, so that a
    // stale failure doesn't outlive the request that caused it.
    private func stopTap() {
        dispatchPrecondition(condition: .onQueue(queue))
        
        stopWatchingProcesses()
        
        if case .running(let p) = tapState {
            HardwareService.stopTap(p)
            print("Tap stopped.")
        }
        
        tapState = .idle
    }
}
