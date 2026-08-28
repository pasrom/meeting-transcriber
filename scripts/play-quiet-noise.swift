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
//   --seconds 0 (the default) plays until killed.

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

if seconds > 0 {
    Thread.sleep(forTimeInterval: seconds)
    engine.stop()
} else {
    // Killed by the caller. `dispatchMain` never returns, which is what a
    // lane script's `kill -TERM` expects to interrupt.
    dispatchMain()
}
