import Combine
import Foundation

struct BluetoothGroupOutput: Codable, Identifiable, Equatable {
    let uid: String
    var name: String
    var balance = 0
    var delayMilliseconds = 0
    var id: String { uid }

    init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }

    init?(_ output: LocalOutput) {
        guard let uid = output.uid else { return nil }
        self.init(uid: uid, name: output.name)
    }

    func configure(_ player: LocalPlayback, volume: Int) {
        player.level.store(volume, ordering: .relaxed)
        player.balance.store(balance, ordering: .relaxed)
        player.delayMilliseconds.store(delayMilliseconds, ordering: .relaxed)
    }
}

struct BluetoothGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var source: SavedGroupSource
    var outputs: [BluetoothGroupOutput]
}

enum BluetoothMemberState: Equatable {
    case idle, stopped, unavailable, waitingForSource, connecting, connected
    case busy(String)
    case retrying(String)

    var description: String {
        switch self {
        case .idle: "Available"
        case .stopped: "Stopped"
        case .unavailable: "Output unavailable"
        case .waitingForSource: "Waiting for source"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .busy(let owner): "In use by \(owner)"
        case .retrying(let reason): reason
        }
    }

    var isRetrying: Bool {
        if case .retrying = self { return true }
        return false
    }
}

struct BluetoothGroupStatus: Equatable {
    var members: [String: BluetoothMemberState] = [:]
    var sourceMessage: String?
    var hasRecentSignal = false
    var connected: Int { members.values.filter { $0 == .connected }.count }
    var connecting: Bool { members.values.contains(.connecting) }
    var reconnecting: Bool { members.values.contains(where: \.isRetrying) }
}

@MainActor
final class BluetoothGroups: ObservableObject {
    @Published private(set) var groups: [BluetoothGroup]
    @Published private(set) var active: [UUID] = []
    @Published private(set) var statuses: [UUID: BluetoothGroupStatus] = [:]
    @Published private(set) var owners: [String: UUID] = [:]
    private var sessions: [UUID: BluetoothGroupPlayback] = [:]
    private var requests: [String: [UUID]] = [:]
    private let defaults: UserDefaults
    private let key = "room-audio.bluetooth-groups.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        groups = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([BluetoothGroup].self, from: $0) } ?? []
    }

    @discardableResult func save(_ group: BluetoothGroup) -> Bool {
        var saved = group
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if active.contains(saved.id), let current = groups.first(where: { $0.id == saved.id }) {
            saved.outputs = current.outputs
        }
        var seen = Set<String>()
        saved.outputs = saved.outputs.filter { !$0.uid.isEmpty && seen.insert($0.uid).inserted }
        guard !saved.name.isEmpty, !saved.outputs.isEmpty else { return false }
        if let index = groups.firstIndex(where: { $0.id == saved.id }) {
            groups[index] = saved
        } else {
            groups.append(saved)
        }
        persist()
        return true
    }

    func remove(_ id: UUID) {
        guard !active.contains(id) else { return }
        groups.removeAll { $0.id == id }
        persist()
    }

    func start(_ id: UUID) {
        guard !active.contains(id), let group = groups.first(where: { $0.id == id }) else { return }
        sessions[id] = BluetoothGroupPlayback()
        active.append(id)
        for output in group.outputs { request(output.uid, in: id, enabled: true) }
    }

    func stop(_ id: UUID) {
        sessions.removeValue(forKey: id)?.stop()
        for uid in Array(requests.keys) { request(uid, in: id, enabled: false) }
        active.removeAll { $0 == id }
    }

    func stopAll() {
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        requests.removeAll()
        active.removeAll()
        statuses.removeAll()
        owners.removeAll()
    }

    func request(_ uid: String, in id: UUID, enabled: Bool) {
        guard active.contains(id) else { return }
        var queue = requests[uid, default: []]
        if enabled {
            guard !queue.contains(id),
                  groups.first(where: { $0.id == id })?.outputs.contains(where: { $0.uid == uid }) == true else { return }
            queue.append(id)
        } else {
            queue.removeAll { $0 == id }
        }
        requests[uid] = queue.isEmpty ? nil : queue
    }

    func owner(of uid: String) -> BluetoothGroup? {
        owners[uid].flatMap { id in groups.first { $0.id == id } }
    }

    func setVolume(_ volume: Int, for uid: String) {
        guard let id = owners[uid] else { return }
        sessions[id]?.setVolume(volume, for: uid)
    }

    func updateOutput(_ output: BluetoothGroupOutput, in id: UUID, volume: Int) {
        guard let index = groups.firstIndex(where: { $0.id == id }),
              let slot = groups[index].outputs.firstIndex(where: { $0.uid == output.uid }) else { return }
        groups[index].outputs[slot] = output
        sessions[id]?.configure(output, volume: volume)
        persist()
    }

    func reconcile(available: [String: LocalOutput], standalone: [String: String], sleeping: Bool,
                   source: (SavedGroupSource) -> (AudioSource?, String?), volume: (String) -> Int) {
        let running = active.compactMap { id in groups.first { $0.id == id } }
        let claims = requests.filter { standalone[$0.key] == nil }.compactMapValues(\.first)
        if owners != claims { owners = claims }

        var plans: [UUID: (source: AudioSource?, message: String?, outputs: [String: LocalOutput])] = [:]
        for group in running {
            let outputs = available.filter { claims[$0.key] == group.id }
            let (input, message) = sleeping ? (nil, "Waiting for Mac to wake") : source(group.source)
            plans[group.id] = (input, message, outputs)
            sessions[group.id]?.prepare(source: input, outputs: outputs)
        }

        // Release old leases before any new owner opens a device.
        var updates: [UUID: BluetoothGroupStatus] = [:]
        for group in running {
            guard let session = sessions[group.id], let plan = plans[group.id] else { continue }
            let now = ContinuousClock().now
            session.startCaptureIfNeeded(at: now)
            var status = BluetoothGroupStatus(sourceMessage: plan.message ?? session.captureFailure?.message)
            for output in group.outputs {
                let uid = output.uid
                if requests[uid]?.contains(group.id) != true {
                    status.members[uid] = .stopped
                } else if let name = standalone[uid] {
                    status.members[uid] = .busy(name)
                } else if let id = claims[uid], id != group.id, let owner = running.first(where: { $0.id == id }) {
                    status.members[uid] = .busy(owner.name)
                } else if let device = plan.outputs[uid] {
                    status.members[uid] = session.connect(device, output: output, volume: volume(uid), at: now)
                } else {
                    status.members[uid] = .unavailable
                }
            }
            session.publishPlayers()
            status.hasRecentSignal = session.hasRecentSignal(at: now)
            updates[group.id] = status
        }
        if statuses != updates { statuses = updates }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(groups) { defaults.set(data, forKey: key) }
    }
}

@MainActor
private final class BluetoothGroupPlayback {
    struct Retry {
        let message: String
        let at: ContinuousClock.Instant
    }

    private struct Connection {
        let device: LocalOutput
        let player: LocalPlayback
        var frames = 0
        var lastProgress: ContinuousClock.Instant
    }

    private let fanout = LocalPlaybackFanout()
    private var capture: Capture?
    private var tap: AppAudioTap?
    private var source: AudioSource?
    private var connections: [String: Connection] = [:]
    private var retries: [String: Retry] = [:]
    private var targetsChanged = false
    private var lastSignalAt: ContinuousClock.Instant?
    private(set) var captureFailure: Retry?

    func setVolume(_ volume: Int, for uid: String) {
        connections[uid]?.player.level.store(volume, ordering: .relaxed)
    }

    func configure(_ output: BluetoothGroupOutput, volume: Int) {
        guard let player = connections[output.uid]?.player else { return }
        output.configure(player, volume: volume)
    }

    func hasRecentSignal(at now: ContinuousClock.Instant) -> Bool {
        if let peak = capture?.peak.exchange(0, ordering: .relaxed), Float(bitPattern: peak) > 0.0001 {
            lastSignalAt = now
        }
        return lastSignalAt.map { now - $0 < .milliseconds(1500) } ?? false
    }

    func prepare(source: AudioSource?, outputs: [String: LocalOutput]) {
        let source = outputs.isEmpty ? nil : source
        if self.source != source {
            stop()
            self.source = source
        }
        for (uid, connection) in connections where connection.device.id != outputs[uid]?.id {
            disconnect(uid)
        }
        retries = retries.filter { outputs[$0.key] != nil }
    }

    func startCaptureIfNeeded(at now: ContinuousClock.Instant) {
        guard capture == nil, let source, captureFailure.map({ $0.at <= now }) ?? true else { return }
        do {
            let (capture, tap) = try Capture.make(source, fd: nil, fanout: fanout)
            do { try capture.start() } catch {
                capture.stop()
                throw error
            }
            self.capture = capture
            self.tap = tap
            captureFailure = nil
        } catch {
            captureFailure = Retry(message: error.localizedDescription, at: now + .seconds(3))
        }
    }

    func connect(_ device: LocalOutput, output: BluetoothGroupOutput, volume: Int,
                 at now: ContinuousClock.Instant) -> BluetoothMemberState {
        guard let capture else { return .waitingForSource }
        let uid = output.uid
        if var connection = connections[uid] {
            output.configure(connection.player, volume: volume)
            let frames = connection.player.renderedFrames.load(ordering: .relaxed)
            if connection.frames != frames {
                connection.frames = frames
                connection.lastProgress = now
                connections[uid] = connection
            } else if now - connection.lastProgress >= .seconds(4) {
                disconnect(uid)
                let message = "Bluetooth output stopped responding"
                retries[uid] = Retry(message: message, at: now + .seconds(2))
                return .retrying(message)
            }
            return frames > 0 ? .connected : .connecting
        }
        if let retry = retries[uid], retry.at > now { return .retrying(retry.message) }
        do {
            let player = try LocalPlayback(device: device, adjustable: true)
            output.configure(player, volume: volume)
            try player.start(inputRate: capture.sampleRate)
            connections[uid] = Connection(device: device, player: player, lastProgress: now)
            retries[uid] = nil
            targetsChanged = true
            return .connecting
        } catch {
            let message = error.localizedDescription
            retries[uid] = Retry(message: message, at: now + .seconds(3))
            return .retrying(message)
        }
    }

    func publishPlayers() {
        if targetsChanged {
            fanout.replace(with: connections.values.map(\.player))
            targetsChanged = false
        } else {
            fanout.reclaim()
        }
    }

    func stop() {
        capture?.stop()
        capture = nil
        tap = nil
        captureFailure = nil
        lastSignalAt = nil
        for uid in Array(connections.keys) { disconnect(uid) }
        publishPlayers()
        retries.removeAll()
        source = nil
    }

    private func disconnect(_ uid: String) {
        connections.removeValue(forKey: uid)?.player.stop()
        targetsChanged = true
    }
}

@MainActor
extension RoutingWorkspace {
    var availableBluetoothOutputs: [String: LocalOutput] {
        Dictionary(destinations.compactMap { destination -> (String, LocalOutput)? in
            guard case .bluetooth(let output) = destination, let uid = output.uid else { return nil }
            return (uid, output)
        }, uniquingKeysWith: { first, _ in first })
    }

    private var standaloneBluetoothOutputs: [String: String] {
        var standalone: [String: String] = [:]
        for route in routes.values where route.transportPending || route.stream.active {
            guard case .bluetooth(let output) = route.destination, let uid = output.uid else { continue }
            standalone[uid] = route.runningSourceName ?? output.name
        }
        return standalone
    }

    func reconcileBluetoothGroups() {
        bluetoothGroups.reconcile(available: availableBluetoothOutputs, standalone: standaloneBluetoothOutputs,
                                  sleeping: waitingForWake, source: resolveBluetoothSource) { uid in
            Int(bluetoothVolume(uid).rounded())
        }
    }

    private func resolveBluetoothSource(_ source: SavedGroupSource) -> (AudioSource?, String?) {
        switch source.choice(apps: apps, inputs: inputs) {
        case .application(let pid):
            guard let objects = apps.first(where: { $0.id == pid })?.audioProcessObjects, !objects.isEmpty else {
                return (nil, "Waiting for audio from \(source.name)")
            }
            return (.application(objects, playLocally: false), nil)
        case .device(let id): return (.device(id), nil)
        case nil: return (nil, source.kind == .app ? "App is closed" : "Input unavailable")
        }
    }

    func bluetoothVolume(_ uid: String) -> Double {
        let volume = volumePreferences.levels["bluetooth:\(uid)"] ?? 45
        return (0...100).contains(volume) ? volume : 45
    }

    private func applyBluetoothVolume(_ value: Double, for uid: String) {
        volumePreferences.levels["bluetooth:\(uid)"] = value
        for route in routes.values {
            guard case .bluetooth(let output) = route.destination, output.uid == uid else { continue }
            route.volume = value
            if route.stream.active { route.setVolume() }
        }
        bluetoothGroups.setVolume(Int(value.rounded()), for: uid)
    }

    func setBluetoothVolume(_ value: Double, for uid: String) {
        objectWillChange.send()
        applyBluetoothVolume(value, for: uid)
        persistVolumePreferences()
    }

    func bluetoothGroupVolumes(_ group: BluetoothGroup) -> [String: Double] {
        let active = bluetoothGroups.active.contains(group.id)
        let standalone = standaloneBluetoothOutputs
        return Dictionary(uniqueKeysWithValues: group.outputs.compactMap { output in
            let owner = bluetoothGroups.owners[output.uid]
            let adjustable = active ? owner == group.id : owner == nil && standalone[output.uid] == nil
            return adjustable ? (output.uid, bluetoothVolume(output.uid)) : nil
        })
    }

    func setBluetoothGroupVolume(_ maximum: Double, group: BluetoothGroup) {
        let levels = bluetoothGroupVolumes(group)
        guard !levels.isEmpty else { return }
        var balances = volumePreferences.bluetoothGroupBalances ?? [:]
        let updated = balances[group.id.uuidString, default: GroupVolumeBalance<String>()]
            .resized(levels, maximum: maximum)
        objectWillChange.send()
        volumePreferences.bluetoothGroupBalances = balances
        for (uid, volume) in updated { applyBluetoothVolume(volume, for: uid) }
        persistVolumePreferences()
    }

    func toggleBluetoothGroup(_ id: UUID) {
        if bluetoothGroups.active.contains(id) { bluetoothGroups.stop(id) }
        else { bluetoothGroups.start(id) }
        reconcileBluetoothGroups()
    }

    func updateBluetoothGroupSource(_ source: SavedGroupSource, in id: UUID) {
        guard var group = bluetoothGroups.groups.first(where: { $0.id == id }), group.source != source else { return }
        group.source = source
        bluetoothGroups.save(group)
        reconcileBluetoothGroups()
    }

    func requestBluetoothOutput(_ uid: String, in id: UUID, enabled: Bool) {
        bluetoothGroups.request(uid, in: id, enabled: enabled)
        reconcileBluetoothGroups()
    }
}
