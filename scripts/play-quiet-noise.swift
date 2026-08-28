#!/usr/bin/env swift
// Plays low-level noise into one named output device, for as long as it is
// left running.
//
// Why a dedicated player rather than `afplay` and a routing change: the
// microphone side of an E2E lane needs a channel that is *alive but quiet*,
// which is the state issue #614 is about. A live microphone in a quiet room
// delivers non-zero samples below the -60 dBFS silence threshold, so
// `ChannelFaultMonitor` must see recent energy and stay quiet while the
// asymmetric-silence episode still latches the menu-bar tint.
//
// The device has to be named explicitly. BlackHole loops back whatever any
// client plays into it regardless of the system default, so addressing it
// directly leaves the default output alone: the meeting simulator keeps
// playing where it always did, and its audio never reaches the loopback that
// feeds the microphone track. Rerouting the default instead would put the
// simulator's fixture into the microphone channel at full level and destroy
// the asymmetry the lane depends on. (The app-audio track is unaffected
// either way: it comes from the process tap, which reads process output and
// touches no device.)
//
// Usage: play-quiet-noise.swift --device "BlackHole 2ch" [--dbfs -70] [--seconds 0]
//                                [--verify]
//   --seconds 0 (the default) plays until killed.
//   --verify captures from the same device while playing and reports what came
//   back. Exit 4: the capture was authorized and running and the device still
//   carried nothing — a real loopback problem. Exit 3: no verdict, because
//   this process may not capture at all (microphone TCC), which macOS signals
//   by delivering all-zero buffers with no error; from an SSH shell that is
//   the guaranteed outcome, so run the verify from the GUI session or CI.
//   Without the flag a caller can only observe the player from outside, where
//   a working player and one whose audio goes nowhere look identical: the
//   process stays up, the render block runs, the device reads back correctly.
//   That cost a whole round of remote debugging, so the check lives here.

import AVFoundation
import CoreAudio
import Foundation

// MARK: - Arguments

func argument(_ name: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: name),
          index + 1 < CommandLine.arguments.count
    else { return nil }
    return CommandLine.arguments[index + 1]
}

guard let deviceName = argument("--device") else {
    FileHandle.standardError.write(Data("usage: play-quiet-noise.swift --device <name> [--dbfs -70] [--seconds 0]\n".utf8))
    exit(2)
}
let dbfs = Double(argument("--dbfs") ?? "-70") ?? -70
let seconds = Double(argument("--seconds") ?? "0") ?? 0
let verify = CommandLine.arguments.contains("--verify")

// MARK: - Device lookup

/// The `AudioDeviceID` whose name matches, or nil. Matched on the human name
/// rather than the UID because that is what a lane script and a person in
/// System Settings both see; UIDs for virtual drivers are opaque.
func outputDevice(named wanted: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain,
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size,
    ) == noErr else { return nil }

    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices,
    ) == noErr else { return nil }

    for device in devices {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain,
        )
        // Unmanaged, matching `readCFStringAudioProperty` in AudioTapLib: the
        // property returns a +1 reference, and reading it into a plain
        // `CFString` variable both leaks and warns.
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &name) == noErr,
              let deviceName = name?.takeRetainedValue(),
              deviceName as String == wanted
        else { continue }

        // Must actually have output streams: an input-only device with the
        // same name would bind and then silently play nowhere.
        var streamAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain,
        )
        var streamSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &streamAddress, 0, nil, &streamSize) == noErr,
              streamSize > 0
        else { continue }
        return device
    }
    return nil
}

guard let device = outputDevice(named: deviceName) else {
    FileHandle.standardError.write(Data("ERROR: no output device named \"\(deviceName)\"\n".utf8))
    exit(1)
}

// MARK: - Engine

let engine = AVAudioEngine()

// Bind the engine's output to the named device instead of the system default.
// This is the whole point of the tool, so a failure here is fatal rather than
// a fallback: playing into the default output would feed the wrong device and
// the lane would assert against a channel nobody wrote to.
var deviceID = device
let status = AudioUnitSetProperty(
    engine.outputNode.audioUnit!,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global,
    0,
    &deviceID,
    UInt32(MemoryLayout<AudioDeviceID>.size),
)
guard status == noErr else {
    FileHandle.standardError.write(Data("ERROR: could not bind output to \"\(deviceName)\" (status \(status))\n".utf8))
    exit(1)
}

// Read back rather than trust the status. A silent misbind sounds exactly like
// a working player from the outside: the process stays up, prints that it is
// playing, and the device that was supposed to receive the audio stays quiet.
// That is the failure this tool exists to make impossible to mistake for a
// product defect.
var boundDevice = AudioDeviceID(0)
var boundSize = UInt32(MemoryLayout<AudioDeviceID>.size)
let readBack = AudioUnitGetProperty(
    engine.outputNode.audioUnit!,
    kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global,
    0,
    &boundDevice,
    &boundSize,
)
guard readBack == noErr, boundDevice == device else {
    FileHandle.standardError.write(Data(
        "ERROR: output bound to device \(boundDevice), expected \(device) for \"\(deviceName)\"\n".utf8,
    ))
    exit(1)
}

let amplitude = Float(pow(10.0, dbfs / 20.0))

// The device's own rate, read from CoreAudio, not the output node's format.
// The node still reports the format of whatever device the engine was created
// against, and it does not refresh when the device is swapped underneath it:
// binding to a 48 kHz loopback while the previous default ran at 24 kHz left
// the graph running at 24 kHz, and nothing audible reached the device.
var rateAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyNominalSampleRate,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain,
)
var deviceRate: Float64 = 0
var rateSize = UInt32(MemoryLayout<Float64>.size)
guard AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &rateSize, &deviceRate) == noErr,
      deviceRate > 0,
      let format = AVAudioFormat(standardFormatWithSampleRate: deviceRate, channels: 2)
else {
    FileHandle.standardError.write(Data("ERROR: could not read the sample rate of \"\(deviceName)\"\n".utf8))
    exit(1)
}

// White noise rather than a tone: a tone at -70 dBFS is a single bin and a
// noise gate or a resampler could plausibly swallow it, while broadband noise
// is what a real room sounds like and is what the energy flag has to see.
var generator = SystemRandomNumberGenerator()
let source = AVAudioSourceNode { _, _, frameCount, audioBufferList in
    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    for frame in 0 ..< Int(frameCount) {
        let sample = Float.random(in: -amplitude ... amplitude, using: &generator)
        for buffer in buffers {
            let data = buffer.mData!.assumingMemoryBound(to: Float.self)
            data[frame] = sample
        }
    }
    return noErr
}

engine.attach(source)
engine.connect(source, to: engine.mainMixerNode, format: format)

do {
    try engine.start()
} catch {
    FileHandle.standardError.write(Data("ERROR: engine failed to start: \(error)\n".utf8))
    exit(1)
}

print("Playing \(dbfs) dBFS noise into \"\(deviceName)\" at \(Int(deviceRate)) Hz"
    + (seconds > 0 ? " for \(seconds)s" : " until killed"))
fflush(stdout)

if verify {
    // Capture through a raw HAL IOProc, not a second AVAudioEngine. Measured
    // on two hosts: an AVAudioEngine input pinned to the device reads pure
    // silence when the SAME process is also playing through an AVAudioEngine
    // output, even while a separate process hears the loopback fine — so the
    // engine-based listener produced a false "loopback carried nothing" on a
    // healthy device. A plain AudioDeviceCreateIOProcID capture co-exists with
    // the playback engine in one process and reads the real ring.
    //
    // TCC first, because macOS delivers all-zero input buffers to an
    // unauthorized client with no error and a clean start: an SSH-spawned
    // process is attributed to the sshd chain and reads zeroes from a device
    // that is carrying signal (verified on the CI mini, where the identical
    // capture read -12.8 dBFS once launched in the gui launchd domain). Zero
    // samples therefore mean nothing until the authorization status says this
    // process was allowed to see any.
    let micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

    final class VerifyState: @unchecked Sendable {
        var peak: Float = 0
        var callbacks = 0
        let lock = NSLock()
    }
    let state = VerifyState()
    var procID: AudioDeviceIOProcID?
    let createStatus = AudioDeviceCreateIOProcID(device, { _, _, inInputData, _, _, _, clientData in
        let state = Unmanaged<VerifyState>.fromOpaque(clientData!).takeUnretainedValue()
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
        var maximum: Float = 0
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let samples = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let floats = data.assumingMemoryBound(to: Float.self)
            for index in 0 ..< samples {
                maximum = max(maximum, abs(floats[index]))
            }
        }
        state.lock.lock()
        state.peak = max(state.peak, maximum)
        state.callbacks += 1
        state.lock.unlock()
        return noErr
    }, Unmanaged.passUnretained(state).toOpaque(), &procID)
    guard createStatus == noErr, let procID, AudioDeviceStart(device, procID) == noErr else {
        FileHandle.standardError.write(Data("VERIFY: cannot open a capture IOProc on \"\(deviceName)\" — no verdict about the loopback from here\n".utf8))
        exit(3)
    }

    Thread.sleep(forTimeInterval: 2)
    AudioDeviceStop(device, procID)
    AudioDeviceDestroyIOProcID(device, procID)

    state.lock.lock()
    let observed = state.peak
    let callbacks = state.callbacks
    state.lock.unlock()

    if observed > 0 {
        print(String(format: "VERIFY: loopback peak %.1f dBFS over 2 s", 20 * log10(Double(observed))))
    } else if !micAuthorized || callbacks == 0 {
        // Zeroes from a process that was never allowed to see samples (or a
        // device that never called back) say nothing about the loopback.
        // Deciding "the loopback is dead" here is the wrong-direction error
        // this tool exists to prevent — it cost a day of blaming a healthy
        // player. The same applies one level up: an app binary exec'd from an
        // SSH shell inherits this unauthorized context even when the bundle
        // itself holds a microphone grant, so a lane hand-run over SSH records
        // digital silence from a working device.
        let message = "VERIFY: inconclusive — this process may not capture audio "
            + "(mic TCC: \(micAuthorized ? "authorized" : "not authorized"), input callbacks: \(callbacks)). "
            + "Run from the GUI session or CI, not an SSH shell.\n"
        FileHandle.standardError.write(Data(message.utf8))
        exit(3)
    } else {
        FileHandle.standardError.write(Data("VERIFY: \"\(deviceName)\" carried nothing back while this process was playing into it (capture was authorized and running)\n".utf8))
        exit(4)
    }
}

if seconds > 0 {
    Thread.sleep(forTimeInterval: seconds)
    engine.stop()
} else {
    // Killed by the caller. `dispatchMain` never returns, which is what a
    // lane script's `kill -TERM` expects to interrupt.
    dispatchMain()
}
