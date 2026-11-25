import AppKit
import CoreAudio
import Synchronization

enum AudioSource: Equatable {
    case device(AudioObjectID)
    case application([AudioObjectID], playLocally: Bool)
    indirect case mix([MixInput])
}

@MainActor
struct RunningAudioApp: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let bundleID: String?
    var hasActiveOutput = false
    var activeAudioObjects: [AudioObjectID] = []
    var audioProcessObjects: [AudioObjectID] = []

    static func list() -> [Self] {
        let clients = (try? ProcessAudioClient.snapshot()) ?? []
        return NSWorkspace.shared.runningApplications.compactMap { app -> Self? in
            guard app.activationPolicy == .regular, !app.isTerminated,
                  app.processIdentifier != getpid(), let name = app.localizedName else { return nil }
            var result = Self(id: app.processIdentifier, name: name, bundleID: app.bundleIdentifier)
            let matching = clients.filter(result.includes)
            result.audioProcessObjects = matching.map(\.object).sorted()
            result.activeAudioObjects = matching.filter(\.outputActive).map(\.object).sorted()
            result.hasActiveOutput = !result.activeAudioObjects.isEmpty
            return result
        }.sorted {
            if $0.hasActiveOutput != $1.hasActiveOutput { return $0.hasActiveOutput }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func audioObjects() throws -> [AudioObjectID] {
        let result = try ProcessAudioClient.snapshot().filter(includes).map(\.object)
        guard !result.isEmpty else { throw StreamError("Play audio in \(name) and try again.") }
        return result
    }

    private func includes(_ client: ProcessAudioClient) -> Bool {
        if client.pid == id { return true }
        guard let bundleID, let processBundle = client.bundleID else { return false }
        return processBundle == bundleID || processBundle.hasPrefix(bundleID + ".")
    }
}

private let signalCallback: AudioDeviceIOProc = { _, _, input, _, _, _, context in
    guard let context else { return noErr }
    let meter = Unmanaged<AppSignalMeter>.fromOpaque(context).takeUnretainedValue()
    for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
        guard let data = buffer.mData else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        for index in 0..<count where abs(samples[index]) >= 0.001 {
            meter.signal.store(true, ordering: .relaxed)
            return noErr
        }
    }
    return noErr
}

final class AppSignalMeter {
    private let tap: AppAudioTap
    private var callback: AudioDeviceIOProcID?
    fileprivate let signal = Atomic<Bool>(false)

    init(processes: [AudioObjectID]) throws {
        tap = try AppAudioTap(processes: processes, playLocally: true)
        guard tap.format.mFormatID == kAudioFormatLinearPCM, tap.format.mBitsPerChannel == 32,
              tap.format.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            throw StreamError("Could not read the app’s audio level.")
        }
        try tapCheck(AudioDeviceCreateIOProcID(tap.device, signalCallback, Unmanaged.passUnretained(self).toOpaque(), &callback))
        guard let callback else { throw StreamError("Could not start the app’s audio meter.") }
        do { try tapCheck(AudioDeviceStart(tap.device, callback)) }
        catch {
            AudioDeviceDestroyIOProcID(tap.device, callback)
            self.callback = nil
            throw error
        }
    }

    func takeSignal() -> Bool {
        signal.exchange(false, ordering: .relaxed)
    }

    deinit {
        if let callback {
            AudioDeviceStop(tap.device, callback)
            AudioDeviceDestroyIOProcID(tap.device, callback)
        }
    }
}

struct ProcessAudioClient {
    let object: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    let outputActive: Bool

    static func snapshot() throws -> [Self] {
        var property = tapAddress(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        let stride = MemoryLayout<AudioObjectID>.size
        try tapCheck(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size))
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / stride)
        if !objects.isEmpty {
            try objects.withUnsafeMutableBytes {
                try tapCheck(AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!))
            }
        }
        return objects.prefix(Int(size) / stride).compactMap { object in
            var pid: pid_t = 0
            var property = tapAddress(kAudioProcessPropertyPID)
            var size = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &pid) == noErr else { return nil }
            property = tapAddress(kAudioProcessPropertyBundleID)
            var value: Unmanaged<CFString>?
            size = UInt32(MemoryLayout.size(ofValue: value))
            let bundleStatus = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value)
            let bundle = bundleStatus == noErr ? value.map { $0.takeRetainedValue() as String } : nil
            property = tapAddress(kAudioProcessPropertyIsRunningOutput)
            var active: UInt32 = 0
            size = UInt32(MemoryLayout.size(ofValue: active))
            let activeStatus = AudioObjectGetPropertyData(object, &property, 0, nil, &size, &active)
            return Self(object: object, pid: pid, bundleID: bundle, outputActive: activeStatus == noErr && active != 0)
        }
    }
}

final class AppAudioTap {
    let device: AudioObjectID
    let format: AudioStreamBasicDescription
    private let tap: AudioObjectID

    init(processes: [AudioObjectID], playLocally: Bool) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "Room Audio"
        description.isPrivate = true
        description.muteBehavior = playLocally ? .unmuted : .mutedWhenTapped
        var tap: AudioObjectID = 0
        try tapCheck(AudioHardwareCreateProcessTap(description, &tap))
        do {
            var property = tapAddress(kAudioTapPropertyFormat)
            var format = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout.size(ofValue: format))
            try tapCheck(AudioObjectGetPropertyData(tap, &property, 0, nil, &size, &format))
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Room Audio Capture",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]]
            ]
            var device: AudioObjectID = 0
            try tapCheck(AudioHardwareCreateAggregateDevice(config as CFDictionary, &device))
            self.tap = tap
            self.device = device
            self.format = format
        } catch {
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }
    }

    deinit {
        AudioHardwareDestroyAggregateDevice(device)
        AudioHardwareDestroyProcessTap(tap)
    }
}

private func tapAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    .init(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}

private func tapCheck(_ status: OSStatus) throws {
    if status != noErr { throw AudioCaptureError(status: status, operation: "Could not capture app audio") }
}
