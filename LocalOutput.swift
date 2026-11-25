import CoreAudio
import Foundation
import Synchronization

struct LocalOutput: Identifiable, Equatable {
    static let symbol = "headphones"
    let id: AudioObjectID
    let name: String
    let uid: String?

    static func list() throws -> [Self] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var property = outputAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try outputCheck(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size))
        let stride = MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        if ids.isEmpty { return [] }
        try ids.withUnsafeMutableBytes {
            try outputCheck(AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!))
        }
        return ids.prefix(Int(size) / stride).compactMap { id in
            var property = outputAddress(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var size = UInt32(MemoryLayout.size(ofValue: transport))
            guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &transport) == noErr,
                  [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport) else { return nil }
            property = outputAddress(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size) == noErr, size > 0 else { return nil }
            guard let name = AudioInput.string(id, kAudioObjectPropertyName) else { return nil }
            let uid = AudioInput.string(id, kAudioDevicePropertyDeviceUID)
            return Self(id: id, name: name, uid: uid)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private func outputAddress(_ selector: AudioObjectPropertySelector,
                           _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

private func outputCheck(_ status: OSStatus) throws {
    if status != noErr { throw StreamError("Bluetooth / Core Audio: \(status)") }
}

private let outputCallback: AudioDeviceIOProc = { _, _, _, _, output, _, context in
    guard let context else { return noErr }
    let player = Unmanaged<LocalPlayback>.fromOpaque(context).takeUnretainedValue()
    player.render(UnsafeMutableAudioBufferListPointer(output))
    return noErr
}

final class LocalPlayback {
    static let maximumDelayMilliseconds = 1_000
    private let id: AudioObjectID
    private let outputRate: Double
    private var callback: AudioDeviceIOProcID?
    private var inputRate = 44100.0
    private let capacity = 32768
    private let ring: UnsafeMutablePointer<Int16>
    private let readIndex = Atomic<Int>(0)
    private let writeIndex = Atomic<Int>(0)
    let level = Atomic<Int>(45)
    let balance = Atomic<Int>(0)
    let delayMilliseconds = Atomic<Int>(0)
    let renderedFrames = Atomic<Int>(0)
    let renderedNonSilentFrames = Atomic<Int>(0)
    private let delay: StereoOutputDelay?
    private var phase = 0.0
    private var buffering = true

    convenience init(device: LocalOutput, adjustable: Bool = false) throws {
        var property = outputAddress(kAudioDevicePropertyStreamFormat, kAudioObjectPropertyScopeOutput)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: description))
        try outputCheck(AudioObjectGetPropertyData(device.id, &property, 0, nil, &size, &description))
        guard description.mChannelsPerFrame == 2, (8000...192000).contains(description.mSampleRate),
              description.mFormatID == kAudioFormatLinearPCM, description.mBitsPerChannel == 32,
              description.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw StreamError("Bluetooth requires a Float32 stereo output.")
        }
        self.init(id: device.id, outputRate: description.mSampleRate, adjustable: adjustable)
    }

    init(id: AudioObjectID, outputRate: Double, adjustable: Bool) {
        self.id = id
        self.outputRate = outputRate
        ring = .allocate(capacity: capacity * 2)
        delay = adjustable ? StereoOutputDelay(sampleRate: outputRate) : nil
    }

    func start(inputRate: Int) throws {
        self.inputRate = Double(inputRate)
        try outputCheck(AudioDeviceCreateIOProcID(id, outputCallback, Unmanaged.passUnretained(self).toOpaque(), &callback))
        guard let callback else { throw StreamError("Could not open the Bluetooth output.") }
        try outputCheck(AudioDeviceStart(id, callback))
    }

    func stop() {
        guard let callback else { return }
        AudioDeviceStop(id, callback)
        AudioDeviceDestroyIOProcID(id, callback)
        self.callback = nil
    }

    deinit {
        stop()
        ring.deallocate()
    }

    // Capture owns the write index. Playback owns the read index.
    func enqueue(_ samples: UnsafePointer<Int16>, frames: Int) -> Bool {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        guard frames <= capacity - (write - read) else { return false }
        for frame in 0..<frames {
            let slot = ((write + frame) % capacity) * 2
            ring[slot] = samples[frame * 2]
            ring[slot + 1] = samples[frame * 2 + 1]
        }
        writeIndex.store(write + frames, ordering: .releasing)
        return true
    }

    func render(_ buffers: UnsafeMutableAudioBufferListPointer) {
        let floatSize = MemoryLayout<Float>.size
        for buffer in buffers {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        guard let first = buffers.first, let leftData = first.mData else { return }
        let interleaved = buffers.count == 1 && first.mNumberChannels == 2
        let left = leftData.assumingMemoryBound(to: Float.self)
        let right: UnsafeMutablePointer<Float>
        let count: Int
        if interleaved {
            right = left.advanced(by: 1)
            count = Int(first.mDataByteSize) / (2 * floatSize)
        } else if buffers.count == 2, first.mNumberChannels == 1, buffers[1].mNumberChannels == 1,
                  let data = buffers[1].mData {
            right = data.assumingMemoryBound(to: Float.self)
            count = min(Int(first.mDataByteSize), Int(buffers[1].mDataByteSize)) / floatSize
        } else { return }

        guard count > 0 else { return }
        _ = renderedFrames.wrappingAdd(count, ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        var read = readIndex.load(ordering: .relaxed)
        let fill = write - read
        let target = Int(inputRate * 0.10)
        if buffering, fill >= target { buffering = false }
        let correction = max(-0.003, min(0.003, Double(fill - target) / inputRate * 0.08))
        let step = inputRate / outputRate * (1 + correction)
        let gain = Float(level.load(ordering: .relaxed)) / 100
        let pan = Float(balance.load(ordering: .relaxed)) / 100
        let leftGain = gain * (1 - max(0, pan))
        let rightGain = gain * (1 + min(0, pan))
        delay?.setMilliseconds(delayMilliseconds.load(ordering: .relaxed))
        let stride = interleaved ? 2 : 1
        var nonSilent = 0
        for index in 0..<count {
            var sample: (Float, Float) = (0, 0)
            if !buffering, write - read > max(1, Int(phase + step)) {
                let a = (read % capacity) * 2
                let b = ((read + 1) % capacity) * 2
                let fraction = Float(phase)
                sample.0 = (Float(ring[a]) * (1 - fraction) + Float(ring[b]) * fraction) / 32768
                sample.1 = (Float(ring[a + 1]) * (1 - fraction) + Float(ring[b + 1]) * fraction) / 32768
                phase += step
                let consumed = Int(phase)
                read += consumed
                phase -= Double(consumed)
            } else {
                buffering = true
                phase = 0
                if delay == nil { break }
            }
            if let delay { sample = delay.process(sample) }
            left[index * stride] = sample.0 * leftGain
            right[index * stride] = sample.1 * rightGain
            if abs(left[index * stride]) + abs(right[index * stride]) > 0.0001 { nonSilent += 1 }
        }
        readIndex.store(read, ordering: .releasing)
        if nonSilent > 0 { _ = renderedNonSilentFrames.wrappingAdd(nonSilent, ordering: .relaxed) }
    }
}

private final class StereoOutputDelay {
    private let sampleRate: Double
    private let capacity: Int
    private let history: UnsafeMutablePointer<SIMD2<Float>>
    private let crossfadeFrames: Int
    private var cursor = 0
    private var position: Int?
    private var previous = 0
    private var fade = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        capacity = Int(ceil(sampleRate * Double(LocalPlayback.maximumDelayMilliseconds) / 1000)) + 1
        crossfadeFrames = max(1, Int(sampleRate * 0.005))
        history = .allocate(capacity: capacity)
        history.initialize(repeating: .zero, count: capacity)
    }

    deinit { history.deallocate() }

    func setMilliseconds(_ milliseconds: Int) {
        let frames = min(capacity - 1, max(0, Int((sampleRate * Double(milliseconds) / 1000).rounded())))
        guard position != frames else { return }
        if let position {
            previous = position
            fade = crossfadeFrames
        }
        position = frames
    }

    func process(_ sample: (Float, Float)) -> (Float, Float) {
        history[cursor] = SIMD2(sample.0, sample.1)
        var result = history[(cursor + capacity - (position ?? 0)) % capacity]
        if fade > 0 {
            let weight = Float(fade) / Float(crossfadeFrames)
            result = result * (1 - weight) + history[(cursor + capacity - previous) % capacity] * weight
            fade -= 1
        }
        cursor = (cursor + 1) % capacity
        return (result.x, result.y)
    }
}

// Core Audio calls one reader at a time. Only the main actor publishes new
// snapshots and releases retired ones between capture callbacks.
final class LocalPlaybackFanout {
    private final class Targets {
        let players: [LocalPlayback]
        init(_ players: [LocalPlayback]) { self.players = players }
    }

    private let current = Atomic<UnsafeMutableRawPointer?>(nil)
    private let reading = Atomic<Bool>(false)
    private var retired: [Unmanaged<Targets>] = []

    @MainActor func replace(with players: [LocalPlayback]) {
        let next = players.isEmpty ? nil : Unmanaged.passRetained(Targets(players)).toOpaque()
        if let old = current.exchange(next, ordering: .sequentiallyConsistent) {
            retired.append(Unmanaged.fromOpaque(old))
        }
        reclaim()
    }

    @MainActor func reclaim() {
        guard !reading.load(ordering: .sequentiallyConsistent) else { return }
        for snapshot in retired { snapshot.release() }
        retired.removeAll(keepingCapacity: true)
    }

    func enqueue(_ samples: UnsafePointer<Int16>, frames: Int) {
        reading.store(true, ordering: .sequentiallyConsistent)
        if let pointer = current.load(ordering: .sequentiallyConsistent) {
            let targets = Unmanaged<Targets>.fromOpaque(pointer).takeUnretainedValue()
            for player in targets.players { _ = player.enqueue(samples, frames: frames) }
        }
        reading.store(false, ordering: .sequentiallyConsistent)
    }

    deinit {
        if let pointer = current.load(ordering: .relaxed) { Unmanaged<Targets>.fromOpaque(pointer).release() }
        for snapshot in retired { snapshot.release() }
    }
}
