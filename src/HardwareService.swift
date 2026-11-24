//
//  HardwareService.swift
//  SpeakerPrep
//
//  Created by Ryan Brown on 8/3/26.
//

import Foundation
import CoreAudio
import AVFoundation
import AudioToolbox

// Property listeners on one audio object, removed together.
struct HardwareListener {
    let objectID: AudioObjectID
    let scope: AudioObjectPropertyScope
    let selectors: [AudioObjectPropertySelector]
    let block: AudioObjectPropertyListenerBlock
}

private func effectInputCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    // This callback is called using a pull model. Its job, since it is
    // attached to the input scope of the output bus is to prepare the
    // input for DSP (by pulling any required dependent inputs). Since
    // outputCallback already pulled the device input there is nothing
    // to render, just copy.
    let tapPtr = inRefCon.assumingMemoryBound(to: Tap.self)
    let size = Int(inNumberFrames) * MemoryLayout<Float32>.size

    guard inBusNumber == 0 else { return kAudioUnitErr_InvalidElement }
    guard let ioData = ioData else { return kAudioUnitErr_InvalidParameter }

    let ioDataBufs = UnsafeMutableAudioBufferListPointer(ioData)
    guard ioDataBufs.count >= 2 else { return kAudioUnitErr_InvalidParameter }

    // Our buffers are only maxFrames long, so we have nothing big enough to
    // hand back. Fail instead: the effect must not consume ioData.
    guard inNumberFrames <= tapPtr.pointee.maxFrames else {
        return kAudioUnitErr_TooManyFramesToProcess
    }

    // No memory to offer means the tap is torn down, so don't claim success
    // with buffers we haven't filled in.
    guard let effectInLeftBuf = tapPtr.pointee.effectInLeftBuf,
        let effectInRightBuf = tapPtr.pointee.effectInRightBuf
    else {
        return kAudioUnitErr_Uninitialized
    }

    // Every return below is noErr, so the effect will read ioData. If it
    // didn't provide memory (e.g. for in-place computation) it expects us to,
    // and either way the buffers have to be initialized before we return.
    if ioDataBufs[0].mData == nil {
        ioDataBufs[0].mData = UnsafeMutableRawPointer(effectInLeftBuf)
        ioDataBufs[0].mDataByteSize = UInt32(size)
        ioDataBufs[0].mNumberChannels = 1
    }
    if ioDataBufs[1].mData == nil {
        ioDataBufs[1].mData = UnsafeMutableRawPointer(effectInRightBuf)
        ioDataBufs[1].mDataByteSize = UInt32(size)
        ioDataBufs[1].mNumberChannels = 1
    }

    guard let pulledInput = tapPtr.pointee.pulledInput else {
        zeroChannel(ioDataBufs, 0, size)
        zeroChannel(ioDataBufs, 1, size)
        ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
        return noErr
    }

    let inputBufs = UnsafeMutableAudioBufferListPointer(pulledInput)
    let left = tapPtr.pointee.leftBufferIndex
    let right = tapPtr.pointee.rightBufferIndex

    if left < inputBufs.count {
        copyChannel(inputBufs, left, ioDataBufs, 0, size)
    } else {
        zeroChannel(ioDataBufs, 0, size)
    }

    if right < inputBufs.count {
        copyChannel(inputBufs, right, ioDataBufs, 1, size)
    } else {
        zeroChannel(ioDataBufs, 1, size)
    }

    return noErr
}

private func outputCallback(
    _ inRefCon: UnsafeMutableRawPointer,
    _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
    _ inBusNumber: UInt32,
    _ inNumberFrames: UInt32,
    _ ioData: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    // This callback is called using a pull model. Its job, since it is
    // attached to the input scope of the output bus, is to prepare the
    // input for the driver output (since this is an output node). The DAC
    // needs N frames for M channels (ioData has M empty buffers). We've
    // set up our channel map so that when we render the input of the
    // output node it will read from the tap channels in the aggregate
    // device (not the hardware inputs).
    let size = Int(inNumberFrames) * MemoryLayout<Float32>.size
    let tapPtr = inRefCon.assumingMemoryBound(to: Tap.self)

    guard let ioData = ioData else {
        // Nothing to silence.
        return noErr
    }

    // Our allocations may be too small.
    guard inNumberFrames <= tapPtr.pointee.maxFrames else {
        zeroList(ioData, size)
        ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
        return noErr
    }

    guard let outputUnit = tapPtr.pointee.outputUnit,
        let effectOutBufList = tapPtr.pointee.effectOutBufList,
        let effectOutLeftBuf = tapPtr.pointee.effectOutLeftBuf,
        let effectOutRightBuf = tapPtr.pointee.effectOutRightBuf,
        let effectRenderBlock = tapPtr.pointee.effectRenderBlock,
        let pullInputBlock = tapPtr.pointee.pullInputBlock
    else {
        zeroList(ioData, size)
        ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
        return kAudioUnitErr_Uninitialized
    }

    // Pull input directly into the output (tap size and output size
    // should be the same).
    var pullFlags: AudioUnitRenderActionFlags = []
    let inputStatus =
        AudioUnitRender(
            outputUnit,
            &pullFlags,
            inTimeStamp,
            1,
            inNumberFrames,
            ioData)
    guard inputStatus == noErr
    else {
        zeroList(ioData, size)
        ioActionFlags.pointee.insert(.unitRenderAction_OutputIsSilence)
        return noErr
    }

    if pullFlags.contains(.unitRenderAction_OutputIsSilence) {
        zeroList(ioData, size)
    }

    let effectOutBufs = UnsafeMutableAudioBufferListPointer(effectOutBufList)
    if effectOutBufs.count > 0 {
        effectOutBufs[0].mData = UnsafeMutableRawPointer(effectOutLeftBuf)
        effectOutBufs[0].mDataByteSize = UInt32(size)
        effectOutBufs[0].mNumberChannels = 1
    }
    if effectOutBufs.count > 1 {
        effectOutBufs[1].mData = UnsafeMutableRawPointer(effectOutRightBuf)
        effectOutBufs[1].mDataByteSize = UInt32(size)
        effectOutBufs[1].mNumberChannels = 1
    }

    // Just in case the effect doesn't write anything.
    memset(effectOutLeftBuf, 0, size)
    memset(effectOutRightBuf, 0, size)

    tapPtr.pointee.pulledInput = ioData

    var effectFlags: AudioUnitRenderActionFlags = []

    let effectStatus = effectRenderBlock(
        &effectFlags,
        inTimeStamp,
        inNumberFrames,
        0,
        effectOutBufList,
        pullInputBlock
    )

    tapPtr.pointee.pulledInput = nil

    guard effectStatus == noErr else {
        // Leave audio pass-through intact.
        return noErr
    }

    // Keep the effect warm while bypassed so un-bypassing has no stale filter
    // state or sample-time jump; simply discard its output once fully dry.
    let bypassed = atomicLoadInt32(&tapPtr.pointee.isBypassed) != 0
    let wetGain = tapPtr.pointee.wetGain
    if bypassed && wetGain <= 0.0 {
        tapPtr.pointee.wetGain = 0.0
        return noErr
    }

    let ioDataBufs = UnsafeMutableAudioBufferListPointer(ioData)
    let left = tapPtr.pointee.leftBufferIndex
    let right = tapPtr.pointee.rightBufferIndex
    let wetSilent = effectFlags.contains(.unitRenderAction_OutputIsSilence)
    let targetWet: Float32 = bypassed ? 0.0 : 1.0

    if !bypassed && wetGain >= 1.0 {
        if left < ioDataBufs.count {
            if wetSilent {
                zeroChannel(ioDataBufs, left, size)
            } else {
                copyChannel(effectOutBufs, 0, ioDataBufs, left, size)
            }
        }
        if right < ioDataBufs.count {
            if wetSilent {
                zeroChannel(ioDataBufs, right, size)
            } else {
                copyChannel(effectOutBufs, 1, ioDataBufs, right, size)
            }
        }
    } else {
        let step = tapPtr.pointee.rampStep
        let frames = Int(inNumberFrames)
        if left < ioDataBufs.count {
            mixChannel(
                effectOutBufs, 0, wetSilent, ioDataBufs, left,
                frames, wetGain, targetWet, step)
        }
        if right < ioDataBufs.count {
            mixChannel(
                effectOutBufs, 1, wetSilent, ioDataBufs, right,
                frames, wetGain, targetWet, step)
        }
        let delta: Float32 = targetWet > wetGain ? step : -step
        let nextGain = wetGain + delta * Float32(frames)
        tapPtr.pointee.wetGain =
            delta > 0 ? min(targetWet, nextGain) : max(targetWet, nextGain)
    }

    return noErr
}

private func mixChannel(
    _ wetBufs: UnsafeMutableAudioBufferListPointer,
    _ wetIndex: Int,
    _ wetSilent: Bool,
    _ dstBufs: UnsafeMutableAudioBufferListPointer,
    _ dstIndex: Int,
    _ frames: Int,
    _ startGain: Float32,
    _ targetGain: Float32,
    _ step: Float32
) {
    let size = frames * MemoryLayout<Float32>.size
    guard 0 <= dstIndex, dstIndex < dstBufs.count,
        let dstRaw = dstBufs[dstIndex].mData
    else {
        return
    }
    let writeBytes = channelByteSize(dstBufs[dstIndex], size)
    let writeFrames = writeBytes / MemoryLayout<Float32>.size
    let dst = dstRaw.assumingMemoryBound(to: Float32.self)

    let wet: UnsafeMutablePointer<Float32>?
    let wetFrames: Int
    if !wetSilent, 0 <= wetIndex, wetIndex < wetBufs.count,
        let wetRaw = wetBufs[wetIndex].mData
    {
        wet = wetRaw.assumingMemoryBound(to: Float32.self)
        wetFrames = channelByteSize(wetBufs[wetIndex], size) / MemoryLayout<Float32>.size
    } else {
        wet = nil
        wetFrames = 0
    }

    var g = startGain
    let delta: Float32 = targetGain > startGain ? step : -step
    for i in 0..<writeFrames {
        g += delta
        if delta > 0 ? g > targetGain : g < targetGain {
            g = targetGain
        }
        let wetSample: Float32 = (i < wetFrames) ? wet![i] : 0.0
        let angle = g * (.pi * 0.5)
        dst[i] = dst[i] * cosf(angle) + wetSample * sinf(angle)
    }
    dstBufs[dstIndex].mDataByteSize = UInt32(writeBytes)
}

private func copyChannel(
    _ srcBufs: UnsafeMutableAudioBufferListPointer,
    _ srcIndex: Int,
    _ dstBufs: UnsafeMutableAudioBufferListPointer,
    _ dstIndex: Int,
    _ size: Int
) {
    guard 0 <= dstIndex, dstIndex < dstBufs.count,
        let dst = dstBufs[dstIndex].mData
    else {
        return
    }
    guard 0 <= srcIndex, srcIndex < srcBufs.count,
        let src = srcBufs[srcIndex].mData
    else {
        zeroChannel(dstBufs, dstIndex, size)
        return
    }
    let writeSize = channelByteSize(dstBufs[dstIndex], size)
    let copySize = min(writeSize, channelByteSize(srcBufs[srcIndex], size))
    memcpy(dst, src, copySize)
    if copySize < writeSize {
        memset(dst.advanced(by: copySize), 0, writeSize - copySize)
    }
    dstBufs[dstIndex].mDataByteSize = UInt32(writeSize)
}

// mDataByteSize is the buffer's capacity on the way in and the valid byte
// count on the way out. A conforming caller sets it every cycle, but zero
// means "unspecified" rather than "empty", and taking it literally would
// truncate the cycle to silence and then latch that zero into the list.
private func channelByteSize(_ buf: AudioBuffer, _ size: Int) -> Int {
    let declared = Int(buf.mDataByteSize)
    return declared > 0 ? min(size, declared) : size
}

private func zeroChannel(
    _ bufs: UnsafeMutableAudioBufferListPointer,
    _ index: Int,
    _ size: Int
) {
    guard 0 <= index, index < bufs.count, let buf = bufs[index].mData else {
        return
    }
    let writeSize = channelByteSize(bufs[index], size)
    memset(buf, 0, writeSize)
    bufs[index].mDataByteSize = UInt32(writeSize)
}

private func zeroList(
    _ bufList: UnsafeMutablePointer<AudioBufferList>,
    _ size: Int
) {
    let bufs = UnsafeMutableAudioBufferListPointer(bufList)
    for i in 0..<bufs.count {
        zeroChannel(bufs, i, size)
    }
}

struct HardwareService {

    static func currentHardwareDevices() -> [Device]? {
        guard
            let deviceIDs: [AudioObjectID] = readPropertyArray(
                AudioObjectID(kAudioObjectSystemObject),
                kAudioHardwarePropertyDevices)
        else {
            print("Error: Unable to read devices.")
            return nil
        }

        var devices: [Device] = []

        for deviceID in deviceIDs {
            guard let device: Device = makeDevice(deviceID) else {
                print("Error: Unable to make device \(deviceID).")
                continue
            }
            if device.outputStreams.isEmpty {
                continue
            }
            devices.append(device)
        }

        return devices
    }

    private static func makeDevice(_ deviceID: AudioDeviceID) -> Device? {
        guard
            let deviceUID: CFString = readProperty(
                deviceID, kAudioDevicePropertyDeviceUID)
        else {
            print("Error: Unable to read device UID.")
            return nil
        }

        guard
            let deviceName: CFString = readProperty(
                deviceID, kAudioObjectPropertyName)
        else {
            print("Error: Unable to read device name.")
            return nil
        }

        guard
            let outputStreamIDs: [AudioStreamID] = readPropertyArray(
                deviceID, kAudioDevicePropertyStreams,
                kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain
            )
        else {
            print("Error: Unable to read output streams.")
            return nil
        }

        var outputStreams: [Stream] = []

        for (i, outputStreamID) in outputStreamIDs.enumerated() {
            guard var outputStream: Stream = makeStream(outputStreamID) else {
                print("Error: Unable to make stream.")
                return nil
            }
            outputStream.index = i
            outputStreams.append(outputStream)
        }

        return Device(
            uid: deviceUID as String,
            name: deviceName as String,
            outputStreams: outputStreams
        )
    }

    private static func makeStream(_ streamID: AudioStreamID) -> Stream? {
        guard
            let firstChannel: UInt32 = readProperty(
                streamID,
                kAudioStreamPropertyStartingChannel),
            firstChannel != 0  // should be 1-based
        else {
            print("Error: Unable to read firstChannel.")
            return nil
        }
        guard
            let asbd: AudioStreamBasicDescription = readProperty(
                streamID,
                kAudioStreamPropertyVirtualFormat)
        else {
            print("Error: Unable to read ASBD.")
            return nil
        }
        let lo = Int(firstChannel - 1)
        let hi = lo + Int(asbd.mChannelsPerFrame)
        return Stream(
            index: -1,
            lo: lo,
            hi: hi,
            sampleRate: asbd.mSampleRate
        )
    }

    static func currentEffects() -> [Effect] {
        var effects: [EffectID: Effect] = [:]

        let targetTypes: [UInt32] = [
            kAudioUnitType_Effect
            // Note: Some effects register as kAudioUnitType_MusicEffect if
            // they support MIDI input, so if we were to support those we'd
            // need to perhaps dedup across both types (if it is registered
            // twice) and support MIDI input.
        ]

        for typeCode in targetTypes {
            let query = AudioComponentDescription(
                componentType: typeCode,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )

            let components: [AVAudioUnitComponent] =
                AVAudioUnitComponentManager.shared().components(matching: query)

            for component in components {
                guard component.supportsNumberInputChannels(2, outputChannels: 2) else {
                    continue
                }
                let effect = makeEffect(component)
                if effects[effect.effectID] == nil {
                    effects[effect.effectID] = effect
                }
            }
        }

        return effects.values.sorted { lhs, rhs in
            let mComp = lhs.manufacturer.localizedCaseInsensitiveCompare(
                rhs.manufacturer)
            if mComp == .orderedSame {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name)
                    == .orderedAscending
            }
            return mComp == .orderedAscending
        }
    }

    private static func makeEffect(_ component: AVAudioUnitComponent) -> Effect
    {
        let desc = component.audioComponentDescription
        return Effect(
            effectID: EffectID(
                componentType: desc.componentType,
                componentSubType: desc.componentSubType,
                componentManufacturer: desc.componentManufacturer
            ),
            name: component.name,
            manufacturer: component.manufacturerName
        )
    }

    static func startTap(
        _ layout: TapLayout,
        _ effectUnit: AUAudioUnit,
        isBypassed: Bool
    ) -> (tap: UnsafeMutablePointer<Tap>, processes: [AudioObjectID])? {
        // TODO: precise error domain rather than print.
        let tapPtr = UnsafeMutablePointer<Tap>.allocate(capacity: 1)
        let rampStep = 1.0 / max(1.0, Float32(layout.outputStream.sampleRate * 0.015))
        tapPtr.initialize(to: Tap(
            layout: layout,
            isBypassed: isBypassed ? 1 : 0,
            wetGain: isBypassed ? 0.0 : 1.0,
            rampStep: rampStep
        ))

        guard let deviceID = deviceID(forUID: layout.deviceUID) else {
            print("Error: Unable to convert device UID to AudioObjectID.")
            stopTap(tapPtr)
            return nil
        }
        tapPtr.pointee.deviceID = deviceID

        guard
            let hwSampleRate: Float64 = readProperty(
                deviceID, kAudioDevicePropertyNominalSampleRate)
        else {
            print("Error: Unable to read device sample rate.")
            stopTap(tapPtr)
            return nil
        }

        let hwInputCount: Int = readChannelCount(
            deviceID, kAudioDevicePropertyScopeInput)
        let hwOutputCount: Int = readChannelCount(
            deviceID, kAudioDevicePropertyScopeOutput)

        guard layout.outputStream.hi <= hwOutputCount else {
            print(
                "Error: Output stream range is out of bounds of hardware outputs."
            )
            stopTap(tapPtr)
            return nil
        }

        // Inclusive tap of only processes currently outputting to this device:
        // coreaudiod's mutedWhenTapped on an exclusive tap mutes processes
        // across all devices (e.g. Bluetooth headphones) once any process is
        // active on the tapped device.
        let tapUUID = UUID()
        let td = CATapDescription()
        let initialProcesses = outputProcessIDs(forDevice: deviceID)
        td.processes = initialProcesses
        td.isExclusive = false
        td.deviceUID = layout.deviceUID
        td.stream = UInt(layout.outputStream.index)
        td.name = ProcessInfo.processInfo.processName
        td.uuid = tapUUID
        td.muteBehavior = .mutedWhenTapped
        td.isPrivate = true
        td.isMixdown = false

        var tapID: AudioObjectID = kAudioObjectUnknown
        let tapCreateStatus = AudioHardwareCreateProcessTap(td, &tapID)
        guard tapCreateStatus == noErr, tapID != kAudioObjectUnknown else {
            print("AudioHardwareCreateProcessTap failed.")
            stopTap(tapPtr)
            return nil
        }
        tapPtr.pointee.tapID = tapID

        guard
            let tapASBD: AudioStreamBasicDescription = readProperty(
                tapID, kAudioTapPropertyFormat)
        else {
            print("Error: Unable to read tap format.")
            stopTap(tapPtr)
            return nil
        }

        guard
            hwSampleRate == layout.outputStream.sampleRate,
            hwSampleRate == tapASBD.mSampleRate
        else {
            print(
                "Error: Sample rates are not the same: hw = \(hwSampleRate), layout = \(layout.outputStream.sampleRate), tap = \(tapASBD.mSampleRate)"
            )
            stopTap(tapPtr)
            return nil
        }

        let isFloat = (tapASBD.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard tapASBD.mFormatID == kAudioFormatLinearPCM,
            isFloat,
            tapASBD.mBitsPerChannel == 32
        else {
            dump(tapASBD)
            print("Error: Tap ASBD is not 32-bit float PCM.")
            stopTap(tapPtr)
            return nil
        }

        let expectedChannels = layout.outputStream.hi - layout.outputStream.lo
        guard Int(tapASBD.mChannelsPerFrame) == expectedChannels else {
            print(
                "Error: Tap channel count \(tapASBD.mChannelsPerFrame) does not match layout \(expectedChannels)."
            )
            stopTap(tapPtr)
            return nil
        }

        guard
            0 <= layout.left && layout.left + 1 < (layout.outputStream.hi - layout.outputStream.lo)
        else {
            print(
                "Error: Target stereo pair \(layout.left), \(layout.left+1) is not in stream bounds."
            )
            stopTap(tapPtr)
            return nil
        }
        tapPtr.pointee.leftBufferIndex = layout.left
        tapPtr.pointee.rightBufferIndex = tapPtr.pointee.leftBufferIndex + 1

        let aggregateUUID = UUID()
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpeakerPrep Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUUID.uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: layout.deviceUID
                ]
            ] as [[String: Any]],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUUID.uuidString,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ] as [[String: Any]],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: layout.deviceUID,
        ]
        var aggregateID: AudioObjectID = kAudioObjectUnknown
        let aggregateCreateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &aggregateID)
        guard aggregateCreateStatus == noErr, aggregateID != kAudioObjectUnknown
        else {
            print("Error: failed to create aggregate device.")
            stopTap(tapPtr)
            return nil
        }
        tapPtr.pointee.aggregateID = aggregateID

        print("AudioHardwareCreateAggregateDevice finished: \(aggregateID)")

        var outputComponentDesc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard
            let outputComponent = AudioComponentFindNext(
                nil, &outputComponentDesc)
        else {
            print("Error: failed to find output component.")
            stopTap(tapPtr)
            return nil
        }

        var outputUnit: AudioUnit?
        let status = AudioComponentInstanceNew(outputComponent, &outputUnit)
        guard status == noErr, let outputUnit = outputUnit else {
            print("Error: failed to create output unit.")
            stopTap(tapPtr)
            return nil
        }
        tapPtr.pointee.outputUnit = outputUnit

        var enableIO: UInt32 = 1
        guard
            setProperty(
                outputUnit, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Input, 1, &enableIO,
                MemoryLayout<UInt32>.size)
        else {
            print("Error: Failed to set EnableIO on (input, 1).")
            stopTap(tapPtr)
            return nil
        }
        guard
            setProperty(
                outputUnit, kAudioOutputUnitProperty_EnableIO,
                kAudioUnitScope_Output, 0, &enableIO,
                MemoryLayout<UInt32>.size)
        else {
            print("Error: Failed to set EnableIO on (output, 0).")
            stopTap(tapPtr)
            return nil
        }

        guard
            setProperty(
                outputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &aggregateID,
                MemoryLayout<AudioObjectID>.size)
        else {
            print(
                "Error: Unable to set aggregate device as output unit's current device."
            )
            stopTap(tapPtr)
            return nil
        }

        let floatSize = MemoryLayout<Float32>.size
        var deviceASBD = AudioStreamBasicDescription(
            mSampleRate: layout.outputStream.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(floatSize),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(floatSize),
            mChannelsPerFrame: tapASBD.mChannelsPerFrame,
            mBitsPerChannel: UInt32(floatSize * 8),
            mReserved: 0
        )
        let asbdSize = MemoryLayout<AudioStreamBasicDescription>.size
        guard
            setProperty(
                outputUnit, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Output, 1, &deviceASBD, asbdSize
            )
        else {
            print("Error: Failed to set format on output unit's (output, 1).")
            stopTap(tapPtr)
            return nil
        }
        guard
            setProperty(
                outputUnit, kAudioUnitProperty_StreamFormat,
                kAudioUnitScope_Input, 0, &deviceASBD, asbdSize
            )
        else {
            print("Error: Failed to set format on output unit's (input, 0).")
            stopTap(tapPtr)
            return nil
        }

        let aggInputCount: Int = readChannelCount(
            aggregateID, kAudioDevicePropertyScopeInput)
        let aggOutputCount: Int = readChannelCount(
            aggregateID, kAudioDevicePropertyScopeOutput)

        guard
            aggInputCount == hwInputCount + Int(tapASBD.mChannelsPerFrame)
        else {
            print(
                "Error: Aggregate input channels is not sum of hardware inputs and tap channels."
            )
            stopTap(tapPtr)
            return nil
        }
        guard aggOutputCount == hwOutputCount else {
            print(
                "Error: Aggregate output channels is not the same as hardware outputs."
            )
            stopTap(tapPtr)
            return nil
        }


        // Make sure the software buffers are large enough to support
        // the maximum hardware buffer size.
        var maxFrames: Int = 4096
        if let range: AudioValueRange = readProperty(
            aggregateID, kAudioDevicePropertyBufferFrameSizeRange)
        {
            maxFrames = Int(range.mMaximum)
        }
        tapPtr.pointee.maxFrames = maxFrames

        // The input channel map needs to cover the whole stream that the tap is tapping
        // not just the target stereo pair, otherwise we'd end up muting the other
        // channels.
        // TODO: we're making an assumption here that the tap is last, but there doesn't
        // seem to be any simple way of locating the tap otherwise.
        let tapLo = hwInputCount
        let tapHi = tapLo + Int(tapASBD.mChannelsPerFrame)
        
        let inputChannelMap: [Int32] = (tapLo..<tapHi).map { Int32($0) }

        guard
            setProperty(
                outputUnit,
                kAudioOutputUnitProperty_ChannelMap,
                kAudioUnitScope_Output,
                1,
                inputChannelMap,
                inputChannelMap.count * MemoryLayout<Int32>.size
            )
        else {
            print(
                "Error: Failed to set input channel map on output unit's (output, 1)."
            )
            stopTap(tapPtr)
            return nil
        }

        // The output channel map needs to cover the entire output device indicating
        // -1 to say which channels we are skipping and indicating the outputUnit
        // output index otherwise for the entire stream.
        let lo = layout.outputStream.lo
        let hi = layout.outputStream.hi
        var outputChannelMap: [Int32] = (0..<aggOutputCount).map { i in
            return (i >= lo && i < hi) ? Int32(i - lo) : -1
        }

        guard
            setProperty(
                outputUnit,
                kAudioOutputUnitProperty_ChannelMap,
                kAudioUnitScope_Output,
                0,
                &outputChannelMap,
                outputChannelMap.count * MemoryLayout<Int32>.size
            )
        else {
            print(
                "Error: Failed to set output channel map on output unit's (output, 0)."
            )
            stopTap(tapPtr)
            return nil
        }

        var maxFrames32 = UInt32(maxFrames)
        guard
            setProperty(
                outputUnit, kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global, 0, &maxFrames32,
                MemoryLayout<UInt32>.size)
        else {
            print("Error: Failed to set max frames on output unit.")
            stopTap(tapPtr)
            return nil
        }

        let refCon = UnsafeMutableRawPointer(tapPtr)

        tapPtr.pointee.pullInputBlock = {
            flags, timestamp, frameCount, busNumber, ioData in
            return effectInputCallback(
                refCon,
                flags,
                timestamp,
                UInt32(busNumber),
                frameCount,
                ioData
            )
        }

        var outputCallbackData = AURenderCallbackStruct(
            inputProc: outputCallback,
            inputProcRefCon: refCon
        )
        guard
            setProperty(
                outputUnit, kAudioUnitProperty_SetRenderCallback,
                kAudioUnitScope_Input, 0, &outputCallbackData,
                MemoryLayout<AURenderCallbackStruct>.size)
        else {
            print("Error: Failed to set output callback.")
            stopTap(tapPtr)
            return nil
        }
        
        guard let effectFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: tapASBD.mSampleRate,
            channels: 2,
            interleaved: false
        ) else {
            print("Error: Failed to create AVAudioFormat.")
            stopTap(tapPtr)
            return nil
        }
        
        do {
            try effectUnit.inputBusses[0].setFormat(effectFormat)
            try effectUnit.outputBusses[0].setFormat(effectFormat)
        } catch {
            print("Error: Failed to set format on effect unit busses: \(error)")
            stopTap(tapPtr)
            return nil
        }
        
        // The unit comes from AVAudioUnit.instantiate, whose busses are only
        // enabled by an AVAudioEngine connection. We drive it directly, so
        // enable them ourselves or it renders silence.
        effectUnit.inputBusses[0].isEnabled = true
        effectUnit.outputBusses[0].isEnabled = true
        
        effectUnit.maximumFramesToRender = maxFrames32

        let bufSize = maxFrames * floatSize
        
        let effectInLeftBuf = UnsafeMutablePointer<Float32>.allocate(capacity: maxFrames)
        effectInLeftBuf.initialize(repeating: 0.0, count: maxFrames)
        
        let effectInRightBuf = UnsafeMutablePointer<Float32>.allocate(capacity: maxFrames)
        effectInRightBuf.initialize(repeating: 0.0, count: maxFrames)
        
        let effectOutLeftBuf = UnsafeMutablePointer<Float32>.allocate(capacity: maxFrames)
        effectOutLeftBuf.initialize(repeating: 0.0, count: maxFrames)
        
        let effectOutRightBuf = UnsafeMutablePointer<Float32>.allocate(capacity: maxFrames)
        effectOutRightBuf.initialize(repeating: 0.0, count: maxFrames)
        
        let bufList = AudioBufferList.allocate(maximumBuffers: 2)
        bufList[0] = AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(bufSize),
            mData: effectOutLeftBuf)
        bufList[1] = AudioBuffer(
            mNumberChannels: 1, mDataByteSize: UInt32(bufSize),
            mData: effectOutRightBuf)
        
        tapPtr.pointee.effectInLeftBuf = effectInLeftBuf
        tapPtr.pointee.effectInRightBuf = effectInRightBuf
        tapPtr.pointee.effectOutLeftBuf = effectOutLeftBuf
        tapPtr.pointee.effectOutRightBuf = effectOutRightBuf
        tapPtr.pointee.effectOutBufList = bufList.unsafeMutablePointer

        do {
            try effectUnit.allocateRenderResources()
        } catch {
            print("Error: Failed to allocate render resources: \(error)")
            stopTap(tapPtr)
            return nil
        }
        // Set only after allocation succeeds: stopTap deallocates iff non-nil.
        tapPtr.pointee.effectUnit = effectUnit
        tapPtr.pointee.effectRenderBlock = effectUnit.renderBlock

        guard AudioUnitInitialize(outputUnit) == noErr else {
            print("Error: Failed to set init output unit.")
            stopTap(tapPtr)
            return nil
        }

        guard AudioOutputUnitStart(outputUnit) == noErr else {
            print("Error: Failed to start output unit.")
            stopTap(tapPtr)
            return nil
        }

        return (tap: tapPtr, processes: initialProcesses)
    }

    static func setTapBypassed(
        _ tapPtr: UnsafeMutablePointer<Tap>,
        _ bypassed: Bool
    ) {
        atomicStoreInt32(&tapPtr.pointee.isBypassed, bypassed ? 1 : 0)
    }

    static func stopTap(_ tapPtr: UnsafeMutablePointer<Tap>) {
        if let outputUnit = tapPtr.pointee.outputUnit {
            AudioOutputUnitStop(outputUnit)
            AudioUnitUninitialize(outputUnit)
            AudioComponentInstanceDispose(outputUnit)
            tapPtr.pointee.outputUnit = nil
        }
        tapPtr.pointee.effectRenderBlock = nil
        tapPtr.pointee.pullInputBlock = nil
        tapPtr.pointee.effectUnit?.deallocateRenderResources()
        tapPtr.pointee.effectUnit = nil
        tapPtr.pointee.pulledInput = nil
        if let effectInLeftBuf = tapPtr.pointee.effectInLeftBuf {
            effectInLeftBuf.deallocate()
            tapPtr.pointee.effectInLeftBuf = nil
        }
        if let effectInRightBuf = tapPtr.pointee.effectInRightBuf {
            effectInRightBuf.deallocate()
            tapPtr.pointee.effectInRightBuf = nil
        }
        if let effectOutLeftBuf = tapPtr.pointee.effectOutLeftBuf {
            effectOutLeftBuf.deallocate()
            tapPtr.pointee.effectOutLeftBuf = nil
        }
        if let effectOutRightBuf = tapPtr.pointee.effectOutRightBuf {
            effectOutRightBuf.deallocate()
            tapPtr.pointee.effectOutRightBuf = nil
        }
        if let effectOutBufList = tapPtr.pointee.effectOutBufList {
            effectOutBufList.deallocate()
            tapPtr.pointee.effectOutBufList = nil
        }
        if tapPtr.pointee.aggregateID != kAudioObjectUnknown {
            destroyAggregate(tapPtr.pointee.aggregateID)
            tapPtr.pointee.aggregateID = kAudioObjectUnknown
        }
        if tapPtr.pointee.tapID != kAudioObjectUnknown {
            destroyTap(tapPtr.pointee.tapID)
            tapPtr.pointee.tapID = kAudioObjectUnknown
        }

        tapPtr.deinitialize(count: 1)
        tapPtr.deallocate()
    }

    static func currentProcessIDs() -> [AudioObjectID] {
        guard
            let all: [AudioObjectID] = readPropertyArray(
                AudioObjectID(kAudioObjectSystemObject),
                kAudioHardwarePropertyProcessObjectList)
        else {
            return []
        }
        let own = ownProcessID()
        return all.filter { $0 != own }
    }

    static func outputProcessIDs(forDevice deviceID: AudioObjectID) -> [AudioObjectID] {
        var matched: [AudioObjectID] = []
        for procID in currentProcessIDs() {
            guard
                let devices: [AudioObjectID] = readPropertyArray(
                    procID,
                    kAudioProcessPropertyDevices,
                    kAudioObjectPropertyScopeOutput,
                    kAudioObjectPropertyElementMain)
            else {
                continue
            }
            if devices.contains(deviceID) {
                matched.append(procID)
            }
        }
        return matched.sorted()
    }

    static func updateTapProcesses(
        _ tapID: AudioObjectID,
        _ processes: [AudioObjectID]
    ) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rawDesc: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        let getStatus = AudioObjectGetPropertyData(
            tapID, &addr, 0, nil, &size, &rawDesc)
        guard getStatus == noErr, let desc = rawDesc?.takeRetainedValue() else {
            print("Error: Unable to read tap description: \(getStatus)")
            return false
        }
        if Set(desc.processes) == Set(processes) { return true }
        desc.processes = processes
        var ref = Unmanaged.passUnretained(desc)
        let setStatus = AudioObjectSetPropertyData(
            tapID, &addr, 0, nil,
            UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size), &ref)
        if setStatus != noErr {
            print("Error: Unable to update tap processes: \(setStatus)")
            return false
        }
        return true
    }

    // Fires when devices are added or removed.
    static func listenForDeviceList(
        _ queue: DispatchQueue,
        _ onChange: @escaping () -> Void
    ) -> HardwareListener {
        return listen(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioObjectPropertyScopeGlobal,
            [kAudioHardwarePropertyDevices],
            queue, onChange)
    }

    static func listenForProcessList(
        _ queue: DispatchQueue,
        _ onChange: @escaping () -> Void
    ) -> HardwareListener {
        return listen(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioObjectPropertyScopeGlobal,
            [kAudioHardwarePropertyProcessObjectList],
            queue, onChange)
    }

    // Fires when the device's sample rate changes or it goes away. Returns
    // nil if the device isn't present.
    static func listenToDevice(
        _ uid: String,
        _ queue: DispatchQueue,
        _ onChange: @escaping () -> Void
    ) -> HardwareListener? {
        guard let deviceID = deviceID(forUID: uid) else {
            return nil
        }
        return listen(
            deviceID,
            kAudioObjectPropertyScopeGlobal,
            [kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyDeviceIsAlive],
            queue, onChange)
    }

    static func listenToProcess(
        _ processID: AudioObjectID,
        _ queue: DispatchQueue,
        _ onChange: @escaping () -> Void
    ) -> HardwareListener {
        return listen(
            processID,
            kAudioObjectPropertyScopeOutput,
            [kAudioProcessPropertyDevices],
            queue, onChange)
    }

    static func stopListening(_ listener: HardwareListener, _ queue: DispatchQueue) {
        for selector in listener.selectors {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: listener.scope,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                listener.objectID, &addr, queue, listener.block)
        }
    }

    private static func listen(
        _ objectID: AudioObjectID,
        _ scope: AudioObjectPropertyScope,
        _ selectors: [AudioObjectPropertySelector],
        _ queue: DispatchQueue,
        _ onChange: @escaping () -> Void
    ) -> HardwareListener {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            onChange()
        }
        for selector in selectors {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectAddPropertyListenerBlock(objectID, &addr, queue, block)
        }
        return HardwareListener(
            objectID: objectID, scope: scope, selectors: selectors, block: block)
    }

    private static func ownProcessID() -> AudioObjectID? {
        guard
            let processID: AudioObjectID = readPropertyQualified(
                AudioObjectID(kAudioObjectSystemObject),
                kAudioHardwarePropertyTranslatePIDToProcessObject,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain,
                ProcessInfo.processInfo.processIdentifier
            ), processID != kAudioObjectUnknown, processID != 0
        else {
            return nil
        }
        return processID
    }

    private static func deviceID(forUID uid: String) -> AudioObjectID? {
        let uidCF = uid as CFString
        guard
            let deviceID: AudioObjectID = readPropertyQualified(
                AudioObjectID(kAudioObjectSystemObject),
                kAudioHardwarePropertyTranslateUIDToDevice,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain,
                uidCF
            ), deviceID != kAudioObjectUnknown, deviceID != 0
        else {
            return nil
        }
        return deviceID
    }
    
    static func instantiateEffect(_ effectID: EffectID) -> AVAudioUnit? {
        var acd = AudioComponentDescription()
        acd.componentType = effectID.componentType
        acd.componentSubType = effectID.componentSubType
        acd.componentManufacturer = effectID.componentManufacturer

        var maybeUnit: AVAudioUnit?
        let semaphore = DispatchSemaphore(value: 0)

        // Out-of-process for AUv3.
        AVAudioUnit.instantiate(with: acd, options: [.loadOutOfProcess]) { maybeUnitV3, _ in
            if maybeUnitV3 != nil {
                maybeUnit = maybeUnitV3
                semaphore.signal()
                return
            }
            
            // In-process for AUv2.
            AVAudioUnit.instantiate(with: acd, options: []) { maybeUnitV2, error in
                if let error = error {
                    print("Failed to instantiate Audio Unit: \(error.localizedDescription)")
                }
                maybeUnit = maybeUnitV2
                semaphore.signal()
            }
        }

        // The completion runs on an arbitrary thread; the SDK's deadlock warning
        // is about blocking main. This is the state machine's queue, not main.
        semaphore.wait()
        return maybeUnit
    }

    private static func destroyTap(_ tapID: AudioObjectID) {
        let status = AudioHardwareDestroyProcessTap(tapID)
        if status == noErr {
            print("Tap finished: \(tapID)")
        } else {
            print("AudioHardwareDestroyProcessTap failed: \(tapID)")
        }
    }

    private static func destroyAggregate(_ aggregateID: AudioObjectID) {
        let status = AudioHardwareDestroyAggregateDevice(aggregateID)
        if status == noErr {
            print("Aggregate finished: \(aggregateID)")
        } else {
            print("AudioHardwareDestroyAggregateDevice failed: \(aggregateID)")
        }
    }

    private static func setProperty(
        _ unit: AudioUnit,
        _ propID: AudioUnitPropertyID,
        _ scope: AudioUnitScope,
        _ elem: AudioUnitElement,
        _ data: UnsafeRawPointer,
        _ size: Int
    ) -> Bool {
        let status = AudioUnitSetProperty(
            unit, propID, scope, elem, data, UInt32(size))
        return status == noErr
    }

    private static func readProperty<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> T? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var dataSize = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        let status = AudioObjectGetPropertyData(
            objectID, &addr, 0, nil, &dataSize, pointer)
        return status == noErr ? pointer.pointee : nil
    }

    private static func readPropertyArray<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> [T]? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            objectID, &addr, 0, nil, &dataSize)
        guard sizeStatus == noErr else { return nil }
        guard dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<T>.size
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        let dataStatus = AudioObjectGetPropertyData(
            objectID, &addr, 0, nil, &dataSize, pointer)
        guard dataStatus == noErr else { return nil }
        let buffer = UnsafeBufferPointer(start: pointer, count: count)
        return Array(buffer)
    }

    private static func readPropertyQualified<T, Q>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope,
        _ element: AudioObjectPropertyElement,
        _ qualifier: Q
    ) -> T? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
        var qual = qualifier
        let qualSize = UInt32(MemoryLayout<Q>.size)
        var dataSize = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        let status = withUnsafePointer(to: &qual) { qualPtr in
            AudioObjectGetPropertyData(
                objectID, &addr, qualSize, qualPtr, &dataSize, pointer)
        }
        return status == noErr ? pointer.pointee : nil
    }

    private static func readChannelCount(
        _ objectID: AudioObjectID,
        _ scope: AudioObjectPropertyScope  // input or output
    ) -> Int {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            objectID, &addr, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else {
            print("Error: failed to read data size of audio buffer list.")
            return 0
        }

        let pointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { pointer.deallocate() }

        let readStatus = AudioObjectGetPropertyData(
            objectID, &addr, 0, nil, &dataSize, pointer)
        guard readStatus == noErr else {
            print("Error: failed to read data of audio buffer list.")
            return 0
        }

        let bufferListPtr = pointer.bindMemory(
            to: AudioBufferList.self, capacity: 1)
        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPtr)

        var count = 0
        for buffer in bufferList {
            count += Int(buffer.mNumberChannels)
        }

        return count
    }
}
