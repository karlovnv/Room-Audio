import AppKit
import CoreAudio
import Network
import SwiftUI

struct AudioInput: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
    let uid: String
    var transportType: UInt32 = 0

    var symbol: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: "mic"
        case kAudioDeviceTransportTypeUSB: "cable.connector"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        default: "waveform"
        }
    }

    static func list() throws -> [Self] {
        var property = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size))
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard !ids.isEmpty else { return [] }
        try ids.withUnsafeMutableBytes {
            try check(AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!))
        }
        return ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).compactMap { id in
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { return nil }
            guard let name = string(id, kAudioObjectPropertyName),
                  let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            var transportProperty = address(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(id, &transportProperty, 0, nil, &transportSize, &transport)
            return Self(id: id, name: name, uid: uid, transportType: transport)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var property = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value) == noErr else { return nil }
        return value.map { $0.takeRetainedValue() as String }
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        .init(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

struct Receiver: Identifiable {
    struct ID: Hashable, Codable {
        let name: String
        let domain: String
    }
    let id: ID
    var name: String { id.name }
    let model: String?

    static func outputSymbol(name: String, model: String?) -> String {
        let name = name.lowercased()
        let model = model?.lowercased() ?? ""
        if model.hasPrefix("macbook") || name.contains("macbook") { return "laptopcomputer" }
        if model.hasPrefix("mac") || model.hasPrefix("imac") ||
            ["imac", "mac mini", "mac studio", "mac pro"].contains(where: name.contains) {
            return "desktopcomputer"
        }
        if model.hasPrefix("appletv") || ["apple tv", "webos", "android tv", "google tv"].contains(where: name.contains) ||
            name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains("tv") {
            return "tv"
        }
        return "hifispeaker.fill"
    }
}

@MainActor
final class Discovery: ObservableObject {
    @Published private(set) var receivers: [Receiver] = []
    @Published private(set) var localReceiverIDs: Set<Receiver.ID> = []
    @Published private(set) var status = "Searching for devices…"
    private var browser: NWBrowser?

    func outputSymbol(for id: Receiver.ID) -> String {
        Receiver.outputSymbol(name: id.name, model: receivers.first { $0.id == id }?.model)
    }

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_airplay._tcp", domain: "local."), using: .tcp)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            MainActor.assumeIsolated {
                guard let self, self.browser === browser else { return }
                switch state {
                case .ready: self.status = "Searching the local network"
                case .waiting(let error): self.status = "Waiting for the network: \(error)"
                case .failed(let error): self.status = "Discovery failed: \(error)"
                case .cancelled: self.status = "Discovery stopped"
                default: break
                }
            }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            MainActor.assumeIsolated {
                guard let self, self.browser === browser else { return }
                var devices: [Receiver.ID: Receiver] = [:]
                var loopbackIDs = Set<Receiver.ID>()
                for result in results {
                    guard case let .service(name, _, domain, interface) = result.endpoint else { continue }
                    let id = Receiver.ID(name: name, domain: domain)
                    if interface?.type == .loopback || result.interfaces.contains(where: { $0.type == .loopback }) {
                        loopbackIDs.insert(id)
                    }
                    var model: String?
                    if case let .bonjour(txt) = result.metadata {
                        model = txt["model"]
                    }
                    if devices[id]?.model == nil {
                        devices[id] = Receiver(id: id, model: model)
                    }
                }
                let localIDs = self.localReceiverIDs.subtracting(devices.keys).union(loopbackIDs)
                if localIDs != self.localReceiverIDs { self.localReceiverIDs = localIDs }
                self.receivers = devices.values.sorted {
                    ($0.name.localizedLowercase, $0.id.domain) < ($1.name.localizedLowercase, $1.id.domain)
                }
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        receivers = []
    }
}

struct RoomAudioView: View {
    @StateObject private var discovery = Discovery()
    @StateObject private var streaming = Streaming()
    @State private var inputs: [AudioInput] = []
    @State private var input: AudioObjectID?
    @State private var useApplication = false
    @State private var applications: [RunningAudioApp] = []
    @State private var application: pid_t?
    @State private var playLocally = false
    @State private var liveSourceName: String?
    @State private var inputError: String?
    @State private var selection: Set<Receiver.ID> = []
    @State private var bluetoothOutputs: [LocalOutput] = []
    @State private var bluetoothSelection: AudioObjectID?
    @State private var bluetoothVolume = 45.0
    @State private var didPreselect = false
    @State private var volumes: [Receiver.ID: Int] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Room Audio").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 10) {
                if streaming.active, let liveSourceName {
                    LabeledContent("Current Source", value: liveSourceName)
                }
                Picker(streaming.active ? "Source for Next Stream" : "Source", selection: $useApplication) {
                    Text("Audio Device").tag(false)
                    Text("App").tag(true)
                }.pickerStyle(.segmented)
                if useApplication {
                    HStack {
                        Picker("App", selection: $application) {
                            Text("Select an app").tag(nil as pid_t?)
                            ForEach(applications) { app in
                                Text(app.hasActiveOutput ? "\(app.name) · output active" : app.name)
                                    .tag(Optional(app.id))
                            }
                        }
                        Button("Refresh", action: refreshApplications)
                    }
                    Toggle("Also Play on This Mac", isOn: $playLocally).toggleStyle(.checkbox)
                } else {
                    HStack {
                        Picker("Audio Input", selection: $input) {
                            Text("Select a device").tag(nil as AudioObjectID?)
                            ForEach(inputs) { device in Text(device.name).tag(Optional(device.id)) }
                        }
                        Button("Refresh Inputs", action: refreshInputs)
                    }
                }
                if streaming.active {
                    Text("The selection takes effect the next time you start streaming.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let inputError { Text(inputError).foregroundStyle(.secondary) }
            HStack {
                let peak = streaming.signalLevel
                let db = peak > 0 ? 20 * log10(Double(peak)) : -Double.infinity
                Text("Input Signal")
                ProgressView(value: min(1, max(0, (db + 60) / 60)))
                    .accessibilityLabel("Input signal level")
                Text(db > -60 ? "\(Int(db.rounded())) dBFS" : "Silence")
                    .monospacedDigit().frame(width: 72, alignment: .trailing)
            }.font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Outputs").font(.headline)
                Text(discovery.status).font(.caption).foregroundStyle(.secondary)
            }
            List {
                Section("Bluetooth") {
                    if bluetoothOutputs.isEmpty {
                        Text("Connect a device in your Mac’s Bluetooth settings.").foregroundStyle(.secondary)
                    }
                    ForEach(bluetoothOutputs) { output in
                        VStack(alignment: .leading) {
                            Toggle(isOn: Binding(
                                get: { bluetoothSelection == output.id },
                                set: { enabled in
                                    bluetoothSelection = enabled ? output.id : nil
                                    if enabled { selection.removeAll() }
                                }
                            )) {
                                HStack {
                                    Label(output.name, systemImage: LocalOutput.symbol)
                                    Spacer()
                                    if let status = streaming.receivers[output.name] {
                                        Text(status).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }.toggleStyle(.checkbox).disabled(streaming.active)
                            if bluetoothSelection == output.id {
                                HStack {
                                    Slider(value: $bluetoothVolume, in: 0...100, step: 1) { Text("Bluetooth Volume") }
                                    Text("\(Int(bluetoothVolume))%").monospacedDigit()
                                }.onChange(of: bluetoothVolume) { _, value in
                                    streaming.setVolume(Int(value), for: output.name)
                                }
                            }
                        }
                    }
                }
                Section("AirPlay") {
                if discovery.receivers.isEmpty {
                    Text("No devices found yet").foregroundStyle(.secondary)
                }
                ForEach(discovery.receivers) { receiver in
                    VStack(alignment: .leading) {
                    Toggle(isOn: Binding(
                        get: { selection.contains(receiver.id) },
                        set: { selected in
                            if selected {
                                bluetoothSelection = nil
                                selection.insert(receiver.id)
                            }
                            else { selection.remove(receiver.id) }
                        }
                    )) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(receiver.name, systemImage: discovery.outputSymbol(for: receiver.id))
                                if let model = receiver.model {
                                    Text(model).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let status = streaming.receivers[receiver.name] {
                                Text(status).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.toggleStyle(.checkbox).disabled(streaming.active)
                    if selection.contains(receiver.id) {
                        HStack {
                            Slider(value: Binding(
                                get: { Double(volumes[receiver.id] ?? 45) },
                                set: {
                                    let volume = Int($0)
                                    volumes[receiver.id] = volume
                                    streaming.setVolume(volume, for: receiver.name)
                                }
                            ), in: 0...100, step: 1) { Text("Volume \(receiver.name)") }
                            Text("\(volumes[receiver.id] ?? 45)%").monospacedDigit()
                        }.disabled(streaming.stopping)
                    }
                    }
                }
                }
            }
            .listStyle(.bordered)
            HStack {
                Text(streaming.status).foregroundStyle(.secondary)
                Spacer()
                if streaming.active {
                    Button("Stop", action: streaming.stop).disabled(streaming.stopping)
                } else {
                    Button("Start") {
                        let selected = discovery.receivers.filter { selection.contains($0.id) }
                        let levels = Dictionary(selected.map { ($0.name, volumes[$0.id] ?? 45) }, uniquingKeysWith: { first, _ in first })
                        do {
                            let source: AudioSource
                            let name: String
                            if useApplication, let app = applications.first(where: { $0.id == application }) {
                                source = .application(try app.audioObjects(), playLocally: playLocally)
                                name = app.name
                            } else if !useApplication, let input {
                                source = .device(input)
                                name = inputs.first(where: { $0.id == input })?.name ?? "Audio Device"
                            } else { return }
                            inputError = nil
                            if let bluetoothSelection, let output = bluetoothOutputs.first(where: { $0.id == bluetoothSelection }) {
                                streaming.start(source: source, output: output, volume: Int(bluetoothVolume))
                            } else {
                                streaming.start(source: source, names: levels.keys.sorted(), volumes: levels)
                            }
                            if streaming.active { liveSourceName = name }
                        } catch { inputError = error.localizedDescription }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((useApplication ? application == nil : input == nil) || (selection.isEmpty && bluetoothSelection == nil))
                }
            }.font(.callout)
        }
        .padding(24)
        .frame(minWidth: 490, minHeight: 380)
        .task {
            refreshInputs()
            discovery.start()
            if CommandLine.arguments.contains("--verify-discovery") {
                await verifyDiscovery()
            } else if CommandLine.arguments.contains("--verify-capture") {
                await verifyCapture()
            } else if let index = CommandLine.arguments.firstIndex(of: "--verify-live"),
                      CommandLine.arguments.count == index + 3 {
                await verifyLive(feeder: CommandLine.arguments[index + 1], clip: CommandLine.arguments[index + 2])
            } else if let index = CommandLine.arguments.firstIndex(of: "--verify-app-source"),
                      CommandLine.arguments.count == index + 3 {
                await verifyApplication(feeder: CommandLine.arguments[index + 1], clip: CommandLine.arguments[index + 2])
            } else if let index = CommandLine.arguments.firstIndex(of: "--verify-bluetooth"),
                      CommandLine.arguments.count == index + 3 {
                await verifyBluetooth(feeder: CommandLine.arguments[index + 1], clip: CommandLine.arguments[index + 2])
            }
        }
        .onChange(of: useApplication) { _, enabled in
            inputError = nil
            if !enabled { refreshInputs() }
        }
        .task(id: useApplication) {
            guard useApplication else { return }
            while !Task.isCancelled {
                refreshApplications()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .task {
            while !Task.isCancelled {
                if let outputs = try? LocalOutput.list(), outputs != bluetoothOutputs {
                    bluetoothOutputs = outputs
                    if !streaming.active && !outputs.contains(where: { $0.id == bluetoothSelection }) {
                        bluetoothSelection = nil
                    }
                }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .onChange(of: discovery.receivers.map(\.id)) { _, ids in
            selection.formIntersection(ids)
            let preferred = ids.filter { ["Kitchen", "Living Room"].contains($0.name) }
            if !didPreselect && !streaming.active && preferred.count == 2 {
                if selection.isEmpty && bluetoothSelection == nil { selection.formUnion(preferred) }
                didPreselect = true
            }
        }
        .onChange(of: streaming.active) { _, active in
            if !active && !bluetoothOutputs.contains(where: { $0.id == bluetoothSelection }) {
                bluetoothSelection = nil
            }
        }
        .onDisappear {
            streaming.stop()
            discovery.stop()
        }
    }

    private func refreshInputs() {
        do {
            inputs = try AudioInput.list()
            inputError = nil
            if !inputs.contains(where: { $0.id == input }) {
                input = inputs.first { $0.name == "BlackHole 2ch" }?.id
            }
        } catch {
            inputError = "Could not list audio inputs: \(error.localizedDescription)"
        }
    }

    private func refreshApplications() {
        let updated = RunningAudioApp.list()
        if applications != updated { applications = updated }
        if !updated.contains(where: { $0.id == application }) { application = nil }
    }

    private func verifyDiscovery() async {
        let expected: Set<String> = ["Kitchen", "Living Room"]
        for _ in 0..<40 {
            let names = Set(discovery.receivers.map(\.name))
            if expected.isSubset(of: names) { break }
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return }
        }
        let names = Set(discovery.receivers.map(\.name))
        let selectedInput = inputs.first { $0.id == input }?.name
        print("Inputs: \(inputs.map(\.name).joined(separator: ", "))")
        print("Selected input: \(selectedInput ?? "none")")
        print("Receivers: \(names.sorted().joined(separator: ", "))")
        print("Discovery: \(discovery.status)")
        discovery.stop()
        exit(expected.isSubset(of: names) && selectedInput == "BlackHole 2ch" ? 0 : 1)
    }

    private func verifyCapture() async {
        do {
            guard let device = inputs.first(where: { $0.name == "BlackHole 2ch" }) else {
                throw StreamError("BlackHole 2ch is absent")
            }
            let pipe = Pipe()
            let read = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(read, F_GETFL)
            guard flags >= 0, fcntl(read, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw StreamError("Cannot set capture verifier pipe to nonblocking")
            }
            let capture = try Capture(id: device.id, fd: pipe.fileHandleForWriting.fileDescriptor)
            try capture.start()
            print("CAPTURE_READY")
            fflush(nil)
            var buffer = [Int16](repeating: 0, count: 4096)
            var peak = [Int](repeating: 0, count: 2)
            var samples = 0
            let deadline = ContinuousClock().now + .seconds(4)
            while ContinuousClock().now < deadline {
                let bytes = buffer.withUnsafeMutableBytes { Darwin.read(read, $0.baseAddress, $0.count) }
                if bytes > 0 {
                    for sample in buffer.prefix(bytes / 2) {
                        peak[samples % 2] = max(peak[samples % 2], abs(Int(sample)))
                        samples += 1
                    }
                } else {
                    try await Task.sleep(for: .milliseconds(4))
                }
            }
            capture.stop()
            print("PCM16 stereo frames=\(samples / 2) peaks=\(peak) dropped=\(capture.failed.load(ordering: .relaxed))")
            guard samples > 300000, peak.allSatisfy({ $0 > 10 }), !capture.failed.load(ordering: .relaxed) else {
                throw StreamError("PCM16 test did not receive clean stereo audio")
            }
            exit(0)
        } catch {
            print(error.localizedDescription)
            exit(1)
        }
    }

    private func verifyLive(feeder: String, clip: String) async {
        let names = ["Kitchen", "Living Room"]
        var success = false
        do {
            for _ in 0..<40 {
                if Set(names).isSubset(of: Set(discovery.receivers.map(\.name))) { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard Set(names).isSubset(of: Set(discovery.receivers.map(\.name))), let input,
                  inputs.contains(where: { $0.id == input && $0.name == "BlackHole 2ch" }) else {
                throw StreamError("BlackHole or a target receiver is missing")
            }
            streaming.start(input: input, names: names, volumes: ["Kitchen": 45, "Living Room": 45])
            let deadline = ContinuousClock().now + .seconds(150)
            while streaming.active && !streaming.isTransmitting && ContinuousClock().now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard streaming.active, streaming.isTransmitting else { throw StreamError(streaming.status) }
            print("LISTEN_IN_ABOUT_10_SECONDS")
            fflush(nil)
            // The stream already carries silence. Feed music after a short pause
            // so the existing roughly seven seconds of AirPlay buffering count toward preparation.
            try await Task.sleep(for: .seconds(4))
            let source = Process()
            source.executableURL = URL(fileURLWithPath: feeder)
            source.arguments = [clip]
            try source.run()
            while source.isRunning { try await Task.sleep(for: .milliseconds(100)) }
            guard source.terminationStatus == 0 else { throw StreamError("BlackHole player failed") }
            try await Task.sleep(for: .seconds(9))
            guard streaming.active, streaming.isTransmitting else { throw StreamError(streaming.status) }
            print("ROOM_AUDIO_BOTH_SESSIONS_ACTIVE")
            success = true
        } catch {
            print("LIVE_TEST_ERROR: \(error.localizedDescription)")
        }
        streaming.stop()
        let shutdown = ContinuousClock().now + .seconds(18)
        while streaming.active && ContinuousClock().now < shutdown {
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("ROOM_AUDIO_STOP: \(streaming.status)")
        exit(success && !streaming.active && streaming.status == "Streaming stopped" ? 0 : 1)
    }

    private func verifyApplication(feeder: String, clip: String) async {
        let names = ["Kitchen", "Living Room"]
        let trigger = FileManager.default.temporaryDirectory.appendingPathComponent("room-audio-verify-\(UUID())")
        let source = Process()
        var passed = false
        do {
            source.executableURL = URL(fileURLWithPath: feeder)
            source.arguments = [clip, trigger.path]
            try source.run()
            let app = RunningAudioApp(id: source.processIdentifier, name: "Room Audio Test Player", bundleID: nil)
            var objects: [AudioObjectID] = []
            for _ in 0..<40 {
                objects = (try? app.audioObjects()) ?? []
                if !objects.isEmpty && Set(names).isSubset(of: Set(discovery.receivers.map(\.name))) { break }
                try await Task.sleep(for: .milliseconds(250))
            }
            guard !objects.isEmpty, Set(names).isSubset(of: Set(discovery.receivers.map(\.name))) else {
                throw StreamError("Test player or AirPlay receivers unavailable")
            }
            print("SELECTED_PROCESS: \(source.processIdentifier), HAL objects: \(objects)")
            fflush(nil)
            streaming.start(source: .application(objects, playLocally: false), names: names,
                            volumes: ["Kitchen": 45, "Living Room": 45])
            let deadline = ContinuousClock().now + .seconds(180)
            while streaming.active && !streaming.isTransmitting && ContinuousClock().now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            guard streaming.active, streaming.isTransmitting else { throw StreamError(streaming.status) }
            print("APP_TEST_LISTEN_IN_ABOUT_10_SECONDS")
            fflush(nil)
            let alert = Process()
            alert.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            alert.arguments = ["/System/Library/Sounds/Glass.aiff"]
            try alert.run()
            NSSound.beep()
            var excludedPeak: Float = streaming.signalLevel
            for _ in 0..<33 {
                try await Task.sleep(for: .milliseconds(120))
                excludedPeak = max(excludedPeak, streaming.signalLevel)
            }
            guard !alert.isRunning, alert.terminationStatus == 0 else { throw StreamError("System sound failed") }
            print("EXCLUDED_SYSTEM_SOUND_PEAK: \(excludedPeak)")
            try Data().write(to: trigger)
            var musicPeak: Float = 0
            for _ in 0..<125 {
                guard streaming.active else { throw StreamError(streaming.status) }
                try await Task.sleep(for: .milliseconds(120))
                musicPeak = max(musicPeak, streaming.signalLevel)
            }
            print("SELECTED_APPLICATION_PEAK: \(musicPeak)")
            guard excludedPeak <= 0.0001, musicPeak > 0.02 else { throw StreamError("Source separation check failed") }
            try await Task.sleep(for: .seconds(9))
            guard streaming.active, streaming.isTransmitting else { throw StreamError(streaming.status) }
            passed = true
        } catch {
            print("APP_SOURCE_TEST_ERROR: \(error.localizedDescription)")
        }
        streaming.stop()
        if source.isRunning { source.terminate() }
        try? FileManager.default.removeItem(at: trigger)
        let shutdown = ContinuousClock().now + .seconds(18)
        while streaming.active && ContinuousClock().now < shutdown {
            try? await Task.sleep(for: .milliseconds(100))
        }
        print("ROOM_AUDIO_APP_SOURCE_STOP: \(streaming.status)")
        exit(passed && !streaming.active && streaming.status == "Streaming stopped" ? 0 : 1)
    }

    private func verifyBluetooth(feeder: String, clip: String) async {
        var passed = false
        do {
            guard let output = try LocalOutput.list().first(where: { $0.name == "FiiO BTA30 Pro" }),
                  let input = inputs.first(where: { $0.name == "BlackHole 2ch" }) else {
                throw StreamError("FiiO or BlackHole is missing")
            }
            streaming.start(source: .device(input.id), output: output, volume: 45)
            guard streaming.isTransmitting else { throw StreamError(streaming.status) }
            print("FIIO_READY_LISTEN_IN_10_SECONDS")
            fflush(nil)
            try await Task.sleep(for: .seconds(10))
            let source = Process()
            source.executableURL = URL(fileURLWithPath: feeder)
            source.arguments = [clip]
            try source.run()
            while source.isRunning { try await Task.sleep(for: .milliseconds(100)) }
            guard source.terminationStatus == 0 else { throw StreamError("BlackHole test player failed") }
            try await Task.sleep(for: .seconds(1))
            guard streaming.isTransmitting, streaming.bluetoothRenderedFrames > 441000 else {
                throw StreamError("Incomplete Bluetooth rendering: \(streaming.status), frames=\(streaming.bluetoothRenderedFrames)")
            }
            print("FIIO_RENDERED_NON_SILENT_FRAMES: \(streaming.bluetoothRenderedFrames)")
            passed = true
        } catch {
            print("FIIO_TEST_ERROR: \(error.localizedDescription)")
        }
        streaming.stop()
        print("FIIO_STOP: \(streaming.status)")
        exit(passed && !streaming.active ? 0 : 1)
    }
}

@MainActor
final class RoomAudioDelegate: NSObject, NSApplicationDelegate {
    private var quitting = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(self, selector: #selector(systemWillSleep(_:)),
                                    name: NSWorkspace.willSleepNotification, object: nil)
        workspaceCenter.addObserver(self, selector: #selector(systemDidWake(_:)),
                                    name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        RoutingWorkspace.shared.prepareSavedGroupsForSleep()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        RoutingWorkspace.shared.resumeSavedGroupsAfterWake()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard !quitting, let window = notification.object as? NSWindow, Self.isRoomAudioWindow(window) else { return }
        Task { @MainActor in
            guard !quitting, !NSApp.windows.contains(where: { $0 !== window && $0.isVisible && Self.isRoomAudioWindow($0) }),
                  !window.isVisible else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, Self.isRoomAudioWindow(window),
              NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
    }

    private static func isRoomAudioWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) &&
            ["Room Audio", "Room Audio Group", "Room Audio Sources", "Room Audio Bluetooth Group"].contains(window.title)
    }

    static func openMainWindow(_ openWindow: OpenWindowAction) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate()
    }

    static func openGroupWindow(_ openWindow: OpenWindowAction, id: UUID) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "group-mixer", value: id)
        NSApp.activate()
    }

    static func openSourcesWindow(_ openWindow: OpenWindowAction, id: UUID) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "group-sources", value: id)
        NSApp.activate()
    }

    static func openBluetoothGroupWindow(_ openWindow: OpenWindowAction, id: UUID) {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "bluetooth-group", value: id)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let workspace = RoutingWorkspace.shared
        guard !quitting else { return .terminateLater }
        workspace.stopDiscovery()
        guard workspace.hasActiveRoutes else { return .terminateNow }
        quitting = true
        workspace.stopAll()
        Task {
            let deadline = ContinuousClock().now + .seconds(20)
            while workspace.hasActiveRoutes && ContinuousClock().now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct RoomAudioApp: App {
    @NSApplicationDelegateAdaptor(RoomAudioDelegate.self) private var delegate
    @StateObject private var workspace = RoutingWorkspace.shared

    var body: some Scene {
        Window("Room Audio", id: "main") {
            if CommandLine.arguments.dropFirst().contains(where: {
                ["--verify-discovery", "--verify-capture", "--verify-live", "--verify-app-source", "--verify-bluetooth"].contains($0)
            }) {
                RoomAudioView()
            } else {
                RoutingView(workspace: workspace, diagnostics: true)
            }
        }.defaultSize(width: 600, height: 570)

        WindowGroup("Room Audio Group", id: "group-mixer", for: UUID.self) { $groupID in
            if let groupID {
                GroupEditor(groupID: groupID, workspace: workspace, groups: workspace.savedGroups)
            }
        }
        .defaultSize(width: 530, height: 460)
        .restorationBehavior(.disabled)

        WindowGroup("Room Audio Sources", id: "group-sources", for: UUID.self) { $groupID in
            if let groupID {
                GroupSourcesWindow(groupID: groupID, workspace: workspace, groups: workspace.savedGroups)
            }
        }
        .defaultSize(width: 530, height: 440)
        .restorationBehavior(.disabled)

        WindowGroup("Room Audio Bluetooth Group", id: "bluetooth-group", for: UUID.self) { $groupID in
            if let groupID {
                BluetoothGroupEditor(id: groupID, workspace: workspace)
            }
        }
        .defaultSize(width: 490, height: 360)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            RoutingView(workspace: workspace, menuBar: true)
        } label: {
            let busy = workspace.isConnecting || workspace.isReconnecting
            let title = if workspace.isReconnecting { "Room Audio · Reconnecting" }
                else if workspace.isConnecting { "Room Audio · Connecting" }
                else { "Room Audio" }
            Label(title, systemImage: busy ? ConnectionIcon.symbol : "speaker.wave.2")
        }
        .menuBarExtraStyle(.window)
    }
}
