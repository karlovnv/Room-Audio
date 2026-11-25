import Combine
import CoreAudio
import Darwin
import Foundation
import OSLog
import SwiftUI
import Synchronization

private let audioCallback: AudioDeviceIOProc = { _, _, input, _, _, _, context in
    guard let context else { return noErr }
    let capture = Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue()
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard let first = buffers.first, let data = first.mData else { return noErr }
    let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
    if buffers.count == 1, first.mNumberChannels == 2 {
        capture.writeFrames(data.assumingMemoryBound(to: Float.self), right: nil, count: count / 2)
    } else if buffers.count == 2, first.mNumberChannels == 1, buffers[1].mNumberChannels == 1,
              let second = buffers[1].mData {
        capture.writeFrames(data.assumingMemoryBound(to: Float.self), right: second.assumingMemoryBound(to: Float.self),
                            count: min(count, Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.size))
    }
    return noErr
}

final class Capture {
    private let id: AudioObjectID
    private let fd: Int32?
    private let localOutput: LocalPlayback?
    private let pcm: UnsafeMutablePointer<Int16>
    private var callback: AudioDeviceIOProcID?
    let failed = Atomic<Bool>(false)
    let peak = Atomic<UInt32>(0)
    let sampleRate: Int

    init(id: AudioObjectID, fd: Int32?, tapFormat: AudioStreamBasicDescription? = nil,
         localOutput: LocalPlayback? = nil) throws {
        self.id = id
        self.fd = fd
        self.localOutput = localOutput
        var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                                  mScope: kAudioObjectPropertyScopeInput,
                                                  mElement: kAudioObjectPropertyElementMain)
        var format = tapFormat ?? AudioStreamBasicDescription()
        if tapFormat == nil {
            var size = UInt32(MemoryLayout.size(ofValue: format))
            try Self.check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, &format))
        }
        guard [44100.0, 48000.0].contains(format.mSampleRate), format.mChannelsPerFrame == 2,
              format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw StreamError("Требуется стереовход 44,1 или 48 кГц Float32.")
        }
        sampleRate = Int(format.mSampleRate)
        if let fd {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETNOSIGPIPE, 1) >= 0,
                  fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw StreamError("Не удалось открыть канал аудиопотока")
            }
        }
        pcm = .allocate(capacity: 256)
    }

    func start() throws {
        try Self.check(AudioDeviceCreateIOProcID(id, audioCallback, Unmanaged.passUnretained(self).toOpaque(), &callback))
        if let callback { try Self.check(AudioDeviceStart(id, callback)) }
    }

    func stop() {
        guard let callback else { return }
        AudioDeviceStop(id, callback)
        AudioDeviceDestroyIOProcID(id, callback)
        self.callback = nil
    }

    deinit {
        stop()
        pcm.deallocate()
    }

    fileprivate func writeFrames(_ first: UnsafePointer<Float>, right: UnsafePointer<Float>?, count: Int) {
        var offset = 0
        var maximum: Float = 0
        while offset < count {
            // Up to 512 bytes, the guaranteed atomic POSIX pipe-write size.
            let length = min(128, count - offset)
            for index in 0..<length {
                let frame = offset + index
                for channel in 0..<2 {
                    let sample: Float
                    if let right { sample = channel == 0 ? first[frame] : right[frame] }
                    else { sample = first[2 * frame + channel] }
                    let limited = sample.isFinite ? max(-1, min(1, sample)) : 0
                    maximum = max(maximum, abs(limited))
                    pcm[2 * index + channel] = Int16((limited * 32767).rounded())
                }
            }
            let bytes = 2 * length * MemoryLayout<Int16>.size
            if let fd, Darwin.write(fd, pcm, bytes) != bytes {
                failed.store(true, ordering: .relaxed)
                return
            }
            if let localOutput, !localOutput.enqueue(pcm, frames: length) {
                failed.store(true, ordering: .relaxed)
                return
            }
            offset += length
        }
        var previous = peak.load(ordering: .relaxed)
        while previous < maximum.bitPattern {
            let update = peak.compareExchange(expected: previous, desired: maximum.bitPattern, ordering: .relaxed)
            if update.exchanged { break }
            previous = update.original
        }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw StreamError("Core Audio: \(status)") }
    }
}

struct StreamError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class Streaming: ObservableObject {
    private let logger = Logger(subsystem: "local.roomaudio.discovery", category: "AirPlay")
    @Published private(set) var active = false
    @Published private(set) var stopping = false
    @Published private(set) var isTransmitting = false
    private(set) var scheduledStart: String?
    @Published private(set) var status = "Готово к запуску"
    @Published private(set) var receivers: [String: String] = [:]
    @Published private(set) var skippedReceivers: [String: String] = [:]
    @Published private(set) var receiversBlockedByTV: Set<String> = []
    private(set) var failedReceivers: Set<String> = []
    @Published private(set) var signalLevel: Float = 0
    @Published private(set) var hasRecentSignal = false
    private var lastSignalAt: ContinuousClock.Instant?
    private var supervisor: Process?
    private var capture: Capture?
    private var appTap: AppAudioTap?
    private var bluetooth: LocalPlayback?
    private var bluetoothName: String?
    private var audio: Pipe?
    private var statusRead: FileHandle?
    private var volumesFile: URL?
    private var joinsFile: URL?
    private var joinRequests: [String: String] = [:]
    private var currentVolumes: [String: Int] = [:]

    private static func awaitingPlayback(_ status: String) -> Bool {
        status == "Подключение" || status == "Синхронизация"
    }

    private static func connectionActive(_ active: Bool, _ stopping: Bool, _ transmitting: Bool,
                                         _ receivers: [String: String]) -> Bool {
        active && !stopping && (!transmitting || receivers.values.contains(where: awaitingPlayback))
    }

    var isConnecting: Bool { Self.connectionActive(active, stopping, isTransmitting, receivers) }

    var connectionUpdates: AnyPublisher<Bool, Never> {
        $active.combineLatest($stopping, $isTransmitting, $receivers)
            .map { active, stopping, transmitting, receivers in
                Self.connectionActive(active, stopping, transmitting, receivers)
            }
            .removeDuplicates()
            .eraseToAnyPublisher()
    }

    func isConnecting(to receiver: String) -> Bool {
        guard active, !stopping, let state = receivers[receiver] else { return false }
        return Self.awaitingPlayback(state) || (!isTransmitting && (state == "Ожидание" || state == "Передача"))
    }

    func prepareReceivers(_ names: [String]) {
        receivers = Dictionary(uniqueKeysWithValues: names.map { ($0, "Ожидание") })
        skippedReceivers = [:]
        receiversBlockedByTV = []
        failedReceivers = []
    }

    func start(input: AudioObjectID, names: [String], volumes: [String: Int]) {
        start(source: .device(input), names: names, volumes: volumes)
    }

    func start(source: AudioSource, names: [String], volumes: [String: Int], sharedClockAddress: String? = nil,
               protectSonos: Bool = false, overrideTV: Set<String> = []) {
        guard !active, !names.isEmpty else { return }
        prepareReceivers(names)
        do {
            guard let script = Bundle.main.url(forResource: "stream", withExtension: "py"),
                  let transport = Bundle.main.url(forResource: "cliairplay", withExtension: nil) else {
                throw StreamError("Компоненты AirPlay отсутствуют в приложении")
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("room-audio-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            var started = false
            defer { if !started { try? FileManager.default.removeItem(at: folder) } }
            let log = folder.appendingPathComponent("status")
            let volumeFile = folder.appendingPathComponent("volumes.json")
            let joinFile = folder.appendingPathComponent("joins.json")
            try Data("{}".utf8).write(to: joinFile)
            try JSONEncoder().encode(volumes).write(to: volumeFile, options: .atomic)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let sink = try FileHandle(forWritingTo: log)
            let statusSource = try FileHandle(forReadingFrom: log)
            let audio = Pipe()
            let (capture, tap) = try makeCapture(source, fd: audio.fileHandleForWriting.fileDescriptor)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            var arguments = [script.path, "--transport", transport.path, "--volumes", volumeFile.path,
                             "--sample-rate", String(capture.sampleRate)]
            if let sharedClockAddress { arguments += ["--use-shared-clock", "--clock-address", sharedClockAddress] }
            if protectSonos { arguments.append("--protect-sonos") }
            if protectSonos { arguments += ["--tv-join-file", joinFile.path] }
            for receiver in overrideTV.sorted() { arguments += ["--override-tv", receiver] }
            process.arguments = arguments + ["--"] + names
            process.standardInput = audio
            process.standardOutput = sink
            process.standardError = sink
            try process.run()
            started = true
            try? sink.close()
            self.supervisor = process
            self.capture = capture
            self.appTap = tap
            self.audio = audio
            self.statusRead = statusSource
            self.volumesFile = volumeFile
            self.joinsFile = joinFile
            self.currentVolumes = volumes
            active = true
            stopping = false
            status = "Подготовка AirPlay…"
            Task { await monitor(process: process, folder: folder) }
        } catch {
            status = error.localizedDescription
        }
    }

    func start(source: AudioSource, output: LocalOutput, volume: Int) {
        guard !active else { return }
        receivers = [output.name: "Подключение"]
        do {
            let player = try LocalPlayback(device: output)
            player.level.store(volume, ordering: .relaxed)
            let (capture, tap) = try makeCapture(source, fd: nil, localOutput: player)
            try player.start(inputRate: capture.sampleRate)
            try capture.start()
            self.capture = capture
            self.appTap = tap
            bluetooth = player
            bluetoothName = output.name
            active = true
            isTransmitting = true
            receivers[output.name] = "Передача"
            status = "Передача по Bluetooth"
            Task { await monitorBluetooth(output, player: player) }
        } catch {
            receivers[output.name] = "Отключено"
            status = error.localizedDescription
        }
    }

    var bluetoothRenderedFrames: Int {
        bluetooth?.renderedNonSilentFrames.load(ordering: .relaxed) ?? 0
    }

    private func makeCapture(_ source: AudioSource, fd: Int32?, localOutput: LocalPlayback? = nil) throws -> (Capture, AppAudioTap?) {
        switch source {
        case .device(let id):
            return (try Capture(id: id, fd: fd, localOutput: localOutput), nil)
        case .application(let ids, let playLocally):
            let tap = try AppAudioTap(processes: ids, playLocally: playLocally)
            return (try Capture(id: tap.device, fd: fd, tapFormat: tap.format, localOutput: localOutput), tap)
        }
    }

    private func monitorBluetooth(_ output: LocalOutput, player: LocalPlayback) async {
        var ticks = 0
        while bluetooth === player {
            updateMeter()
            if capture?.failed.load(ordering: .relaxed) == true {
                finishBluetooth(error: "Переполнился буфер Bluetooth.")
                break
            }
            if ticks % 10 == 0, let connected = try? LocalOutput.list(), !connected.contains(output) {
                finishBluetooth(error: "Bluetooth-устройство отключилось.")
                break
            }
            ticks += 1
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func finishBluetooth(error: String? = nil) {
        capture?.stop()
        bluetooth?.stop()
        capture = nil
        appTap = nil
        bluetooth = nil
        if let bluetoothName { receivers[bluetoothName] = error == nil ? "Остановлено" : "Отключено" }
        bluetoothName = nil
        clearSignal()
        status = error ?? "Передача остановлена"
        active = false
        isTransmitting = false
    }

    private func updateMeter() {
        if let capture {
            let peak = Float(bitPattern: capture.peak.exchange(0, ordering: .relaxed))
            signalLevel = max(peak, signalLevel * 0.65)
            let now = ContinuousClock.now
            if peak >= 0.001 { lastSignalAt = now }
            let recent = lastSignalAt.map { $0.duration(to: now) < .seconds(2) } ?? false
            if recent != hasRecentSignal { hasRecentSignal = recent }
        }
    }

    private func clearSignal() {
        signalLevel = 0
        hasRecentSignal = false
        lastSignalAt = nil
    }

    func setVolume(_ volume: Int, for receiver: String) {
        if bluetoothName == receiver, let bluetooth {
            bluetooth.level.store(volume, ordering: .relaxed)
            return
        }
        setVolumes([receiver: volume])
    }

    func setVolumes(_ changes: [String: Int]) {
        guard let volumesFile, !stopping else { return }
        var updated = currentVolumes
        for (receiver, volume) in changes where updated[receiver] != nil { updated[receiver] = volume }
        guard updated != currentVolumes else { return }
        do {
            try JSONEncoder().encode(updated).write(to: volumesFile, options: .atomic)
            currentVolumes = updated
        } catch { status = "Не удалось задать громкость: \(error.localizedDescription)" }
    }

    func stopReceiver(_ receiver: String) {
        guard let volumesFile, currentVolumes[receiver] != nil, !stopping else { return }
        if currentVolumes.count == 1 { stop(); return }
        var remaining = currentVolumes
        remaining.removeValue(forKey: receiver)
        do {
            try JSONEncoder().encode(remaining).write(to: volumesFile, options: .atomic)
            currentVolumes = remaining
            receivers[receiver] = "Остановка…"
        } catch {
            status = "Не удалось остановить выход: \(error.localizedDescription)"
        }
    }

    func joinTVReceiver(_ receiver: String, volume: Int) -> Bool {
        guard receiversBlockedByTV.contains(receiver) else { return false }
        return requestJoin(receiver, volume: volume, token: UUID().uuidString)
    }

    func rejoinFailedReceiver(_ receiver: String, volume: Int) {
        guard failedReceivers.contains(receiver) else { return }
        _ = requestJoin(receiver, volume: volume, token: "recover:\(UUID())")
    }

    private func requestJoin(_ receiver: String, volume: Int, token: String) -> Bool {
        guard isTransmitting, !stopping, let volumesFile, let joinsFile else { return false }
        do {
            var requests = joinRequests
            requests[receiver] = token
            var volumes = currentVolumes
            volumes[receiver] = volume
            try JSONEncoder().encode(volumes).write(to: volumesFile, options: .atomic)
            try JSONEncoder().encode(requests).write(to: joinsFile, options: .atomic)
            joinRequests = requests
            currentVolumes = volumes
            receiversBlockedByTV.remove(receiver)
            failedReceivers.remove(receiver)
            skippedReceivers.removeValue(forKey: receiver)
            receivers[receiver] = "Подключение"
            return true
        } catch {
            status = "Не удалось подключить выход: \(error.localizedDescription)"
            return false
        }
    }

    func stop() {
        guard active, !stopping else { return }
        if bluetooth != nil {
            finishBluetooth()
            return
        }
        stopping = true
        status = "Остановка…"
        shutdown()
    }

    private func shutdown() {
        capture?.stop()
        try? audio?.fileHandleForWriting.close()
        if let supervisor, supervisor.isRunning { supervisor.terminate() }
    }

    private func monitor(process: Process, folder: URL) async {
        var pending = Data()
        var terminalError: String?
        while true {
            updateMeter()
            if let data = try? statusRead?.readToEnd() { pending.append(data) }
            while let newline = pending.firstIndex(of: 10) {
                let line = pending[..<newline]
                pending.removeSubrange(...newline)
                guard let event = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: String],
                      let kind = event["status"] else { continue }
                if kind == "error" { terminalError = event["message"] ?? "Ошибка AirPlay" }
                guard !stopping else { continue }
                switch kind {
                case "authorization": status = "Подтверди запуск PTP в окне macOS"
                case "capture":
                    do {
                        try capture?.start()
                        status = "Синхронизация AirPlay…"
                    } catch {
                        terminalError = error.localizedDescription
                        shutdown()
                    }
                case "streaming":
                    isTransmitting = true
                    scheduledStart = event["anchor"]
                    status = "Передача звука"
                case "receiver_stopped":
                    if let name = event["receiver"] { receivers[name] = "Остановлено" }
                case "receiver_retry":
                    if let name = event["receiver"] {
                        logger.notice("\(name, privacy: .public): повтор подключения AirPlay без перезапуска PTP")
                    }
                case "receiver_skipped", "receiver_failed":
                    if let name = event["receiver"] {
                        if kind == "receiver_failed" {
                            failedReceivers.insert(name)
                            let reason = event["message"] ?? "Ошибка AirPlay"
                            let diagnostic = event["diagnostic"] ?? ""
                            logger.error("\(name, privacy: .public): \(reason, privacy: .public) \(diagnostic, privacy: .public)")
                        }
                        if event["category"] == "tv" { receiversBlockedByTV.insert(name) }
                        skippedReceivers[name] = event["message"] ?? "недоступна"
                        currentVolumes.removeValue(forKey: name)
                        receivers[name] = "Остановлено"
                    }
                case "connecting", "connected", "playing":
                    if let name = event["receiver"] {
                        receivers[name] = switch kind {
                        case "connecting": "Подключение"
                        case "connected": "Синхронизация"
                        default: "Передача"
                        }
                    }
                default: break
                }
            }
            if capture?.failed.load(ordering: .relaxed) == true && terminalError == nil && !stopping {
                terminalError = "Передатчик не успевает принять аудиопоток"
                shutdown()
            }
            // Process exit is joined after one more read to collect its final event.
            if !process.isRunning {
                if let final = try? statusRead?.readToEnd(), !final.isEmpty {
                    pending.append(final)
                    continue
                }
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        capture?.stop()
        try? statusRead?.close()
        try? audio?.fileHandleForWriting.close()
        try? FileManager.default.removeItem(at: folder)
        statusRead = nil
        capture = nil
        appTap = nil
        clearSignal()
        audio = nil
        supervisor = nil
        volumesFile = nil
        joinsFile = nil
        joinRequests = [:]
        currentVolumes = [:]
        let failure = terminalError ?? ((process.terminationStatus == 0 || stopping) ? nil : "AirPlay завершился с ошибкой")
        status = failure ?? "Передача остановлена"
        for name in Array(receivers.keys) { receivers[name] = failure == nil ? "Остановлено" : "Отключено" }
        active = false
        stopping = false
        isTransmitting = false
        scheduledStart = nil
    }
}
