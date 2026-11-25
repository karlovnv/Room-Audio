import AppKit
import Combine
import CoreAudio
import SwiftUI

@MainActor
final class SharedPTP {
    static var serviceInstalled: Bool {
        let manifest = "/Library/LaunchDaemons/local.roomaudio.ptp.plist"
        let attributes = try? FileManager.default.attributesOfItem(atPath: manifest)
        return (attributes?[.ownerAccountID] as? NSNumber)?.uint32Value == 0
    }

    private final class Session {
        let process: Process
        let input: Pipe
        let folder: URL
        let status: URL
        var closing = false

        init(receiver: String) throws {
            guard let script = Bundle.main.url(forResource: "stream", withExtension: "py"),
                  let transport = Bundle.main.url(forResource: "cliairplay", withExtension: nil) else {
                throw StreamError("Компоненты AirPlay отсутствуют")
            }
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("room-audio-shared-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            status = folder.appendingPathComponent("clock.jsonl")
            input = Pipe()
            process = Process()
            do {
                FileManager.default.createFile(atPath: status.path, contents: nil)
                let log = try FileHandle(forWritingTo: status)
                defer { try? log.close() }
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [script.path, "--transport", transport.path, "--clock-only", "--", receiver]
                process.standardInput = input
                process.standardOutput = log
                process.standardError = log
                try process.run()
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }

        func stop() {
            guard !closing else { return }
            closing = true
            if !events.contains(where: { $0["status"] == "clock_ready" }) && process.isRunning {
                process.terminate()
            }
            try? input.fileHandleForWriting.close()
        }

        var events: [[String: String]] {
            ((try? String(contentsOf: status, encoding: .utf8)) ?? "").split(separator: "\n").compactMap {
                (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: String]
            }
        }
    }

    private var session: Session?
    private var leases: Set<UUID> = []

    func acquire(_ token: UUID, receiver: String) async throws -> String {
        try Task.checkCancellation()
        while let current = session, current.closing && current.process.isRunning {
            try await Task.sleep(for: .milliseconds(100))
        }
        if leases.isEmpty, let current = session, !current.process.isRunning {
            session = nil
        }
        if session == nil { session = try Session(receiver: receiver) }
        guard let current = session else { throw StreamError("Не удалось запустить PTP") }
        leases.insert(token)
        do {
            let deadline = ContinuousClock().now + .seconds(130)
            while ContinuousClock().now < deadline {
                try Task.checkCancellation()
                let events = current.events
                if let error = events.last(where: { $0["status"] == "error" })?["message"] {
                    throw StreamError(error)
                }
                guard current.process.isRunning else { throw StreamError("Общий процесс PTP завершился") }
                if let address = events.last(where: { $0["status"] == "clock_ready" })?["address"] {
                    return address
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw StreamError("Истекло время запуска общего PTP")
        } catch {
            release(token)
            throw error
        }
    }

    func release(_ token: UUID) {
        guard leases.remove(token) != nil, leases.isEmpty, let current = session else { return }
        current.stop()
        Task {
            while current.process.isRunning { try? await Task.sleep(for: .milliseconds(100)) }
            try? FileManager.default.removeItem(at: current.folder)
            if session === current { session = nil }
        }
    }

    var isRunning: Bool { session?.process.isRunning ?? false }
    var usesInstalledService: Bool {
        session?.events.contains { $0["status"] == "managed_clock" } == true &&
            session?.events.contains { $0["status"] == "authorization" } == false
    }
}

enum RouteDestination: Identifiable, Equatable {
    enum ID: Hashable {
        case airplay(Receiver.ID)
        case bluetooth(AudioObjectID)
    }
    case airplay(Receiver.ID)
    case bluetooth(LocalOutput)

    var id: ID {
        switch self {
        case .airplay(let id): .airplay(id)
        case .bluetooth(let output): .bluetooth(output.id)
        }
    }

    var name: String {
        switch self {
        case .airplay(let id): id.name
        case .bluetooth(let output): output.name
        }
    }

    var isAirPlay: Bool {
        if case .airplay = self { return true }
        return false
    }

    var visibilityKey: String {
        switch self {
        case .airplay(let id): "airplay:\(id.domain):\(id.name)"
        case .bluetooth(let output): "bluetooth:\(output.uid ?? output.name)"
        }
    }
}

enum RouteSourceChoice: Hashable {
    case application(pid_t)
    case device(AudioObjectID)
}

@MainActor
final class OutputRoute: ObservableObject, Identifiable {
    let id: RouteDestination.ID
    let destination: RouteDestination
    let stream = Streaming()
    @Published var source: RouteSourceChoice?
    @Published var volume = 45.0
    @Published var playLocally = false
    private(set) var attemptedAt = Date.distantPast
    @Published private(set) var starting = false
    @Published private(set) var runningSourceName: String?
    @Published private(set) var error: String?
    private var session: Task<Void, Never>?

    var isConnecting: Bool { starting || stream.isConnecting }

    init(_ destination: RouteDestination) {
        id = destination.id
        self.destination = destination
    }

    func start(_ source: AudioSource, name: String? = nil, clock: SharedPTP, overrideTV: Bool = false) {
        guard !starting, !stream.active, session == nil else { return }
        error = nil
        attemptedAt = .now
        stream.prepareReceivers([destination.name])
        starting = true
        runningSourceName = name
        let token = UUID()
        session = Task {
            defer {
                clock.release(token)
                starting = false
                runningSourceName = nil
                session = nil
            }
            do {
                switch destination {
                case .airplay:
                    let address = try await clock.acquire(token, receiver: destination.name)
                    try Task.checkCancellation()
                    stream.start(source: source, names: [destination.name],
                                 volumes: [destination.name: Int(volume.rounded())], sharedClockAddress: address, protectSonos: true,
                                 overrideTV: overrideTV ? [destination.name] : [])
                case .bluetooth(let output):
                    try Task.checkCancellation()
                    stream.start(source: source, output: output, volume: Int(volume.rounded()))
                }
                starting = false
                if !stream.active { throw StreamError(stream.status) }
                while stream.active {
                    // Once a route has started, stop waits for its own cleanup before
                    // releasing its clock lease. Other receivers can keep playing.
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func setVolume() {
        stream.setVolume(Int(volume.rounded()), for: destination.name)
    }

    func stop() {
        if stream.active { stream.stop() }
        else if starting { session?.cancel() }
    }
}

@MainActor
final class SynchronizedGroup: ObservableObject {
    let stream = Streaming()
    @Published private(set) var members: Set<String> = []
    @Published private(set) var preparing = false
    @Published private(set) var sourceName: String?
    private(set) var hasTransmitted = false
    @Published var error: String?
    @Published private(set) var attemptedAt = Date.distantPast
    private var attemptedReceivers: Set<String> = []
    private var exclusions: [String: String] = [:]
    private var startingVolumes: [String: Int] = [:]
    private var session: Task<Void, Never>?

    var active: Bool { preparing || stream.active || !members.isEmpty }
    var isConnecting: Bool { preparing || stream.isConnecting }

    func isConnecting(to receiver: String) -> Bool {
        members.contains(receiver) && (preparing || stream.isConnecting(to: receiver))
    }

    var transmittingReceivers: Set<String> {
        guard stream.isTransmitting, !stream.stopping else { return [] }
        return members.filter { stream.receivers[$0] == "Передача" }
    }

    func attempted(_ receiver: String) -> Bool {
        attemptedReceivers.contains(receiver) || exclusions[receiver] != nil
    }

    func reason(for receiver: String) -> String? {
        if let reason = exclusions[receiver] ?? stream.skippedReceivers[receiver] { return reason }
        if !active, attemptedReceivers.contains(receiver), let error {
            if stream.skippedReceivers.isEmpty { return error }
            return "передача группы прервалась"
        }
        return nil
    }

    func recordAttempt(receivers: Set<String>, exclusions: [String: String]) {
        attemptedReceivers = receivers
        self.exclusions = exclusions
        stream.prepareReceivers(receivers.sorted())
        attemptedAt = .now
    }

    func start(_ source: AudioSource, title: String, volumes: [String: Int], clock: SharedPTP,
               protectSonos: Bool = false, overrideTV: Set<String> = [],
               exclusions: [String: String] = [:]) {
        guard session == nil, let first = volumes.keys.sorted().first else { return }
        let token = UUID()
        recordAttempt(receivers: Set(volumes.keys), exclusions: exclusions)
        hasTransmitted = false
        members = Set(volumes.keys)
        startingVolumes = volumes
        sourceName = title
        preparing = true
        error = nil
        session = Task {
            defer {
                clock.release(token)
                members = []
                preparing = false
                sourceName = nil
                startingVolumes = [:]
                session = nil
            }
            do {
                let address = try await clock.acquire(token, receiver: first)
                try Task.checkCancellation()
                stream.start(source: source, names: volumes.keys.sorted(),
                             volumes: startingVolumes, sharedClockAddress: address, protectSonos: protectSonos,
                             overrideTV: overrideTV)
                preparing = false
                guard stream.active else { throw StreamError(stream.status) }
                while stream.active {
                    if stream.isTransmitting { hasTransmitted = true }
                    let stopped = members.filter { stream.receivers[$0] == "Остановлено" }
                    if !stopped.isEmpty { members.subtract(stopped) }
                    let joined = stream.receivers.filter { ["Подключение", "Синхронизация", "Передача"].contains($0.value) }.map(\.key)
                    if !Set(joined).isSubset(of: members) { members.formUnion(joined) }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if stream.status != "Передача остановлена" { error = stream.status }
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func stop() {
        if stream.active { stream.stop() }
        else { session?.cancel() }
    }

    func joinTVReceiver(_ receiver: String, volume: Int) {
        if stream.joinTVReceiver(receiver, volume: volume) { members.insert(receiver) }
    }

    func setVolumes(_ changes: [String: Int]) {
        if preparing {
            for (name, volume) in changes where startingVolumes[name] != nil { startingVolumes[name] = volume }
        } else {
            stream.setVolumes(changes)
        }
    }
}

@MainActor
final class RoutingWorkspace: ObservableObject {
    static let shared = RoutingWorkspace()
    let discovery = Discovery()
    let clock = SharedPTP()
    let synchronizedGroup = SynchronizedGroup()
    let savedGroups: SpeakerGroups
    @Published private(set) var routes: [RouteDestination.ID: OutputRoute] = [:]
    @Published private(set) var apps: [RunningAudioApp] = []
    @Published private(set) var inputs: [AudioInput] = []
    @Published private(set) var destinations: [RouteDestination] = []
    @Published var groupSelection: Set<RouteDestination.ID> = []
    var volumePreferences: OutputVolumePreferences
    var groupPlayback: [UUID: SavedGroupPlayback] = [:]
    @Published var recoveringGroups: Set<UUID> = []
    @Published private(set) var recoveringReceivers: [UUID: Set<Receiver.ID>] = [:]
    var waitingForWake = false
    private let defaults: UserDefaults
    private var routeActivityObservers: [RouteDestination.ID: AnyCancellable] = [:]
    private var groupActivityObservers: Set<AnyCancellable> = []
    private var polling: Task<Void, Never>?
    private var checkingWindow = false
    fileprivate var checkingPTPService = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        savedGroups = SpeakerGroups(defaults: defaults)
        let data = defaults.data(forKey: OutputVolumePreferences.key)
        volumePreferences = data.flatMap { try? JSONDecoder().decode(OutputVolumePreferences.self, from: $0) }
            ?? OutputVolumePreferences()
        groupActivityObservers = [
            savedGroups.objectWillChange.sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            },
            synchronizedGroup.$preparing.dropFirst().sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            },
            synchronizedGroup.stream.connectionUpdates.dropFirst().sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
        ]
    }

    func start() {
        guard polling == nil else { return }
        discovery.start()
        refresh()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                self?.refresh()
                self?.recoverSavedGroups()
            }
        }
    }

    private func refresh() {
        let updatedApps = RunningAudioApp.list()
        if apps != updatedApps { apps = updatedApps }
        if let updated = try? AudioInput.list(), inputs != updated { inputs = updated }
        let bluetooth = (try? LocalOutput.list())
            ?? destinations.compactMap { if case .bluetooth(let output) = $0 { output } else { nil } }
        let available: [RouteDestination] = discovery.receivers.map { .airplay($0.id) } + bluetooth.map { .bluetooth($0) }
        for destination in available where routes[destination.id] == nil {
            let route = OutputRoute(destination)
            route.volume = storedVolume(for: destination)
            if let blackHole = inputs.first(where: { $0.name == "BlackHole 2ch" }) { route.source = .device(blackHole.id) }
            routes[destination.id] = route
            routeActivityObservers[destination.id] = route.$starting.combineLatest(route.stream.$active, route.stream.connectionUpdates)
                .map { (visible: $0 || $1, connecting: $0 || $2) }
                .removeDuplicates(by: ==)
                .dropFirst()
                .sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.objectWillChange.send() }
                }
        }
        if destinations != available {
            destinations = available
            groupSelection.formIntersection(available.map(\.id))
        }
    }

    func setRouteVolume(_ volume: Double, route: OutputRoute) {
        objectWillChange.send()
        route.volume = volume
        volumePreferences.levels[route.destination.visibilityKey] = volume
        persistVolumePreferences()
        let name = route.destination.name
        if route.destination.isAirPlay,
           let group = savedGroups.owner(of: name) ?? (synchronizedGroup.members.contains(name) ? synchronizedGroup : nil) {
            group.setVolumes([name: Int(volume.rounded())])
        } else {
            route.setVolume()
        }
    }

    func storedVolume(for destination: RouteDestination) -> Double {
        guard let volume = volumePreferences.levels[destination.visibilityKey], (0...100).contains(volume) else { return 45 }
        return volume
    }

    func persistVolumePreferences() {
        if let data = try? JSONEncoder().encode(volumePreferences) {
            defaults.set(data, forKey: OutputVolumePreferences.key)
        }
    }

    var hasActiveRoutes: Bool {
        clock.isRunning || synchronizedGroup.preparing || synchronizedGroup.stream.active || savedGroups.hasActiveGroups ||
            routes.values.contains { $0.starting || $0.stream.active }
    }

    func stopAll() {
        groupPlayback.removeAll()
        recoveringGroups.removeAll()
        recoveringReceivers.removeAll()
        for route in routes.values { route.stop() }
        synchronizedGroup.stop()
        savedGroups.stopAll()
    }

    var isReconnecting: Bool { !recoveringGroups.isEmpty || !recoveringReceivers.isEmpty }
    var isConnecting: Bool { savedGroups.isConnecting || synchronizedGroup.isConnecting || routes.values.contains(where: \.isConnecting) }

    func isReconnecting(group id: UUID) -> Bool {
        recoveringGroups.contains(id) || recoveringReceivers[id] != nil
    }

    func isReconnecting(receiver id: Receiver.ID) -> Bool {
        recoveringReceivers.values.contains { $0.contains(id) } ||
            recoveringGroups.contains { groupPlayback[$0]?.receivers.contains(id) == true }
    }

    func setRecoveringReceivers(_ receivers: Set<Receiver.ID>, in group: UUID) {
        let value = receivers.isEmpty ? nil : receivers
        if recoveringReceivers[group] != value { recoveringReceivers[group] = value }
    }

    func stopDiscovery() {
        polling?.cancel()
        polling = nil
        discovery.stop()
    }

    func verifyWindowLifecycle(reopen: OpenWindowAction) {
        guard !checkingWindow else { return }
        checkingWindow = true
        Task {
            let deadline = ContinuousClock().now + .seconds(12)
            while (!routes.values.contains { $0.destination.name == "Kitchen" } ||
                   !NSApp.windows.contains { $0.isVisible && $0.title == "Room Audio" }) &&
                  ContinuousClock().now < deadline {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard let route = routes.values.first(where: { $0.destination.name == "Kitchen" }),
                  let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Room Audio" }) else {
                print("Window lifecycle: missing Kitchen or main window")
                exit(1)
            }
            route.volume = 37
            window.performClose(nil)
            try? await Task.sleep(for: .milliseconds(600))
            guard !window.isVisible, NSApp.activationPolicy() == .accessory,
                  routes[route.id] === route, route.volume == 37, polling != nil else {
                print("Window lifecycle: workspace did not survive close")
                exit(1)
            }
            print("WINDOW_CLOSED_ACCESSORY_MODE_WORKSPACE_RUNNING")
            RoomAudioDelegate.openMainWindow(reopen)
            for _ in 0..<30 {
                if NSApp.windows.contains(where: { $0.isVisible && $0.title == "Room Audio" }) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard NSApp.windows.contains(where: { $0.isVisible && $0.title == "Room Audio" }),
                  NSApp.activationPolicy() == .regular, routes[route.id] === route, route.volume == 37 else {
                print("Window lifecycle: window did not reopen with the same workspace")
                exit(1)
            }
            print("WINDOW_REOPENED_ROUTE_PRESERVED")
            fflush(nil)
            NSApp.terminate(nil)
        }
    }
}

@MainActor
struct RoutingView: View {
    @ObservedObject var workspace: RoutingWorkspace
    @ObservedObject private var discovery: Discovery
    @ObservedObject private var synchronizedGroup: SynchronizedGroup
    @ObservedObject private var savedGroups: SpeakerGroups
    @AppStorage("room-audio.simple-mode") private var simpleMode = false
    @AppStorage("room-audio.pinned-outputs") private var pinnedOutputsData = Data()
    @State private var editingVisibility = false
    @State private var installingPTP = false
    @State private var setupError: String?
    @Environment(\.openWindow) private var openWindow
    private let diagnostics: Bool

    init(workspace: RoutingWorkspace, diagnostics: Bool = false) {
        self.workspace = workspace
        self.discovery = workspace.discovery
        self.synchronizedGroup = workspace.synchronizedGroup
        self.savedGroups = workspace.savedGroups
        self.diagnostics = diagnostics
    }

    private var destinations: [RouteDestination] { workspace.destinations }
    private var routes: [RouteDestination.ID: OutputRoute] { workspace.routes }
    private var apps: [RunningAudioApp] { workspace.apps }
    private var inputs: [AudioInput] { workspace.inputs }
    private var clock: SharedPTP { workspace.clock }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Room Audio").font(.largeTitle.bold())
                    if !simpleMode {
                        Text(discovery.status).font(.caption).foregroundStyle(.secondary)
                        if !SharedPTP.serviceInstalled {
                            Button("AirPlay без пароля…", action: installPTP).disabled(installingPTP)
                        }
                        if let setupError { Text(setupError).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Toggle("Простой режим", isOn: $simpleMode).toggleStyle(.checkbox)
                    Button(editingVisibility ? "Готово" : "Видимость выходов") {
                        editingVisibility.toggle()
                    }.buttonStyle(.link)
                }
            }
            if !simpleMode || synchronizedGroup.active {
                HStack {
                    if synchronizedGroup.members.isEmpty {
                        Button("Запустить синхронно", action: startGroup)
                            .buttonStyle(.borderedProminent)
                            .disabled(workspace.groupSelection.count < 2)
                        Text("Отметь выходы AirPlay с одним источником.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Остановить группу", action: synchronizedGroup.stop)
                        Text(synchronizedGroup.preparing ? "Подготовка группы…" : "Синхронная группа")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !simpleMode, let error = synchronizedGroup.error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
            List {
                if editingVisibility { visibilitySettings }
                if !simpleMode || !savedGroups.groups.isEmpty {
                    SavedGroupsSection(workspace: workspace, groups: savedGroups, simpleMode: simpleMode)
                }
                let visible = destinations.filter(isVisible)
                let availableIDs = Set(destinations.map(\.id))
                let missing = knownDestinations.filter { !availableIDs.contains($0.id) && isVisible($0) }
                if simpleMode && visible.isEmpty && missing.isEmpty && savedGroups.groups.isEmpty {
                    Text("Выбери колонки в «Видимость выходов».")
                        .foregroundStyle(.secondary)
                } else if !simpleMode && destinations.isEmpty {
                    Text("Ожидание аудиовыходов…").foregroundStyle(.secondary)
                }
                if simpleMode {
                    group("Колонки", visible)
                } else {
                    group("AirPlay", visible.filter(\.isAirPlay))
                    group("Bluetooth", visible.filter { !$0.isAirPlay })
                }
                group("Недоступные выходы", missing, available: false)
            }.listStyle(.inset)
        }
        .padding(20)
        .frame(minWidth: 510, minHeight: 390)
        .task { workspace.start() }
        .task {
            guard diagnostics else { return }
            if CommandLine.arguments.contains("--verify-saved-groups") {
                verifySavedGroups()
            } else if CommandLine.arguments.contains("--verify-group-recovery"), !workspace.checkingPTPService {
                workspace.checkingPTPService = true
                Task {
                    do {
                        guard let group = savedGroups.groups.first(where: { $0.name == "All Sonos" }),
                              let session = savedGroups.session(for: group.id) else {
                            throw StreamError("Группа All Sonos не найдена.")
                        }
                        try await waitForPTPTest("обнаружение колонок") {
                            group.members.isSubset(of: Set(destinations.compactMap {
                                if case .airplay(let id) = $0 { id } else { nil }
                            }))
                        }
                        workspace.startSavedGroup(group, session: session)
                        try await waitForPTPTest("передача All Sonos", timeout: 90) {
                            session.transmittingReceivers == Set(group.members.map(\.name)) ||
                                (!session.active && workspace.groupPlayback[group.id] == nil && session.error != nil)
                        }
                        guard let anchor = session.stream.scheduledStart else {
                            throw StreamError(session.error ?? "Нет общего старта.")
                        }
                        print("RECOVERY_TEST_PLAYING source=\(session.sourceName ?? "?") anchor=\(anchor)")
                    } catch {
                        print("RECOVERY_TEST_ERROR \(error.localizedDescription)")
                    }
                    fflush(nil)
                }
            } else if let index = CommandLine.arguments.firstIndex(of: "--verify-group-volume"),
                      CommandLine.arguments.count == index + 3, !workspace.checkingPTPService {
                workspace.checkingPTPService = true
                let args = CommandLine.arguments
                Task { await verifyPTPService(feeder: args[index + 1], clips: [args[index + 2]], testVolume: true) }
            } else if let index = CommandLine.arguments.firstIndex(of: "--verify-ptp-service"),
                      CommandLine.arguments.count == index + 4, !workspace.checkingPTPService {
                workspace.checkingPTPService = true
                let args = CommandLine.arguments
                Task {
                    await verifyPTPService(feeder: args[index + 1], clips: [args[index + 2], args[index + 3]])
                }
            } else if CommandLine.arguments.contains("--verify-menu-lifecycle") {
                workspace.verifyWindowLifecycle(reopen: openWindow)
            } else if let index = CommandLine.arguments.firstIndex(of: "--verify-routes"),
               CommandLine.arguments.count == index + 4 {
                await verifyRoutes(feeder: CommandLine.arguments[index + 1],
                                   kitchenFile: CommandLine.arguments[index + 2],
                                   livingFile: CommandLine.arguments[index + 3])
            } else if let index = CommandLine.arguments.firstIndex(of: "--verify-group"),
                      CommandLine.arguments.count == index + 3 {
                await verifyGroup(feeder: CommandLine.arguments[index + 1], file: CommandLine.arguments[index + 2])
            } else if let index = CommandLine.arguments.firstIndex(of: "--verify-app-signals"),
                      CommandLine.arguments.count == index + 3 {
                await verifyAppSignals(feeder: CommandLine.arguments[index + 1], file: CommandLine.arguments[index + 2])
            }
        }
    }

    private var knownDestinations: [RouteDestination] {
        let members = savedGroups.groups.flatMap(\.members).map(RouteDestination.airplay)
        let known = destinations + routes.values.map(\.destination) + members
        return Dictionary(known.map { ($0.visibilityKey, $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func installPTP() {
        guard let helper = Bundle.main.url(forResource: "PTPService", withExtension: nil),
              let transport = Bundle.main.url(forResource: "cliairplay", withExtension: nil) else {
            setupError = "Компоненты службы PTP отсутствуют."
            return
        }
        installingPTP = true
        setupError = nil
        let installer = Process()
        installer.executableURL = helper
        installer.arguments = ["--install", transport.path]
        installer.terminationHandler = { process in
            let status = process.terminationStatus
            Task { @MainActor in
                if status != 0 { setupError = "Установка службы PTP не завершилась." }
                installingPTP = false
            }
        }
        do { try installer.run() }
        catch {
            installingPTP = false
            setupError = error.localizedDescription
        }
    }

    private var pinnedOutputs: Set<String> {
        (try? JSONDecoder().decode(Set<String>.self, from: pinnedOutputsData)) ?? []
    }

    private var visibilitySettings: some View {
        Section("Всегда показывать в простом режиме") {
            if knownDestinations.isEmpty {
                Text("Ожидание аудиовыходов…").foregroundStyle(.secondary)
            }
            ForEach(knownDestinations, id: \.visibilityKey) { destination in
                let names = if case .airplay(let id) = destination {
                    savedGroups.groups.filter { $0.members.contains(id) }.map(\.name)
                } else { [String]() }
                Toggle(isOn: Binding(
                    get: { pinnedOutputs.contains(destination.visibilityKey) },
                    set: { pinned in
                        var outputs = pinnedOutputs
                        if pinned { outputs.insert(destination.visibilityKey) }
                        else { outputs.remove(destination.visibilityKey) }
                        if let data = try? JSONEncoder().encode(outputs.sorted()) { pinnedOutputsData = data }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(destination.name)
                        if !names.isEmpty {
                            Text(names.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.toggleStyle(.checkbox)
            }
        }
    }

    private func isVisible(_ destination: RouteDestination) -> Bool {
        guard simpleMode else { return true }
        if pinnedOutputs.contains(destination.visibilityKey) { return true }
        if case .airplay(let id) = destination, workspace.isReconnecting(receiver: id) { return true }
        let route = routes[destination.id]
        if route?.starting == true || route?.stream.active == true { return true }
        return destination.isAirPlay &&
            (synchronizedGroup.members.contains(destination.name) || savedGroups.owner(of: destination.name) != nil)
    }

    @ViewBuilder private func group(_ title: String, _ destinations: [RouteDestination], available: Bool = true) -> some View {
        if !destinations.isEmpty {
            Section(title) {
                ForEach(destinations) { destination in
                    if let route = routes[destination.id] {
                        let owner = savedGroups.owner(of: destination.name) ?? synchronizedGroup
                        let receiverID: Receiver.ID? = if case .airplay(let id) = destination { id } else { nil }
                        RouteRow(route: route, stream: route.stream, apps: apps, inputs: inputs, available: available, simpleMode: simpleMode,
                                 reconnecting: receiverID.map { workspace.isReconnecting(receiver: $0) } ?? false,
                                 clock: clock, group: owner, groupStream: owner.stream,
                                 groupTitle: savedGroups.ownerName(of: destination.name),
                                 groupAttempt: receiverID.flatMap(savedGroups.latestAttempt(for:)),
                                 receiverID: receiverID,
                                 workspace: workspace,
                                 savedGroups: savedGroups,
                                 groupSelected: Binding(
                                    get: { workspace.groupSelection.contains(destination.id) },
                                    set: { if $0 { workspace.groupSelection.insert(destination.id) } else { workspace.groupSelection.remove(destination.id) } }
                                 ))
                    } else {
                        Label(destination.name, systemImage: "airplay.audio").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func startGroup() {
        synchronizedGroup.error = nil
        let groupRoutes = destinations.filter { workspace.groupSelection.contains($0.id) && $0.isAirPlay }
            .compactMap { routes[$0.id] }
        do {
            guard groupRoutes.count > 1, let first = groupRoutes.first else { return }
            guard groupRoutes.allSatisfy({ !$0.starting && !$0.stream.active && savedGroups.owner(of: $0.destination.name) == nil }) else {
                throw StreamError("Сначала останови индивидуальные маршруты выбранных колонок.")
            }
            guard let choice = first.source, groupRoutes.allSatisfy({ $0.source == choice }) else {
                throw StreamError("Выбери один и тот же источник во всех отмеченных строках.")
            }
            if case .application = choice, !groupRoutes.allSatisfy({ $0.playLocally == first.playLocally }) {
                throw StreamError("Установи одинаковое значение «Также на Mac» для всей группы.")
            }
            let (source, title) = try resolveSource(choice, apps: apps, inputs: inputs, playLocally: first.playLocally)
            let levels = Dictionary(groupRoutes.map { ($0.destination.name, Int($0.volume.rounded())) }, uniquingKeysWith: { a, _ in a })
            synchronizedGroup.start(source, title: title, volumes: levels, clock: clock)
        } catch {
            synchronizedGroup.error = error.localizedDescription
        }
    }

    private func verifyGroup(feeder: String, file: String) async {
        let names: Set<String> = ["Kitchen", "Living Room"]
        let trigger = FileManager.default.temporaryDirectory.appendingPathComponent("room-audio-group-\(UUID())")
        let player = Process()
        var passed = false
        do {
            player.executableURL = URL(fileURLWithPath: feeder)
            player.arguments = [file, trigger.path]
            try player.run()
            let app = RunningAudioApp(id: player.processIdentifier, name: "Room Audio Test Player", bundleID: nil)
            var objects: [AudioObjectID] = []
            for _ in 0..<60 {
                objects = (try? app.audioObjects()) ?? []
                if !objects.isEmpty && names.isSubset(of: Set(destinations.filter(\.isAirPlay).map(\.name))) { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            guard !objects.isEmpty && names.isSubset(of: Set(destinations.filter(\.isAirPlay).map(\.name))) else {
                throw StreamError("Test source or speakers not found")
            }
            synchronizedGroup.start(.application(objects, playLocally: false), title: app.name,
                                    volumes: ["Kitchen": 45, "Living Room": 45], clock: clock)
            let stream = synchronizedGroup.stream
            let deadline = ContinuousClock().now + .seconds(170)
            while !stream.isTransmitting {
                guard !synchronizedGroup.members.isEmpty, ContinuousClock().now < deadline else {
                    throw StreamError(synchronizedGroup.error ?? stream.status)
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard let anchor = stream.scheduledStart, stream.receivers["Kitchen"] == "Передача",
                  stream.receivers["Living Room"] == "Передача" else { throw StreamError("Shared start not confirmed") }
            print("GROUP_SHARED_START \(anchor); LISTEN_IN_ABOUT_10_SECONDS")
            fflush(nil)
            try await Task.sleep(for: .seconds(4))
            try Data().write(to: trigger)
            var peak: Float = 0
            for _ in 0..<135 {
                guard stream.isTransmitting else { throw StreamError(stream.status) }
                peak = max(peak, stream.signalLevel)
                try await Task.sleep(for: .milliseconds(120))
            }
            guard peak > 0.02 else { throw StreamError("No audio captured") }
            print("GROUP_SOURCE_PEAK \(peak)")
            stream.stopReceiver("Kitchen")
            for _ in 0..<50 {
                if stream.receivers["Kitchen"] == "Остановлено" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard stream.receivers["Kitchen"] == "Остановлено", stream.receivers["Living Room"] == "Передача",
                  stream.isTransmitting, clock.isRunning else { throw StreamError("Kitchen stop interrupted Living Room") }
            print("GROUP_KITCHEN_STOPPED_LIVING_ROOM_CONTINUES")
            fflush(nil)
            try await Task.sleep(for: .seconds(7))
            passed = stream.isTransmitting
        } catch {
            print("GROUP_TEST_ERROR: \(error.localizedDescription)")
        }
        synchronizedGroup.stop()
        if player.isRunning { player.terminate() }
        for _ in 0..<160 {
            if synchronizedGroup.members.isEmpty && !clock.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? FileManager.default.removeItem(at: trigger)
        print("GROUP_STOPPED: \(synchronizedGroup.members.isEmpty), PTP_RUNNING: \(clock.isRunning)")
        exit(passed && synchronizedGroup.members.isEmpty && !clock.isRunning ? 0 : 1)
    }

    private func verifyPTPService(feeder: String, clips: [String], testVolume: Bool = false) async {
        var player: Process?
        var session: SynchronizedGroup?
        var trigger: URL?
        var passed = false
        do {
            guard SharedPTP.serviceInstalled,
                  let group = savedGroups.groups.first(where: { $0.name == "All Sonos" }),
                  let savedSession = savedGroups.session(for: group.id) else {
                throw StreamError("Служба PTP или группа All Sonos не найдена.")
            }
            session = savedSession
            let names = Set(group.members.map(\.name))
            guard names == ["Kitchen", "Living Room"] else { throw StreamError("Неожиданный состав All Sonos.") }
            try await waitForPTPTest("колонки и окно") {
                names.isSubset(of: Set(destinations.filter(\.isAirPlay).map(\.name))) &&
                    NSApp.windows.contains { $0.isVisible && $0.title == "Room Audio" }
            }
            let initialVolumes = testVolume ? ["Kitchen": 30, "Living Room": 60] : ["Kitchen": 45, "Living Room": 45]
            if testVolume {
                for member in group.members {
                    guard let route = routes[.airplay(member)], let level = initialVolumes[member.name] else {
                        throw StreamError("Колонка \(member.name) недоступна.")
                    }
                    workspace.setRouteVolume(Double(level), route: route)
                }
            }
            for (index, clip) in clips.enumerated() {
                let source = Process()
                let cue = FileManager.default.temporaryDirectory.appendingPathComponent("room-audio-ptp-test-\(UUID())")
                source.executableURL = URL(fileURLWithPath: feeder)
                source.arguments = [clip, cue.path]
                try source.run()
                player = source
                trigger = cue
                let app = RunningAudioApp(id: source.processIdentifier, name: "PTP test \(index + 1)", bundleID: nil)
                try await waitForPTPTest("аудиоисточник") { (try? app.audioObjects().isEmpty) == false }
                savedSession.start(.application(try app.audioObjects(), playLocally: false), title: app.name,
                                   volumes: initialVolumes, clock: clock, protectSonos: true)
                try await waitForPTPTest("захват аудио") {
                    savedSession.stream.status == "Синхронизация AirPlay…" ||
                        savedSession.stream.isTransmitting || (!savedSession.active && savedSession.error != nil)
                }
                try Data().write(to: cue)
                try await waitForPTPTest("подключение обеих колонок") {
                    savedSession.transmittingReceivers == names || (!savedSession.active && savedSession.error != nil)
                }
                guard savedSession.transmittingReceivers == names, clock.usesInstalledService,
                      let anchor = savedSession.stream.scheduledStart else {
                    throw StreamError(savedSession.error ?? "Колонки не подтвердили старт через установленную службу.")
                }
                print("ALL_SONOS_SOURCE_\(index + 1)_STARTED_WITHOUT_AUTHORIZATION_EVENT anchor=\(anchor)")
                fflush(nil)
                try await waitForPTPTest("звуковой сигнал") { savedSession.stream.signalLevel > 0.02 }
                if testVolume {
                    try await verifyLiveGroupVolume(group, session: savedSession, anchor: anchor)
                } else if index == 0 {
                    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Room Audio" }) else {
                        throw StreamError("Окно Room Audio не найдено.")
                    }
                    window.performClose(nil)
                    try await waitForPTPTest("закрытие окна") { !window.isVisible }
                    var peak: Float = 0
                    for _ in 0..<35 {
                        guard savedSession.transmittingReceivers == names,
                              savedSession.stream.scheduledStart == anchor else {
                            throw StreamError("После закрытия окна изменилась сессия All Sonos: \(savedSession.stream.status)")
                        }
                        peak = max(peak, savedSession.stream.signalLevel)
                        try await Task.sleep(for: .milliseconds(120))
                    }
                    guard peak > 0.02 else { throw StreamError("После закрытия окна не зафиксирован звуковой сигнал.") }
                    print("WINDOW_CLOSED_BOTH_RECEIVERS_CONTINUED peak=\(peak)")
                    fflush(nil)
                    try await Task.sleep(for: .seconds(6))
                } else {
                    try await Task.sleep(for: .seconds(12))
                    guard savedSession.transmittingReceivers == names else {
                        throw StreamError("Второй источник не продолжил передачу на обе колонки.")
                    }
                }
                savedSession.stop()
                try await waitForPTPTest("остановка группы") { !savedSession.active && !clock.isRunning }
                if source.isRunning { source.terminate() }
                try? FileManager.default.removeItem(at: cue)
            }
            passed = true
        } catch {
            print("PTP_SERVICE_TEST_ERROR: \(error.localizedDescription)")
        }
        session?.stop()
        if let player, player.isRunning { player.terminate() }
        if let trigger { try? FileManager.default.removeItem(at: trigger) }
        try? await waitForPTPTest("очистка после теста") { !clock.isRunning }
        if passed && !clock.isRunning { print("PTP_SERVICE_TEST_PASSED_APP_STILL_RUNNING") }
        fflush(nil)
        if !passed || clock.isRunning { exit(1) }
    }

    private func verifyLiveGroupVolume(_ group: SpeakerGroup, session: SynchronizedGroup, anchor: String) async throws {
        for (index, maximum) in [60, 40, 0, 40, 60].enumerated() {
            if index > 0 { workspace.setGroupVolume(Double(maximum), for: group, session: session) }
            let actual = workspace.groupVolumeLevels(for: group, session: session)
            guard actual.count == 2, actual.values.max() == Double(maximum),
                  actual.allSatisfy({ $0.value == Double(maximum) * ($0.key.name == "Kitchen" ? 0.5 : 1) }) else {
                throw StreamError("Неверный баланс группы на уровне \(maximum)%.")
            }
            print("GROUP_VOLUME_SET \(maximum / 2) \(maximum) anchor=\(anchor)")
            fflush(nil)
            var peak: Float = 0
            for _ in 0..<42 {
                try await Task.sleep(for: .milliseconds(120))
                guard session.transmittingReceivers == ["Kitchen", "Living Room"],
                      session.stream.scheduledStart == anchor else {
                    throw StreamError("Передача прервалась на уровне \(maximum)%.")
                }
                peak = max(peak, session.stream.signalLevel)
            }
            guard peak > 0.02 else { throw StreamError("Захват музыки пропал на уровне \(maximum)%.") }
            print("GROUP_VOLUME_SIGNAL \(maximum) peak=\(peak)")
            fflush(nil)
        }
        print("GROUP_VOLUME_TEST_PASSED")
    }

    private func waitForPTPTest(_ stage: String, timeout: Int = 25, ready: () -> Bool) async throws {
        let deadline = ContinuousClock().now + .seconds(timeout)
        while !ready() {
            guard ContinuousClock().now < deadline else { throw StreamError("Тайм-аут: \(stage).") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func verifyRoutes(feeder: String, kitchenFile: String, livingFile: String) async {
        var testRoutes: [OutputRoute] = []
        var players: [Process] = []
        var result = false
        let trigger = FileManager.default.temporaryDirectory.appendingPathComponent("room-audio-routes-\(UUID())")
        do {
            let setups = [("Kitchen", kitchenFile), ("Living Room", livingFile)]
            for _ in 0..<60 {
                if setups.allSatisfy({ setup in routes.values.contains { $0.destination.name == setup.0 && $0.destination.isAirPlay } }) { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            for (name, file) in setups {
                guard let route = routes.values.first(where: { $0.destination.name == name && $0.destination.isAirPlay }) else {
                    throw StreamError("Missing receiver: \(name)")
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: feeder)
                process.arguments = [file, trigger.path]
                try process.run()
                players.append(process)
                let app = RunningAudioApp(id: process.processIdentifier, name: name, bundleID: nil)
                var ids: [AudioObjectID] = []
                for _ in 0..<40 {
                    ids = (try? app.audioObjects()) ?? []
                    if !ids.isEmpty { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard !ids.isEmpty else { throw StreamError("Missing source: \(name)") }
                print("ROUTE \(name) <- PID \(process.processIdentifier), Core Audio \(ids)")
                fflush(nil)
                testRoutes.append(route)
                route.start(.application(ids, playLocally: false), clock: clock)
            }
            let deadline = ContinuousClock().now + .seconds(170)
            while !testRoutes.allSatisfy({ $0.stream.isTransmitting }) {
                if let failure = testRoutes.first(where: { !$0.starting && !$0.stream.active }) {
                    throw StreamError("\(failure.destination.name): \(failure.error ?? failure.stream.status)")
                }
                guard ContinuousClock().now < deadline else { throw StreamError("Timed out waiting for both routes") }
                try await Task.sleep(for: .milliseconds(100))
            }
            print("ROUTES_LISTEN_IN_ABOUT_10_SECONDS")
            fflush(nil)
            try await Task.sleep(for: .seconds(4))
            try Data().write(to: trigger)
            var peaks: [Float] = [0, 0]
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(120))
                for index in testRoutes.indices {
                    guard testRoutes[index].stream.isTransmitting else { throw StreamError(testRoutes[index].stream.status) }
                    peaks[index] = max(peaks[index], testRoutes[index].stream.signalLevel)
                }
            }
            guard peaks.allSatisfy({ $0 > 0.02 }) else { throw StreamError("One or more routes did not receive signal") }
            print("ROUTES_PEAKS \(peaks)")
            testRoutes[0].stop()
            for _ in 0..<60 {
                if !testRoutes[0].stream.active { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard !testRoutes[0].stream.active, testRoutes[1].stream.isTransmitting, clock.isRunning else {
                throw StreamError("Stopping Kitchen affected Living Room")
            }
            print("KITCHEN_STOPPED_LIVING_ROOM_STILL_TRANSMITTING")
            fflush(nil)
            try await Task.sleep(for: .seconds(9))
            result = testRoutes[1].stream.isTransmitting
        } catch {
            print("ROUTES_TEST_ERROR: \(error.localizedDescription)")
        }
        testRoutes.forEach { $0.stop() }
        for process in players where process.isRunning { process.terminate() }
        for _ in 0..<160 {
            if !testRoutes.contains(where: { $0.starting || $0.stream.active }) && !clock.isRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? FileManager.default.removeItem(at: trigger)
        print("ROUTES_STOPPED: \(!testRoutes.contains(where: { $0.starting || $0.stream.active })), PTP_RUNNING: \(clock.isRunning)")
        exit(result && !clock.isRunning ? 0 : 1)
    }
}

@MainActor
private struct RouteRow: View {
    @ObservedObject var route: OutputRoute
    @ObservedObject var stream: Streaming
    let apps: [RunningAudioApp]
    let inputs: [AudioInput]
    let available: Bool
    let simpleMode: Bool
    let reconnecting: Bool
    let clock: SharedPTP
    @ObservedObject var group: SynchronizedGroup
    @ObservedObject var groupStream: Streaming
    let groupTitle: String?
    let groupAttempt: (SpeakerGroup, SynchronizedGroup)?
    let receiverID: Receiver.ID?
    let workspace: RoutingWorkspace
    @ObservedObject var savedGroups: SpeakerGroups
    @Binding var groupSelected: Bool
    @State private var sourceError: String?
    @State private var editingTVName = false
    @State private var tvName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(route.destination.name, systemImage: route.destination.isAirPlay ? "airplay.audio" : "hifispeaker")
                    .font(.headline)
                if reconnecting || route.isConnecting || group.isConnecting(to: route.destination.name) {
                    ConnectionIcon(reconnecting: reconnecting)
                }
                Spacer()
                if !simpleMode && route.destination.isAirPlay && available {
                    Toggle("В группу", isOn: $groupSelected).toggleStyle(.checkbox)
                        .disabled(!group.members.isEmpty || route.starting || stream.active)
                }
                if blockedByTV {
                    if let (group, session) = currentGroupAttempt, let receiverID {
                        ForcePlayButton(receiver: route.destination.name) {
                            workspace.forcePlay(receiverID, group: group, session: session)
                        }
                            .disabled(session.stream.stopping || (session.active ? !session.stream.isTransmitting : group.source == nil))
                    } else {
                        ForcePlayButton(receiver: route.destination.name) { start(overrideTV: true) }
                            .disabled(route.source == nil)
                    }
                }
                if inGroup {
                    let stopping = groupStream.receivers[route.destination.name] == "Остановка…" || groupStream.stopping
                    Button {
                        if let receiverID, groupTitle != nil {
                            workspace.stopSavedGroupReceiver(receiverID, session: group)
                        } else {
                            groupStream.stopReceiver(route.destination.name)
                        }
                    } label: {
                        transmissionLabel(stopping ? "Остановка…" : "Остановить", active: true, compact: simpleMode)
                    }.disabled(group.preparing || stopping)
                } else if route.starting || stream.active {
                    Button(action: route.stop) {
                        transmissionLabel(stream.stopping ? "Остановка…" : "Остановить", active: true, compact: simpleMode)
                    }.disabled(stream.stopping)
                } else {
                    Button {
                        start()
                    } label: {
                        transmissionLabel("Запустить", active: false, compact: simpleMode)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(route.source == nil || !available)
                }
            }
            if !simpleMode && !inGroup {
                HStack {
                    RouteSourcePicker(title: route.starting || stream.active ? "Следующий источник" : "Источник",
                                      apps: apps, inputs: inputs, selection: $route.source)
                    if case .application = route.source {
                        Toggle("Также на Mac", isOn: $route.playLocally).toggleStyle(.checkbox)
                    }
                }
            }
            VolumeSlider(name: route.destination.name,
                         value: Binding(get: { route.volume }, set: { workspace.setRouteVolume($0, route: route) }),
                         showsSignalColumn: !simpleMode, signal: normalizedSignal)
            if !simpleMode || activityLabel != "Передача выключена" {
                HStack(spacing: 6) {
                    Text(activityLabel).foregroundStyle(.secondary).font(.caption)
                    if blockedByTV { editTVName }
                }
            }
            if let message = sourceError ?? route.error, message != activityLabel {
                Text(message).foregroundStyle(.secondary).font(.caption)
            }
            if (route.starting || stream.active || inGroup),
               let (savedGroup, session) = groupAttempt, session !== group,
               let reason = session.reason(for: route.destination.name) {
                Text("Группа «\(savedGroup.name)» · при запуске: \(occupation(reason))")
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
        .padding(.vertical, 6)
        .onChange(of: route.source) { _, _ in sourceError = nil }
    }

    private var inGroup: Bool { group.members.contains(route.destination.name) }

    private var normalizedSignal: Double {
        let peak = Double(inGroup ? groupStream.signalLevel : stream.signalLevel)
        return peak > 0 ? max(0, min(1, (20 * log10(peak) + 60) / 60)) : 0
    }

    private var currentGroupAttempt: (SpeakerGroup, SynchronizedGroup)? {
        guard let groupAttempt, groupAttempt.1.attemptedAt >= route.attemptedAt else { return nil }
        return groupAttempt
    }

    private var blockedByTV: Bool {
        guard available, !inGroup, !route.starting, !stream.active else { return false }
        return (currentGroupAttempt?.1.stream ?? stream).receiversBlockedByTV.contains(route.destination.name)
    }

    private var editTVName: some View {
        Button {
            tvName = savedGroups.tvDeviceNames[route.destination.name] ?? ""
            editingTVName = true
        } label: {
            Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Имя устройства на ТВ-входе \(route.destination.name)")
        .help("Указать имя устройства на ТВ-входе")
        .popover(isPresented: $editingTVName) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Устройство на ТВ-входе").font(.headline)
                TextField("Например, LG OLED", text: $tvName)
                Button("Сохранить") {
                    savedGroups.setTVDeviceName(tvName, for: route.destination.name)
                    editingTVName = false
                }.keyboardShortcut(.defaultAction)
            }
            .padding(12).frame(width: 260)
        }
    }

    private func occupation(_ reason: String) -> String {
        reason == tvInputBusyMessage ? savedGroups.tvOccupation(for: route.destination.name) : reason
    }

    private var activityLabel: String {
        let receiver = route.destination.name
        if inGroup {
            let status: String
            if group.transmittingReceivers.contains(receiver) {
                status = "Подключена"
            } else if group.preparing {
                status = "Подготовка…"
            } else {
                status = groupStream.receivers[receiver] == "Передача" && !groupStream.stopping
                    ? "Синхронизация" : groupStream.stopping ? "Остановка…" : groupStream.receivers[receiver] ?? groupStream.status
            }
            let title = groupTitle.map { "Группа «\($0)»" } ?? "Синхронная группа"
            return [title, group.sourceName, status].compactMap { $0 }.joined(separator: " · ")
        }
        if !route.starting, !stream.active {
            if let (group, session) = currentGroupAttempt {
                if let reason = session.reason(for: receiver) {
                    return "Группа «\(group.name)» · при запуске: \(occupation(reason))"
                }
                if session.active {
                    return "Группа «\(group.name)» · передача на эту колонку выключена"
                }
                return available ? "Передача выключена" : "Колонка недоступна"
            }
            if let reason = stream.skippedReceivers[receiver] { return occupation(reason) }
        }
        let status = route.starting ? "Подготовка…" : stream.status
        if (route.starting || stream.active), let name = route.runningSourceName {
            if stream.isTransmitting && !stream.stopping && !stream.hasRecentSignal {
                return "\(name) · нет сигнала от источника"
            }
            return "\(name) · \(status)"
        }
        if !available { return "Колонка недоступна" }
        return status == "Готово к запуску" ? "Передача выключена" : status
    }

    private func start(overrideTV: Bool = false) {
        sourceError = nil
        do {
            guard let choice = route.source else { return }
            let (source, name) = try resolveSource(choice, apps: apps, inputs: inputs, playLocally: route.playLocally)
            route.start(source, name: name, clock: clock, overrideTV: overrideTV)
        } catch {
            sourceError = error.localizedDescription
        }
    }
}

@MainActor @ViewBuilder
func transmissionLabel(_ title: String, active: Bool, compact: Bool) -> some View {
    if compact {
        Label(title, systemImage: active ? "stop.fill" : "play.fill").labelStyle(.iconOnly)
            .help(title)
    } else {
        Text(title)
    }
}

struct VolumeSlider: View {
    let name: String
    @Binding var value: Double
    let showsSignalColumn: Bool
    var signal: Double? = nil
    var available = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.wave.2")
                .frame(width: 18, alignment: .leading)
                .accessibilityHidden(true)
            Slider(value: $value, in: 0...100, step: 1) { Text("Громкость \(name)") }
                .labelsHidden()
                .accessibilityLabel("Громкость \(name)")
            Text(available ? "\(Int(value.rounded()))%" : "—")
                .monospacedDigit().frame(width: 38, alignment: .trailing)
            if showsSignalColumn {
                if let signal {
                    ProgressView(value: signal).frame(width: 64)
                        .accessibilityLabel("Сигнал \(name)")
                } else {
                    Color.clear.frame(width: 64, height: 1).accessibilityHidden(true)
                }
            }
        }
    }
}

struct ConnectionIcon: View {
    static let symbol = "arrow.triangle.2.circlepath"
    let reconnecting: Bool

    var body: some View {
        let title = reconnecting ? "Переподключение" : "Подключение"
        Image(systemName: Self.symbol)
            .foregroundStyle(.orange)
            .accessibilityLabel(title)
            .help(title)
    }
}

@MainActor
func resolveSource(_ choice: RouteSourceChoice, apps: [RunningAudioApp], inputs: [AudioInput],
                           playLocally: Bool) throws -> (AudioSource, String) {
    switch choice {
    case .application(let pid):
        guard let app = apps.first(where: { $0.id == pid }) ?? RunningAudioApp.list().first(where: { $0.id == pid }) else { throw StreamError("Приложение закрыто, выбери источник заново.") }
        return (.application(try app.audioObjects(), playLocally: playLocally), app.name)
    case .device(let id):
        guard let input = inputs.first(where: { $0.id == id }) else { throw StreamError("Аудиоустройство недоступно.") }
        return (.device(id), input.name)
    }
}
