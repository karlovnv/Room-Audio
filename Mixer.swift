import CoreAudio
import Darwin
import Foundation
import Synchronization

struct MixInput: Equatable {
    let id: String
    let source: AudioSource?
    let gain: Double
    let muted: Bool
    let unavailable: String?
}

struct MixInputStatus: Equatable {
    var hasSignal = false
    var error: String?
}

// The Core Audio callback writes once. The mixer queue is the sole reader.
final class MixInputBuffer: @unchecked Sendable {
    private let capacity = 32_768
    private let samples: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<Int>(0)
    private let readIndex = Atomic<Int>(0)

    init() { samples = .allocate(capacity: capacity * 2) }
    deinit { samples.deallocate() }

    func enqueue(_ first: UnsafePointer<Float>, right: UnsafePointer<Float>?, frames: Int, channels: Int) {
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        let accepted = min(frames, capacity - (write - read))
        for frame in 0..<accepted {
            let target = ((write + frame) % capacity) * 2
            let left = first[frame * channels]
            let rightSample = right?[frame] ?? first[frame * channels + min(1, channels - 1)]
            samples[target] = left.isFinite ? max(-1, min(1, left)) : 0
            samples[target + 1] = rightSample.isFinite ? max(-1, min(1, rightSample)) : 0
        }
        writeIndex.store(write + accepted, ordering: .releasing)
    }

    var queuedFrames: Int {
        writeIndex.load(ordering: .acquiring) - readIndex.load(ordering: .relaxed)
    }

    func mix(into output: UnsafeMutablePointer<Float>, frames: Int, phase: inout Double,
             ratio: Double, gain: Float, previousGain: inout Float) -> Float {
        var read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        var peak: Float = 0
        let gainStep = (gain - previousGain) / Float(frames)
        var gainNow = previousGain
        for frame in 0..<frames {
            guard write - read >= 2 else { break }
            let a = (read % capacity) * 2
            let b = ((read + 1) % capacity) * 2
            let fraction = Float(phase)
            gainNow += gainStep
            for channel in 0..<2 {
                let sample = samples[a + channel] + (samples[b + channel] - samples[a + channel]) * fraction
                peak = max(peak, abs(sample))
                output[frame * 2 + channel] += sample * gainNow
            }
            phase += ratio
            let consumed = Int(phase)
            if consumed > write - read {
                read = write
                phase = 0
                break
            }
            read += consumed
            phase -= Double(consumed)
        }
        previousGain = gain
        readIndex.store(read, ordering: .releasing)
        return peak
    }
}

private final class MixChannel {
    let ring: MixInputBuffer
    let inputRate: Int
    var gain: Float = 0
    var previousGain: Float = 0
    var phase = 0.0
    var primed = false
    var recentSignal: UInt64?

    init(ring: MixInputBuffer, inputRate: Int) {
        self.ring = ring
        self.inputRate = inputRate
    }

    func mix(into samples: UnsafeMutablePointer<Float>, frames: Int, now: UInt64) {
        let fill = ring.queuedFrames
        let target = inputRate / 25
        if fill < 2 { primed = false }
        guard primed || fill >= target else { return }
        primed = true
        // Correct slow drift between independent Core Audio clocks around a 40 ms queue.
        let correction = max(-0.005, min(0.005, Double(fill - target) / Double(target) * 0.002))
        let ratio = Double(inputRate) / Double(MixRenderer.sampleRate) * (1 + correction)
        if ring.mix(into: samples, frames: frames, phase: &phase, ratio: ratio, gain: gain, previousGain: &previousGain) >= 0.001 {
            recentSignal = now
        }
    }
}

// All render state is confined to queue. Input capture callbacks only access their buffers.
private final class MixRenderer: @unchecked Sendable {
    static let sampleRate = 48_000
    private static let chunk = 128
    private let fd: Int32
    private let queue = DispatchQueue(label: "room-audio.mix", qos: .userInitiated)
    private let samples: UnsafeMutablePointer<Float>
    private let pcm: UnsafeMutablePointer<Int16>
    private var channels: [String: MixChannel] = [:]
    private var timer: DispatchSourceTimer?
    private var epoch: UInt64 = 0
    private var framesWritten: UInt64 = 0
    private var pendingFrames = 0
    private var peak: Float = 0
    let failed = Atomic<Bool>(false)

    init(fd: Int32) throws {
        self.fd = fd
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETNOSIGPIPE, 1) >= 0,
              fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw StreamError("Не удалось открыть канал микшера")
        }
        samples = .allocate(capacity: Self.chunk * 2)
        pcm = .allocate(capacity: Self.chunk * 2)
    }

    deinit {
        timer?.cancel()
        samples.deallocate()
        pcm.deallocate()
    }

    func setChannels(_ channels: [String: MixChannel], gains: [String: Float]) {
        queue.sync {
            for (id, channel) in channels { channel.gain = gains[id] ?? 0 }
            self.channels = channels
        }
    }

    func start() {
        queue.sync {
            guard timer == nil else { return }
            epoch = DispatchTime.now().uptimeNanoseconds
            framesWritten = 0
            pendingFrames = 0
            let tick = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            tick.schedule(deadline: .now(), repeating: .milliseconds(5), leeway: .milliseconds(1))
            tick.setEventHandler { [weak self] in self?.render() }
            timer = tick
            tick.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    func meter() -> (Float, Set<String>) {
        queue.sync {
            let now = DispatchTime.now().uptimeNanoseconds
            let value = peak
            peak = 0
            let signals = channels.compactMap { id, channel in
                channel.recentSignal.map { now - $0 < 750_000_000 } == true ? id : nil
            }
            return (value, Set(signals))
        }
    }

    private func render() {
        guard timer != nil, !failed.load(ordering: .relaxed) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsed = now - epoch
        let expected = elapsed / 1_000_000 * UInt64(Self.sampleRate) / 1000
        guard expected > framesWritten else { return }
        if expected - framesWritten > UInt64(Self.sampleRate / 2) {
            failed.store(true, ordering: .relaxed)
            return
        }
        let eligible = min(Int(expected - framesWritten), Self.sampleRate / 25)
        var written = 0
        while written < eligible {
            if pendingFrames == 0 {
                let count = min(Self.chunk, eligible - written)
                for i in 0..<(count * 2) { samples[i] = 0 }
                for channel in channels.values { channel.mix(into: samples, frames: count, now: now) }
                for i in 0..<(count * 2) {
                    let sample = max(-1, min(1, samples[i]))
                    peak = max(peak, abs(sample))
                    pcm[i] = Int16((sample * 32767).rounded())
                }
                pendingFrames = count
            }
            let bytes = pendingFrames * 2 * MemoryLayout<Int16>.size
            let result = Darwin.write(fd, pcm, bytes)
            if result != bytes {
                if result == -1 && [EAGAIN, EWOULDBLOCK, EINTR].contains(errno) { return }
                failed.store(true, ordering: .relaxed)
                return
            }
            written += pendingFrames
            framesWritten += UInt64(pendingFrames)
            pendingFrames = 0
        }
    }
}

@MainActor
final class GroupMixer {
    private struct Slot {
        let source: AudioSource
        let capture: Capture
        let tap: AppAudioTap?
        let channel: MixChannel
    }

    private let renderer: MixRenderer
    private var slots: [String: Slot] = [:]
    private var errors: [String: String] = [:]
    private var configuration: [MixInput]?
    private var running = false

    var sampleRate: Int { MixRenderer.sampleRate }
    var failed: Bool { renderer.failed.load(ordering: .relaxed) }

    init(fd: Int32) throws { renderer = try MixRenderer(fd: fd) }

    func update(_ inputs: [MixInput]) {
        guard inputs != configuration else { return }
        configuration = inputs
        guard running else { return }
        reconcile(inputs)
    }

    func start() {
        guard !running else { return }
        running = true
        reconcile(configuration ?? [])
        renderer.start()
    }

    func stop() {
        guard running else { return }
        running = false
        renderer.stop()
        renderer.setChannels([:], gains: [:])
        for slot in slots.values { slot.capture.stop() }
        slots.removeAll()
        errors.removeAll()
    }

    func meter() -> (Float, [String: MixInputStatus]) {
        let (peak, signals) = renderer.meter()
        var states = errors.mapValues { MixInputStatus(error: $0) }
        for (id, _) in slots { states[id] = MixInputStatus(hasSignal: signals.contains(id)) }
        return (peak, states)
    }

    private func reconcile(_ inputs: [MixInput]) {
        let wanted = Dictionary(inputs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in Array(slots.keys) where slots[id]?.source != wanted[id]?.source {
            slots.removeValue(forKey: id)?.capture.stop()
        }
        errors = [:]
        var gains: [String: Float] = [:]
        for (id, input) in wanted {
            guard let source = input.source else {
                errors[id] = input.unavailable
                continue
            }
            if slots[id] == nil {
                do {
                    let ring = MixInputBuffer()
                    let (capture, tap) = try Capture.make(source, fd: nil, mixInput: ring)
                    try capture.start()
                    slots[id] = Slot(source: source, capture: capture, tap: tap,
                                     channel: MixChannel(ring: ring, inputRate: capture.sampleRate))
                } catch { errors[id] = error.localizedDescription }
            }
            gains[id] = input.muted || !input.gain.isFinite ? 0 : Float(max(0, min(100, input.gain))) / 100
        }
        renderer.setChannels(slots.mapValues(\.channel), gains: gains)
    }
}
