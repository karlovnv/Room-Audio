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

        init(receivers: [String]) throws {
            guard let script = Bundle.main.url(forResource: "stream", withExtension: "py"),
                  let transport = Bundle.main.url(forResource: "cliairplay", withExtension: nil) else {
                throw StreamError("AirPlay components are missing")
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
                process.arguments = [script.path, "--transport", transport.path, "--clock-only", "--"] + receivers
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
        try await acquire(token, receivers: [receiver])
    }

    func acquire(_ token: UUID, receivers: [String]) async throws -> String {
        try Task.checkCancellation()
        while let current = session, current.closing && current.process.isRunning {
            try await Task.sleep(for: .milliseconds(100))
        }
        if leases.isEmpty, let current = session, !current.process.isRunning {
            session = nil
        }
        if session == nil { session = try Session(receivers: receivers) }
        guard let current = session else { throw StreamError("Could not start PTP") }
        leases.insert(token)
        do {
            let deadline = ContinuousClock().now + .seconds(130)
            while ContinuousClock().now < deadline {
                try Task.checkCancellation()
                let events = current.events
                if let error = events.last(where: { $0["status"] == "error" })?["message"] {
                    if events.last(where: { $0["status"] == "error" })?["category"] == "local" {
                        throw LocalAirPlayOutputError(message: error)
                    }
                    throw StreamError(error)
                }
                guard current.process.isRunning else { throw StreamError("The shared PTP process exited") }
                if let address = events.last(where: { $0["status"] == "clock_ready" })?["address"] {
                    return address
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw StreamError("Timed out starting shared PTP")
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

    @MainActor
    func outputSymbol(in discovery: Discovery) -> String {
        switch self {
        case .airplay(let id): discovery.outputSymbol(for: id)
        case .bluetooth: LocalOutput.symbol
        }
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
    var transportPending: Bool { session != nil }

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
            } catch let error as LocalAirPlayOutputError {
                stream.markLocalAirPlay([destination.name], message: error.localizedDescription)
                self.error = error.localizedDescription
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
    var transportPending: Bool { session != nil }
    private var pendingMix: [MixInput]?

    var active: Bool { preparing || stream.active || !members.isEmpty }
    var isConnecting: Bool { preparing || stream.isConnecting }

    func isConnecting(to receiver: String) -> Bool {
        members.contains(receiver) && (preparing || stream.isConnecting(to: receiver))
    }

    var transmittingReceivers: Set<String> {
        guard stream.isTransmitting, !stream.stopping else { return [] }
        return members.filter { stream.receivers[$0] == "Streaming" }
    }

    func attempted(_ receiver: String) -> Bool {
        attemptedReceivers.contains(receiver) || exclusions[receiver] != nil
    }

    func reason(for receiver: String) -> String? {
        if let reason = exclusions[receiver] ?? stream.skippedReceivers[receiver] { return reason }
        if !active, attemptedReceivers.contains(receiver), let error {
            if stream.skippedReceivers.isEmpty { return error }
            return "Group stream interrupted"
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
        guard session == nil, !volumes.isEmpty else { return }
        let token = UUID()
        recordAttempt(receivers: Set(volumes.keys), exclusions: exclusions)
        hasTransmitted = false
        members = Set(volumes.keys)
        startingVolumes = volumes
        sourceName = title
        if case .mix(let inputs) = source { pendingMix = inputs }
        preparing = true
        error = nil
        session = Task {
            defer {
                clock.release(token)
                members = []
                preparing = false
                sourceName = nil
                startingVolumes = [:]
                pendingMix = nil
                session = nil
            }
            do {
                let address = try await clock.acquire(token, receivers: volumes.keys.sorted())
                try Task.checkCancellation()
                stream.start(source: pendingMix.map(AudioSource.mix) ?? source, names: volumes.keys.sorted(),
                             volumes: startingVolumes, sharedClockAddress: address, protectSonos: protectSonos,
                             overrideTV: overrideTV)
                preparing = false
                guard stream.active else { throw StreamError(stream.status) }
                while stream.active {
                    if stream.isTransmitting { hasTransmitted = true }
                    let stopped = members.filter { stream.receivers[$0] == "Stopped" }
                    if !stopped.isEmpty { members.subtract(stopped) }
                    let joined = stream.receivers.filter { ["Connecting", "Synchronizing", "Streaming"].contains($0.value) }.map(\.key)
                    if !Set(joined).isSubset(of: members) { members.formUnion(joined) }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                if stream.status != "Streaming stopped" { error = stream.status }
            } catch is CancellationError {
                return
            } catch let error as LocalAirPlayOutputError {
                stream.markLocalAirPlay(volumes.keys.sorted(), message: error.localizedDescription)
                self.error = error.localizedDescription
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func setMix(_ inputs: [MixInput], title: String) {
        guard pendingMix != nil else { return }
        pendingMix = inputs
        if sourceName != title { sourceName = title }
        stream.updateMix(inputs)
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
    @Published private(set) var offlineActiveOutputs: Set<RouteDestination.ID> = []
    @Published var groupSelection: Set<RouteDestination.ID> = []
    var volumePreferences: OutputVolumePreferences
    let airPlay = AirPlayCoordinator()
    var waitingForWake = false
    private let defaults: UserDefaults
    private var routeActivityObservers: [RouteDestination.ID: AnyCancellable] = [:]
    private var lastAvailableActiveOutputs: Set<RouteDestination.ID> = []
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
            airPlay.objectWillChange.sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            },
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
                self?.refreshSavedGroupMixes()
                if let self { airPlay.reconcile(self) }
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
            let availableIDs = Set(available.map(\.id))
            let previouslyActive = lastAvailableActiveOutputs.union(destinations.filter(hasRouteActivity).map(\.id))
            let missing = offlineActiveOutputs.union(previouslyActive).subtracting(availableIDs)
            if missing != offlineActiveOutputs { offlineActiveOutputs = missing }
            destinations = available
            groupSelection.formIntersection(availableIDs)
        }
        lastAvailableActiveOutputs = Set(available.filter(hasRouteActivity).map(\.id))
    }

    func hasRouteActivity(_ destination: RouteDestination) -> Bool {
        let route = routes[destination.id]
        if route?.starting == true || route?.stream.active == true { return true }
        if case .airplay(let id) = destination, let slot = airPlay.slots[id] {
            return !slot.claims.isEmpty || slot.connection != nil
        }
        return false
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
        airPlay.stopAll()
        airPlay.reconcile(self)
        for route in routes.values { route.stop() }
        synchronizedGroup.stop()
        savedGroups.stopAll()
    }

    var isReconnecting: Bool {
        airPlay.slots.keys.contains(where: isReconnecting(receiver:))
    }

    var isConnecting: Bool { savedGroups.isConnecting || synchronizedGroup.isConnecting ||
        routes.values.contains(where: \.isConnecting) }

    func isReconnecting(group id: UUID) -> Bool {
        airPlay.slots.keys.contains { airPlay.requested($0, by: .saved(id)) && isReconnecting(receiver: $0) }
    }

    func isReconnecting(receiver id: Receiver.ID) -> Bool {
        guard let slot = airPlay.slots[id] else { return false }
        if case .retry = slot.state { return true }
        return waitingForWake && !slot.claims.isEmpty
    }

    func stopQuickGroup() {
        airPlay.stop(.quick)
        airPlay.reconcile(self)
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
    @AppStorage("room-audio.simple-mode") private var mainWindowSimpleMode = false
    @AppStorage("room-audio.pinned-outputs") private var pinnedOutputsData = Data()
    @State private var editingVisibility = false
    @State private var installingPTP = false
    @State private var setupError: String?
    @Environment(\.openWindow) private var openWindow
    private let diagnostics: Bool
    private let menuBar: Bool

    init(workspace: RoutingWorkspace, diagnostics: Bool = false, menuBar: Bool = false) {
        self.workspace = workspace
        self.discovery = workspace.discovery
        self.synchronizedGroup = workspace.synchronizedGroup
        self.savedGroups = workspace.savedGroups
        self.diagnostics = diagnostics
        self.menuBar = menuBar
    }

    private var destinations: [RouteDestination] { workspace.destinations }
    private var routes: [RouteDestination.ID: OutputRoute] { workspace.routes }
    private var apps: [RunningAudioApp] { workspace.apps }
    private var inputs: [AudioInput] { workspace.inputs }
    private var clock: SharedPTP { workspace.clock }
    private var simpleMode: Bool { menuBar || mainWindowSimpleMode }

    var body: some View {
        Group {
            if menuBar {
                compactPanel.frame(width: 440)
            } else if simpleMode {
                compactPanel.frame(minWidth: 440, idealWidth: 600, maxWidth: .infinity,
                                   minHeight: 320, maxHeight: .infinity, alignment: .topLeading)
            } else {
                detailedPanel
            }
        }
        .task { workspace.start() }
        .task {
            guard diagnostics else { return }
            if CommandLine.arguments.contains("--verify-saved-groups") {
                verifySavedGroups()
            } else if CommandLine.arguments.contains("--verify-routing-handoff"), !workspace.checkingPTPService {
                workspace.checkingPTPService = true
                await verifyRoutingHandoff()
            } else if CommandLine.arguments.contains("--verify-group-recovery"), !workspace.checkingPTPService {
                workspace.checkingPTPService = true
                Task {
                    do {
                        guard let group = savedGroups.groups.first(where: { $0.name == "All Sonos" }),
                              let session = savedGroups.session(for: group.id) else {
                            throw StreamError("All Sonos group not found.")
                        }
                        try await waitForPTPTest("output discovery") {
                            group.members.isSubset(of: Set(destinations.compactMap {
                                if case .airplay(let id) = $0 { id } else { nil }
                            }))
                        }
                        workspace.startSavedGroup(group, session: session)
                        try await waitForPTPTest("All Sonos streaming", timeout: 90) {
                            session.transmittingReceivers == Set(group.members.map(\.name)) ||
                                (!session.active && workspace.airPlay.runs[.saved(group.id)] == nil && session.error != nil)
                        }
                        guard let anchor = session.stream.scheduledStart else {
                            throw StreamError(session.error ?? "Synchronized start was not confirmed.")
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

    private var detailedPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Room Audio").font(menuBar ? .title2.bold() : .largeTitle.bold())
                    if !simpleMode {
                        Text(discovery.status).font(.caption).foregroundStyle(.secondary)
                        if !SharedPTP.serviceInstalled {
                            Button("Set Up AirPlay Sync…", action: installPTP).disabled(installingPTP)
                        }
                        if let setupError { Text(setupError).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                Spacer()
                panelMenu
            }
            if !simpleMode || workspace.airPlay.runs[.quick] != nil {
                HStack {
                    if workspace.airPlay.runs[.quick] == nil {
                        Button("Start in Sync", action: startGroup)
                            .buttonStyle(.borderedProminent)
                            .disabled(workspace.groupSelection.count < 2)
                        Text("Select AirPlay outputs that use the same source.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("Stop Group", action: workspace.stopQuickGroup)
                        Text(synchronizedGroup.preparing ? "Preparing group…" : "Synchronized Group")
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
                    Text("Choose which outputs to show in Output Visibility.")
                        .foregroundStyle(.secondary)
                } else if !simpleMode && destinations.isEmpty {
                    Text("Waiting for outputs…").foregroundStyle(.secondary)
                }
                if simpleMode {
                    group("Outputs", visible)
                } else {
                    group("AirPlay", visible.filter(\.isAirPlay))
                    group("Bluetooth", visible.filter { !$0.isAirPlay })
                }
                group("Unavailable Outputs", missing, available: false)
            }.listStyle(.inset)
        }
        .padding(20)
        .frame(minWidth: 510, minHeight: 390)
    }

    private var panelMenu: some View {
        Menu {
            if menuBar {
                Button("Open Main Window") { RoomAudioDelegate.openMainWindow(openWindow) }
            } else {
                Button("New Group…") { RoomAudioDelegate.openGroupWindow(openWindow, id: UUID()) }
            }
            Button("Output Visibility") { editingVisibility = true }
            if !menuBar { Toggle("Simple Mode", isOn: $mainWindowSimpleMode) }
            Divider()
            Button("Stop All", action: workspace.stopAll)
            Button("Quit Room Audio") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis").frame(width: 24)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Settings and Actions")
        .help("Settings and Actions")
    }

    private var compactPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(editingVisibility ? "Output Visibility" : "Room Audio").font(.headline)
                Spacer()
                if editingVisibility {
                    Button("Done") { editingVisibility = false }
                } else {
                    panelMenu
                }
            }
            if editingVisibility {
                CompactPanelScroll(maximumHeight: 260, content: compactVisibilityOptions)
            } else {
                CompactPanelScroll(maximumHeight: 460, content: compactRoutes)
            }
        }
        .padding(16)
    }

    private var compactVisibilityOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Always Show in Simple Mode")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            visibilityOptions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactRoutes: some View {
        let availableIDs = Set(destinations.map(\.id))
        let outputs = knownDestinations.filter(isVisible)
        return VStack(alignment: .leading, spacing: 12) {
            if workspace.airPlay.runs[.quick] != nil {
                Button("Stop Synchronized Group", action: workspace.stopQuickGroup)
            }
            if !savedGroups.groups.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Groups").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(savedGroups.groups) { group in
                        if let session = savedGroups.session(for: group.id) {
                            SavedGroupRow(group: group, session: session, stream: session.stream,
                                          workspace: workspace, groups: savedGroups, simpleMode: true, compact: true,
                                          allowsGroupEditing: !menuBar)
                        }
                    }
                }
            }
            if !outputs.isEmpty {
                if !savedGroups.groups.isEmpty { Divider() }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Outputs").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(outputs) { destination in
                        routeRow(destination, available: availableIDs.contains(destination.id), compact: true)
                    }
                }
            } else if savedGroups.groups.isEmpty {
                Text("Choose which outputs to show in Output Visibility.").foregroundStyle(.secondary)
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
            setupError = "PTP service components are missing."
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
                if status != 0 { setupError = "PTP service installation did not complete." }
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
        Section("Always Show in Simple Mode") {
            visibilityOptions
        }
    }

    @ViewBuilder private var visibilityOptions: some View {
        let pinnable = knownDestinations.filter { !isLocalAirPlay($0) }
        if pinnable.isEmpty {
            Text("Waiting for outputs…").foregroundStyle(.secondary)
        }
        ForEach(pinnable, id: \.visibilityKey) { destination in
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
                    Label(destination.name, systemImage: destination.outputSymbol(in: discovery))
                    if !names.isEmpty {
                        Text(names.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.toggleStyle(.checkbox)
        }
    }

    private func isVisible(_ destination: RouteDestination) -> Bool {
        guard simpleMode else { return true }
        guard !isLocalAirPlay(destination),
              routes[destination.id] != nil || destinations.contains(destination) else { return false }
        if pinnedOutputs.contains(destination.visibilityKey) { return true }
        if case .airplay(let id) = destination, workspace.isReconnecting(receiver: id) { return true }
        return workspace.offlineActiveOutputs.contains(destination.id) || workspace.hasRouteActivity(destination)
    }

    private func isLocalAirPlay(_ destination: RouteDestination) -> Bool {
        guard case .airplay(let id) = destination else { return false }
        return discovery.localReceiverIDs.contains(id)
    }

    @ViewBuilder private func group(_ title: String, _ destinations: [RouteDestination], available: Bool = true) -> some View {
        if !destinations.isEmpty {
            Section(title) {
                ForEach(destinations) { destination in
                    routeRow(destination, available: available)
                }
            }
        }
    }

    @ViewBuilder private func routeRow(_ destination: RouteDestination, available: Bool, compact: Bool = false) -> some View {
        let receiverID: Receiver.ID? = if case .airplay(let id) = destination { id } else { nil }
        let outputIcon = destination.outputSymbol(in: discovery)
        if let route = routes[destination.id] {
            let currentRoute = receiverID.flatMap { workspace.airPlay.slots[$0]?.connection?.run.route }
            let savedGroup = currentRoute.flatMap(workspace.savedGroupForRoute)
            let owner = savedGroup.flatMap { savedGroups.session(for: $0.id) } ?? synchronizedGroup
            RouteRow(route: route, stream: route.stream, apps: apps, inputs: inputs,
                     available: available, simpleMode: simpleMode, outputIcon: outputIcon,
                     reconnecting: receiverID.map { workspace.isReconnecting(receiver: $0) } ?? false,
                     clock: clock, group: owner, groupStream: owner.stream,
                     receiverID: receiverID,
                     workspace: workspace,
                     savedGroups: savedGroups,
                     compact: compact,
                     groupSelected: Binding(
                        get: { workspace.groupSelection.contains(destination.id) },
                        set: { if $0 { workspace.groupSelection.insert(destination.id) } else { workspace.groupSelection.remove(destination.id) } }
                     ))
        } else if compact {
            HStack(spacing: CompactRouteLayout.iconSpacing) {
                CompactRouteLayout.icon(outputIcon)
                Text("\(destination.name) · unavailable")
            }
            .foregroundStyle(.secondary)
        } else {
            Label(destination.name, systemImage: outputIcon).foregroundStyle(.secondary)
        }
    }

    private func verifyRoutingHandoff() async {
        do {
            guard let all = savedGroups.groups.first(where: { $0.name == "All Sonos" }),
                  let vibe = savedGroups.groups.first(where: { $0.name == "Kitchen Vibe" }),
                  let kitchen = all.members.first(where: { $0.name == "Kitchen" }),
                  let living = all.members.first(where: { $0.name == "Living Room" }),
                  vibe.members.contains(kitchen), !vibe.configuredInputs.isEmpty,
                  let allSession = savedGroups.session(for: all.id),
                  let vibeSession = savedGroups.session(for: vibe.id) else {
                throw StreamError("Set up sources for All Sonos and Kitchen Vibe before running this check.")
            }
            try await waitForPTPTest("Kitchen and Living Room discovery") {
                destinations.contains(.airplay(kitchen)) && destinations.contains(.airplay(living))
            }
            workspace.startSavedGroup(all, session: allSession)
            try await waitForPTPTest("All Sonos startup", timeout: 75) {
                workspace.airPlay.playing(.saved(all.id)).isSuperset(of: [kitchen, living])
            }
            let original = workspace.airPlay.slots[living]?.connection
            print("HANDOFF_BASELINE Both speakers active")
            fflush(nil)

            workspace.attachSavedReceiver(kitchen, group: vibe, session: vibeSession, takeover: true)
            try await waitForPTPTest("moving Kitchen to Kitchen Vibe", timeout: 75) {
                workspace.airPlay.playing(.saved(vibe.id)).contains(kitchen)
            }
            guard workspace.airPlay.slots[living]?.connection == original else { throw StreamError("Living Room reconnected.") }
            print("HANDOFF_TO_VIBE Kitchen active, Living Room session unchanged")
            fflush(nil)

            workspace.stopSavedGroup(vibe, session: vibeSession)
            try await waitForPTPTest("returning Kitchen to All Sonos", timeout: 75) {
                workspace.airPlay.playing(.saved(all.id)).contains(kitchen)
            }
            guard workspace.airPlay.slots[living]?.connection == original else { throw StreamError("Living Room reconnected.") }
            print("HANDOFF_RETURN Kitchen restored, Living Room session unchanged")
            fflush(nil)

            workspace.stopReceiver(kitchen)
            try await waitForPTPTest("stopping Kitchen manually") {
                workspace.airPlay.slots[kitchen]?.connection == nil
            }
            try await Task.sleep(for: .seconds(2))
            guard !workspace.airPlay.requested(kitchen, by: .saved(all.id)),
                  workspace.airPlay.slots[kitchen]?.connection == nil else {
                throw StreamError("Kitchen reconnected after a manual stop.")
            }
            workspace.attachSavedReceiver(kitchen, group: all, session: allSession)
            try await waitForPTPTest("connecting Kitchen manually", timeout: 60) {
                workspace.airPlay.playing(.saved(all.id)).contains(kitchen)
            }
            guard workspace.airPlay.slots[living]?.connection == original else { throw StreamError("Living Room reconnected.") }
            print("HANDOFF_PASSED Manual stop and attach confirmed")
        } catch {
            print("HANDOFF_ERROR \(error.localizedDescription)")
        }
        fflush(nil)
    }

    private func startGroup() {
        synchronizedGroup.error = nil
        let groupRoutes = destinations.filter { workspace.groupSelection.contains($0.id) && $0.isAirPlay }
            .compactMap { routes[$0.id] }
        do {
            guard groupRoutes.count > 1, let first = groupRoutes.first else { return }
            guard let choice = first.source, groupRoutes.allSatisfy({ $0.source == choice }) else {
                throw StreamError("Choose the same source for all selected outputs.")
            }
            if case .application = choice, !groupRoutes.allSatisfy({ $0.playLocally == first.playLocally }) {
                throw StreamError("Use the same “Also Play on This Mac” setting for every output in the group.")
            }
            let (source, _) = try resolveSource(choice, apps: apps, inputs: inputs, playLocally: first.playLocally)
            let receivers = Set(groupRoutes.compactMap {
                if case .airplay(let id) = $0.destination { id } else { nil }
            })
            workspace.airPlay.start(.quick, name: "Synchronized Group", receivers: receivers,
                                   backend: .group(synchronizedGroup), source: source)
            workspace.airPlay.reconcile(workspace)

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
            guard let anchor = stream.scheduledStart, stream.receivers["Kitchen"] == "Streaming",
                  stream.receivers["Living Room"] == "Streaming" else { throw StreamError("Shared start not confirmed") }
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
                if stream.receivers["Kitchen"] == "Stopped" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard stream.receivers["Kitchen"] == "Stopped", stream.receivers["Living Room"] == "Streaming",
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
                throw StreamError("The PTP service or All Sonos group was not found.")
            }
            session = savedSession
            let names = Set(group.members.map(\.name))
            guard names == ["Kitchen", "Living Room"] else { throw StreamError("All Sonos has unexpected outputs.") }
            try await waitForPTPTest("outputs and main window") {
                names.isSubset(of: Set(destinations.filter(\.isAirPlay).map(\.name))) &&
                    NSApp.windows.contains { $0.isVisible && $0.title == "Room Audio" }
            }
            let initialVolumes = testVolume ? ["Kitchen": 30, "Living Room": 60] : ["Kitchen": 45, "Living Room": 45]
            if testVolume {
                for member in group.members {
                    guard let route = routes[.airplay(member)], let level = initialVolumes[member.name] else {
                        throw StreamError("\(member.name) is unavailable.")
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
                try await waitForPTPTest("audio source") { (try? app.audioObjects().isEmpty) == false }
                savedSession.start(.application(try app.audioObjects(), playLocally: false), title: app.name,
                                   volumes: initialVolumes, clock: clock, protectSonos: true)
                try await waitForPTPTest("audio capture") {
                    savedSession.stream.status == "Synchronizing AirPlay…" ||
                        savedSession.stream.isTransmitting || (!savedSession.active && savedSession.error != nil)
                }
                try Data().write(to: cue)
                try await waitForPTPTest("both outputs connecting") {
                    savedSession.transmittingReceivers == names || (!savedSession.active && savedSession.error != nil)
                }
                guard savedSession.transmittingReceivers == names, clock.usesInstalledService,
                      let anchor = savedSession.stream.scheduledStart else {
                    throw StreamError(savedSession.error ?? "The outputs did not confirm startup through the installed service.")
                }
                print("ALL_SONOS_SOURCE_\(index + 1)_STARTED_WITHOUT_AUTHORIZATION_EVENT anchor=\(anchor)")
                fflush(nil)
                try await waitForPTPTest("audio signal") { savedSession.stream.signalLevel > 0.02 }
                if testVolume {
                    try await verifyLiveGroupVolume(group, session: savedSession, anchor: anchor)
                } else if index == 0 {
                    guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Room Audio" }) else {
                        throw StreamError("Room Audio window not found.")
                    }
                    window.performClose(nil)
                    try await waitForPTPTest("closing the window") { !window.isVisible }
                    var peak: Float = 0
                    for _ in 0..<35 {
                        guard savedSession.transmittingReceivers == names,
                              savedSession.stream.scheduledStart == anchor else {
                            throw StreamError("The All Sonos session changed after the window closed: \(savedSession.stream.status)")
                        }
                        peak = max(peak, savedSession.stream.signalLevel)
                        try await Task.sleep(for: .milliseconds(120))
                    }
                    guard peak > 0.02 else { throw StreamError("No audio signal was detected after the window closed.") }
                    print("WINDOW_CLOSED_BOTH_RECEIVERS_CONTINUED peak=\(peak)")
                    fflush(nil)
                    try await Task.sleep(for: .seconds(6))
                } else {
                    try await Task.sleep(for: .seconds(12))
                    guard savedSession.transmittingReceivers == names else {
                        throw StreamError("The second source did not continue streaming to both outputs.")
                    }
                }
                savedSession.stop()
                try await waitForPTPTest("stopping the group") { !savedSession.active && !clock.isRunning }
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
        try? await waitForPTPTest("test cleanup") { !clock.isRunning }
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
                throw StreamError("Incorrect group balance at \(maximum)%.")
            }
            print("GROUP_VOLUME_SET \(maximum / 2) \(maximum) anchor=\(anchor)")
            fflush(nil)
            var peak: Float = 0
            for _ in 0..<42 {
                try await Task.sleep(for: .milliseconds(120))
                guard session.transmittingReceivers == ["Kitchen", "Living Room"],
                      session.stream.scheduledStart == anchor else {
                    throw StreamError("Streaming was interrupted at \(maximum)%.")
                }
                peak = max(peak, session.stream.signalLevel)
            }
            guard peak > 0.02 else { throw StreamError("Audio capture was lost at \(maximum)%.") }
            print("GROUP_VOLUME_SIGNAL \(maximum) peak=\(peak)")
            fflush(nil)
        }
        print("GROUP_VOLUME_TEST_PASSED")
    }

    private func waitForPTPTest(_ stage: String, timeout: Int = 25, ready: () -> Bool) async throws {
        let deadline = ContinuousClock().now + .seconds(timeout)
        while !ready() {
            guard ContinuousClock().now < deadline else { throw StreamError("Timed out waiting for \(stage).") }
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
    let outputIcon: String
    let reconnecting: Bool
    let clock: SharedPTP
    @ObservedObject var group: SynchronizedGroup
    @ObservedObject var groupStream: Streaming
    let receiverID: Receiver.ID?
    let workspace: RoutingWorkspace
    @ObservedObject var savedGroups: SpeakerGroups
    let compact: Bool
    @Binding var groupSelected: Bool
    @State private var sourceError: String?
    @State private var editingTVName = false
    @State private var tvName = ""

    var body: some View {
        Group {
            if compact { compactRow }
            else { detailedRow }
        }
        .onChange(of: route.source) { _, _ in sourceError = nil }
    }

    private var detailedRow: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(route.destination.name, systemImage: outputIcon)
                    .font(.headline)
                if connecting {
                    ConnectionIcon(reconnecting: reconnecting)
                }
                Spacer()
                if !simpleMode && route.destination.isAirPlay && available {
                    Toggle("Add to Group", isOn: $groupSelected).toggleStyle(.checkbox)
                        .disabled(!group.members.isEmpty || route.starting || stream.active)
                }
                if blockedByTV { forcePlay }
                transmissionControl
            }
            if !simpleMode && !inGroup {
                HStack {
                    RouteSourcePicker(title: route.starting || stream.active ? "Next Source" : "Source",
                                      apps: apps, inputs: inputs, selection: $route.source)
                    if case .application = route.source {
                        Toggle("Also Play on This Mac", isOn: $route.playLocally).toggleStyle(.checkbox)
                    }
                }
            }
            volumeControl
            if !simpleMode || activityLabel != "Streaming off" {
                HStack(spacing: 6) {
                    Text(activityLabel).foregroundStyle(.secondary).font(.caption)
                    if blockedByTV { editTVName }
                }
            }
            if let message = sourceError ?? route.error, message != activityLabel {
                Text(message).foregroundStyle(.secondary).font(.caption)
            }

        }
        .padding(.vertical, 6)
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                volumeControl.disabled(!available)
                transmissionControl
                    .buttonStyle(CompactSpeakerButtonStyle())
                    .frame(width: 28)
            }
            let status = compactStatus
            if blockedByTV || status != nil {
                HStack(spacing: 6) {
                    if let status { Text(status) }
                    if blockedByTV {
                        forcePlay
                        editTVName
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, CompactRouteLayout.titleInset)
            }
        }
        .padding(.vertical, 2)
        .grayscale(available ? 0 : 1)
        .opacity(available ? 1 : 0.55)
    }

    private var compactStatus: String? {
        let status = activityLabel
        return status == "Streaming off" ? nil : status
    }

    private var volumeControl: some View {
        VolumeSlider(name: route.destination.name,
                     value: Binding(get: { route.volume }, set: { workspace.setRouteVolume($0, route: route) }),
                     showsSignalColumn: !simpleMode, signal: normalizedSignal,
                     caption: compact ? route.destination.name : nil,
                     connection: compact && connecting ? ConnectionIcon(reconnecting: reconnecting) : nil,
                     captionIcon: compact ? outputIcon : nil)
    }

    private var connecting: Bool {
        if case .connecting = outputSlot?.state { return true }
        return reconnecting || route.isConnecting
    }

    @ViewBuilder private var forcePlay: some View {
        if let receiverID, let run = outputSlot?.claims.first?.run {
            ForcePlayButton(receiver: route.destination.name) {
                workspace.airPlay.attach(receiverID, to: run.route, takeover: true)
                workspace.airPlay.reconcile(workspace)
            }
        } else {
            ForcePlayButton(receiver: route.destination.name) { start(overrideTV: true) }
                .disabled(route.source == nil && !individualRequested)
        }
    }

    @ViewBuilder private var transmissionControl: some View {
        if inGroup {
            let stopping = groupStream.receivers[route.destination.name] == "Stopping…" || groupStream.stopping
            Button {
                if let receiverID { workspace.stopReceiver(receiverID) }
            } label: {
                transmissionLabel(stopping ? "Stopping…" : "Stop", active: true, compact: simpleMode)
            }
            .accessibilityLabel("Stop \(route.destination.name)")
            .disabled(group.preparing || stopping)
        } else if route.starting || stream.active || individualRequested {
            Button(action: stopIndividual) {
                transmissionLabel(stream.stopping ? "Stopping…" : "Stop", active: true, compact: simpleMode)
            }
            .accessibilityLabel("Stop \(route.destination.name)")
            .disabled(stream.stopping)
        } else {
            let title = "Start"
            let button = Button {
                start()
            } label: {
                transmissionLabel(title, active: false, compact: simpleMode)
            }
            .accessibilityLabel("\(title) \(route.destination.name)")
            .disabled(route.source == nil || !available)
            if compact {
                button
            } else {
                button.buttonStyle(.borderedProminent)
            }
        }
    }

    private var outputSlot: OutputSlot? {
        receiverID.flatMap { workspace.airPlay.slots[$0] }
    }

    private var inGroup: Bool {
        guard let route = outputSlot?.connection?.run.route else { return false }
        if case .individual = route { return false }
        return true
    }

    private var normalizedSignal: Double {
        let peak = Double(inGroup ? groupStream.signalLevel : stream.signalLevel)
        return peak > 0 ? max(0, min(1, (20 * log10(peak) + 60) / 60)) : 0
    }

    private var blockedByTV: Bool {
        if case .external(let external, _) = outputSlot?.availability { return external.kind == .tv }
        return false
    }

    private var editTVName: some View {
        Button {
            tvName = savedGroups.tvDeviceNames[route.destination.name] ?? ""
            editingTVName = true
        } label: {
            Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("TV input device name for \(route.destination.name)")
        .help("Name the TV input device")
        .popover(isPresented: $editingTVName) {
            VStack(alignment: .leading, spacing: 8) {
                Text("TV Input Device").font(.headline)
                TextField("For example, LG OLED", text: $tvName)
                Button("Save") {
                    savedGroups.setTVDeviceName(tvName, for: route.destination.name)
                    editingTVName = false
                }.keyboardShortcut(.defaultAction)
            }
            .padding(12).frame(width: 260)
        }
    }

    private var activityLabel: String {
        if let sourceError { return sourceError }
        if !available { return "Output unavailable" }
        if let slot = outputSlot {
            switch slot.availability {
            case .offline: return "Output unavailable"
            case .external(let external, _):
                return external.kind == .tv ? savedGroups.tvOccupation(for: route.destination.name) : external.description
            case .unsupported(let reason): return reason
            case .unknown: return "Checking availability…"
            case .available: break
            }
            switch slot.state {
            case .connected(let connection):
                return inGroup && !compact ? "Via \(connection.run.name)" : connection.run.name
            case .connecting(let connection): return "\(connection.run.name) · Connecting…"
            case .releasing: return "Stopping…"
            case .retry(_, let reason): return reason
            case .idle: return "Waiting to connect"
            }
        }
        if let error = route.error { return error }
        if stream.active { return [route.runningSourceName, stream.status].compactMap { $0 }.joined(separator: " · ") }
        return "Streaming off"
    }

    private var individualRequested: Bool {
        receiverID.map { workspace.airPlay.runs[.individual($0)] != nil } ?? false
    }

    private func stopIndividual() {
        if let receiverID {
            workspace.airPlay.stop(.individual(receiverID))
            workspace.airPlay.reconcile(workspace)
        } else {
            route.stop()
        }
    }

    private func start(overrideTV: Bool = false) {
        sourceError = nil
        if overrideTV, let receiverID, workspace.airPlay.runs[.individual(receiverID)] != nil {
            workspace.airPlay.attach(receiverID, to: .individual(receiverID), takeover: true)
            workspace.airPlay.reconcile(workspace)
            return
        }
        do {
            guard let choice = route.source else { return }
            let (source, name) = try resolveSource(choice, apps: apps, inputs: inputs, playLocally: route.playLocally)
            if let receiverID {
                let key = AirPlayRoute.individual(receiverID)
                workspace.airPlay.start(key, name: name, receivers: [receiverID], backend: .individual(route),
                                        source: source, takeover: overrideTV ? receiverID : nil)
                workspace.airPlay.reconcile(workspace)
            } else {
                route.start(source, name: name, clock: clock, overrideTV: overrideTV)
            }
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

private struct CompactSpeakerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CompactSpeakerButton(label: configuration.label, pressed: configuration.isPressed)
    }

    private struct CompactSpeakerButton<Label: View>: View {
        let label: Label
        let pressed: Bool
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        @State private var hovering = false

        var body: some View {
            label
                .frame(width: 28, height: 22)
                .foregroundStyle(enabled ? Color.primary : Color.secondary)
                .background {
                    if enabled && (hovering || focused || pressed) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(pressed ? 0.18 : 0.10))
                    }
                }
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

private struct CompactPanelScroll<Content: View>: View {
    let maximumHeight: CGFloat
    let content: Content
    @State private var contentHeight: CGFloat?

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                    contentHeight = $0
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(maximumHeight, contentHeight ?? maximumHeight))
    }
}

enum CompactRouteLayout {
    static let captionWidth: CGFloat = 134
    static let iconWidth: CGFloat = 18
    static let iconSpacing: CGFloat = 6
    static var titleInset: CGFloat { iconWidth + iconSpacing }

    static func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .frame(width: iconWidth)
            .accessibilityHidden(true)
    }
}

struct VolumeSlider: View {
    let name: String
    @Binding var value: Double
    let showsSignalColumn: Bool
    var signal: Double? = nil
    var available = true
    var caption: String? = nil
    var connection: ConnectionIcon? = nil
    var captionIcon: String? = nil
    var hidesCaption = false

    @ViewBuilder private var slider: some View {
        if caption == nil && !hidesCaption {
            Slider(value: $value, in: 0...100, step: 1) { Text("Volume \(name)") }
        } else {
            Slider(value: Binding(get: { value }, set: { value = $0.rounded() }), in: 0...100) {
                Text("Volume \(name)")
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if hidesCaption {
                EmptyView()
            } else if let caption {
                HStack(spacing: CompactRouteLayout.iconSpacing) {
                    if let captionIcon { CompactRouteLayout.icon(captionIcon) }
                    Text(caption).lineLimit(1).truncationMode(.tail)
                    connection
                }
                    .frame(width: CompactRouteLayout.captionWidth, alignment: .leading)
                    .help(caption)
            } else {
                Image(systemName: "speaker.wave.2")
                    .frame(width: 18, alignment: .leading)
                    .accessibilityHidden(true)
            }
            slider
                .labelsHidden()
                .accessibilityLabel("Volume \(name)")
            Text(available ? "\(Int(value.rounded()))%" : "—")
                .monospacedDigit().frame(width: 38, alignment: .trailing)
            if showsSignalColumn {
                if let signal {
                    ProgressView(value: signal).frame(width: 64)
                        .accessibilityLabel("Signal \(name)")
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
        let title = reconnecting ? "Reconnecting" : "Connecting"
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
        guard let app = apps.first(where: { $0.id == pid }) ?? RunningAudioApp.list().first(where: { $0.id == pid }) else { throw StreamError("The app is closed. Choose a source again.") }
        return (.application(try app.audioObjects(), playLocally: playLocally), app.name)
    case .device(let id):
        guard let input = inputs.first(where: { $0.id == id }) else { throw StreamError("Audio device unavailable.") }
        return (.device(id), input.name)
    }
}
