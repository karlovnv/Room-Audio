import Foundation

enum AirPlayRoute: Hashable {
    case saved(UUID)
    case quick
    case individual(Receiver.ID)
}

struct PlaybackRun: Equatable {
    let id = UUID()
    let route: AirPlayRoute
    let name: String
}

struct OutputClaim: Equatable {
    enum Priority: Equatable {
        case ordinary
        case takeover
    }

    let run: PlaybackRun
    let priority: Priority
}

struct ExternalPlayback: Equatable {
    enum Kind: String { case tv, airplay, paused, other }
    let kind: Kind
    let description: String
}

struct TakeoverPermit: Equatable {
    let runID: UUID
    let occupationID: UUID
}

struct OutputSlot: Equatable {
    enum Availability: Equatable {
        case offline
        case available
        case unknown
        case unsupported(String)
        case external(ExternalPlayback, occupationID: UUID)
    }

    struct Connection: Equatable {
        let run: PlaybackRun
        let operationID: UUID
        let occupation: UUID?
        var overrideTV: Bool { occupation != nil }
    }

    enum State: Equatable {
        case idle
        case connecting(Connection)
        case connected(Connection)
        case releasing(Connection)
        case retry(Date, String)
    }

    enum Command: Equatable {
        case attach(Connection)
        case detach(Connection)
    }

    private(set) var claims: [OutputClaim] = []
    private(set) var availability = Availability.offline
    private(set) var state = State.idle
    private var permit: TakeoverPermit?
    private var retryCount = 0

    var connection: Connection? {
        switch state {
        case .connecting(let connection), .connected(let connection), .releasing(let connection): connection
        case .idle, .retry: nil
        }
    }

    var playing: PlaybackRun? {
        if case .connected(let connection) = state { return connection.run }
        return nil
    }

    func requested(by run: PlaybackRun) -> Bool { claims.contains { $0.run == run } }

    mutating func request(_ run: PlaybackRun, priority: OutputClaim.Priority = .ordinary) {
        let claim = OutputClaim(run: run, priority: priority)
        switch priority {
        case .ordinary:
            if !requested(by: run) { claims.append(claim) }
        case .takeover:
            claims.removeAll { $0.run == run }
            claims.insert(claim, at: 0)
            if case .external(let source, let occupationID) = availability, source.kind == .tv {
                permit = TakeoverPermit(runID: run.id, occupationID: occupationID)
            }
            clearBackoff()
        }
    }

    mutating func revoke(_ run: PlaybackRun) {
        let wasFirst = claims.first?.run == run
        claims.removeAll { $0.run == run }
        if permit?.runID == run.id { permit = nil }
        if wasFirst { clearBackoff() }
    }

    mutating func observedAvailable(_ online: Bool) {
        if !online {
            if availability != .offline { availability = .offline; permit = nil }
        } else if availability == .offline {
            availability = .available
            clearBackoff()
        }
    }

    mutating func observedOccupancy(_ observation: Availability) {
        switch observation {
        case .external(let source, _):
            if case .external(let current, _) = availability, current == source { return }
            availability = .external(source, occupationID: UUID())
        case .unknown:
            // An unsuccessful query cannot clear a confirmed external owner.
            if case .external = availability { return }
            availability = .unknown
        default:
            guard availability != observation else { return }
            availability = observation
        }
        permit = nil
        clearBackoff()
    }

    mutating func next(now: Date, suspended: Bool, canStart: (PlaybackRun) -> Bool) -> Command? {
        let first = suspended ? nil : claims.first?.run
        let desired: PlaybackRun?
        let override: UUID?
        switch availability {
        case .available:
            desired = first
            override = nil
        case .external(_, let occupationID):
            let allowed = first.map { permit == TakeoverPermit(runID: $0.id, occupationID: occupationID) } ?? false
            desired = allowed ? first : nil
            override = allowed ? occupationID : nil
        case .unknown:
            // Keep an existing healthy connection, but wait for a fresh probe before attaching.
            desired = connection?.run == first ? first : nil
            override = nil
        case .offline, .unsupported:
            desired = nil
            override = nil
        }

        switch state {
        case .releasing:
            return nil
        case .connecting(let connection), .connected(let connection):
            if desired == connection.run { return nil }
            if case .connecting = state, case .external(_, let occupationID) = availability,
               first == connection.run, connection.occupation == occupationID { return nil }
            state = .releasing(connection)
            return .detach(connection)
        case .retry(let deadline, _) where now < deadline:
            return nil
        case .idle, .retry:
            guard let desired, canStart(desired) else { return nil }
            let connection = Connection(run: desired, operationID: UUID(), occupation: override)
            if override != nil { permit = nil }
            state = .connecting(connection)
            return .attach(connection)
        }
    }

    mutating func didFailWhileConnected(_ connection: Connection) {
        guard self.connection == connection else { return }
        state = .releasing(connection)
    }

    mutating func didPlay(_ connection: Connection) {
        guard state == .connecting(connection) else { return }
        state = .connected(connection)
        retryCount = 0
        if connection.overrideTV { availability = .available }
    }

    mutating func didRelease(_ connection: Connection, now: Date, failure: String?) {
        guard self.connection == connection else { return }
        state = .idle
        if let failure, requested(by: connection.run),
           claims.first?.run == connection.run, availability == .available {
            let delays: [TimeInterval] = [3, 5, 8, 15, 25]
            let seconds = delays[min(retryCount, delays.count - 1)]
            retryCount = min(retryCount + 1, delays.count - 1)
            state = .retry(now.addingTimeInterval(seconds), failure)
        }
    }

    private mutating func clearBackoff() {
        retryCount = 0
        if case .retry = state { state = .idle }
    }
}

import Combine
import OSLog

@MainActor
final class AirPlayCoordinator: ObservableObject {
    @MainActor
    enum Backend {
        case group(SynchronizedGroup)
        case individual(OutputRoute)

        var stream: Streaming {
            switch self {
            case .group(let group): group.stream
            case .individual(let route): route.stream
            }
        }

        var busy: Bool {
            switch self {
            case .group(let group): group.transportPending
            case .individual(let route): route.transportPending
            }
        }

        var failure: String? {
            switch self {
            case .group(let group): group.error
            case .individual(let route): route.error
            }
        }

        func detach(_ receiver: Receiver.ID, allOutputs: Bool) {
            switch self {
            case .group(let session):
                if allOutputs { session.stop() }
                else { stream.stopReceiver(receiver.name) }
            case .individual(let route): route.stop()
            }
        }
    }

    private struct BackendRun {
        let run: PlaybackRun
        let backend: Backend
        let source: AudioSource?
    }

    @Published private(set) var slots: [Receiver.ID: OutputSlot] = [:]
    @Published private(set) var runs: [AirPlayRoute: PlaybackRun] = [:]
    private var backends: [UUID: BackendRun] = [:]
    private var transportOwners: [AirPlayRoute: UUID] = [:]
    private var probeDeadline: [Receiver.ID: Date] = [:]
    private var probes: [Receiver.ID: UUID] = [:]
    private var nonSonos: Set<Receiver.ID> = []
    private let logger = Logger(subsystem: "local.roomaudio.discovery", category: "Routing")

    func start(_ route: AirPlayRoute, name: String, receivers: Set<Receiver.ID>, backend: Backend,
               source: AudioSource?, takeover: Receiver.ID? = nil) {
        guard !receivers.isEmpty, runs[route] == nil else { return }
        let run = PlaybackRun(route: route, name: name)
        backends[run.id] = BackendRun(run: run, backend: backend, source: source)
        runs[route] = run
        var updated = slots
        for receiver in receivers {
            updated[receiver, default: OutputSlot()].request(run, priority: receiver == takeover ? .takeover : .ordinary)
        }
        slots = updated
        logger.notice("start \(run.name, privacy: .public) run=\(run.id.uuidString, privacy: .public)")
    }

    func attach(_ receiver: Receiver.ID, to route: AirPlayRoute, takeover: Bool = false) {
        guard let run = runs[route] else { return }
        slots[receiver, default: OutputSlot()].request(run, priority: takeover ? .takeover : .ordinary)
        logger.notice("\(takeover ? "takeover" : "attach", privacy: .public) output=\(receiver.name, privacy: .public) target=\(run.name, privacy: .public)")
    }

    func stop(_ route: AirPlayRoute, receiver: Receiver.ID? = nil) {
        guard let run = runs[route] else { return }
        if let receiver {
            slots[receiver]?.revoke(run)
            logger.notice("stopOutput output=\(receiver.name, privacy: .public) owner=\(run.name, privacy: .public)")
        } else {
            runs.removeValue(forKey: route)
            var updated = slots
            for receiver in updated.keys { updated[receiver]?.revoke(run) }
            slots = updated
            logger.notice("stopRun owner=\(run.name, privacy: .public) run=\(run.id.uuidString, privacy: .public)")
        }
    }

    func stopAll() {
        for route in Array(runs.keys) { stop(route) }
    }

    func requested(_ receiver: Receiver.ID, by route: AirPlayRoute) -> Bool {
        guard let run = runs[route] else { return false }
        return slots[receiver]?.requested(by: run) == true
    }

    func playing(_ route: AirPlayRoute) -> Set<Receiver.ID> {
        guard let run = runs[route] else { return [] }
        return Set(slots.compactMap { $0.value.playing == run ? $0.key : nil })
    }

    func reconcile(_ workspace: RoutingWorkspace, now: Date = .now) {
        let online = Set(workspace.destinations.compactMap { if case .airplay(let id) = $0 { id } else { nil } })
        var updated = slots
        var starts: [UUID: [(Receiver.ID, OutputSlot.Connection)]] = [:]
        for receiver in updated.keys {
            guard var slot = updated[receiver] else { continue }
            slot.observedAvailable(online.contains(receiver))
            if let connection = slot.connection, let entry = backends[connection.run.id] {
                let stream = entry.backend.stream
                let receipt = stream.airPlayReceipts[receiver.name]
                if online.contains(receiver), let category = receipt?.category {
                    slot.observedOccupancy(observation(category, message: receipt?.failure ?? ""))
                }
                if receipt?.released == true || !entry.backend.busy {
                    let failure = receipt?.failure ?? (slot.state == .releasing(connection) ? nil : (entry.backend.failure ?? stream.status))
                    slot.didRelease(connection, now: now, failure: failure)
                    report("released", receiver, connection, note: failure)
                } else if receipt?.failure != nil {
                    slot.didFailWhileConnected(connection)
                } else if receipt?.playing == true, stream.isTransmitting, slot.state == .connecting(connection) {
                    slot.didPlay(connection)
                    report("connected", receiver, connection)
                }
            }

            switch slot.next(now: now, suspended: workspace.waitingForWake, canStart: canStart) {
            case .attach(let connection):
                starts[connection.run.id, default: []].append((receiver, connection))
            case .detach(let connection):
                report("releasing", receiver, connection, note: slot.claims.first?.run.name)
            case nil:
                break
            }
            updated[receiver] = slot
        }

        let keeping = Set(updated.values.compactMap { slot -> UUID? in
            switch slot.state {
            case .connecting(let connection), .connected(let connection): connection.run.id
            default: nil
            }
        })
        for (receiver, slot) in updated {
            if case .releasing(let connection) = slot.state {
                backends[connection.run.id]?.backend.detach(receiver, allOutputs: !keeping.contains(connection.run.id))
            }
        }
        if updated != slots { slots = updated }
        for (runID, requests) in starts {
            guard let entry = backends[runID] else { continue }
            open(entry, requests, workspace: workspace, now: now)
        }
        for (route, runID) in Array(transportOwners) where backends[runID]?.backend.busy != true {
            transportOwners.removeValue(forKey: route)
        }
        let held = Set(slots.values.compactMap { $0.connection?.run.id })
        let active = Set(runs.values.map(\.id))
        let draining = Set(transportOwners.values)
        backends = backends.filter { active.contains($0.key) || held.contains($0.key) || draining.contains($0.key) }
        let retained = slots.filter { !$0.value.claims.isEmpty || $0.value.connection != nil }
        if retained != slots { slots = retained }
        if !workspace.waitingForWake { probeNeededOutputs(workspace, now: now) }
    }

    private func canStart(_ run: PlaybackRun) -> Bool {
        guard let entry = backends[run.id] else { return false }
        if !entry.backend.busy { return true }
        return transportOwners[run.route] == run.id && entry.backend.stream.isTransmitting && !entry.backend.stream.stopping
    }

    private func open(_ entry: BackendRun, _ requests: [(Receiver.ID, OutputSlot.Connection)],
                      workspace: RoutingWorkspace, now: Date) {
        let volumes = Dictionary(requests.map { (key: $0.0.name, value: workspace.receiverVolume($0.0)) },
                                 uniquingKeysWith: { first, _ in first })
        for (receiver, connection) in requests { report("connecting", receiver, connection) }
        if entry.backend.busy {
            for (receiver, connection) in requests {
                if !entry.backend.stream.joinAuthorizedReceiver(receiver.name, volume: workspace.receiverVolume(receiver),
                                                               operationID: connection.operationID, overrideTV: connection.overrideTV) {
                    slots[receiver]?.didRelease(connection, now: now, failure: "Could not send the AirPlay request")
                }
            }
            return
        }
        transportOwners[entry.run.route] = entry.run.id
        let override = Set(requests.filter { $0.1.overrideTV }.map { $0.0.name })
        switch entry.backend {
        case .group(let session):
            let current = workspace.savedGroupForRoute(entry.run.route)
            let source = current.map { AudioSource.mix(workspace.resolveMix(for: $0)) } ?? entry.source
            if let source {
                session.start(source, title: current?.inputSummary ?? entry.run.name, volumes: volumes,
                              clock: workspace.clock, protectSonos: true, overrideTV: override)
            }
        case .individual(let route):
            if let source = entry.source {
                route.start(source, name: entry.run.name, clock: workspace.clock, overrideTV: !override.isEmpty)
            }
        }
        if !entry.backend.busy {
            for (receiver, connection) in requests {
                slots[receiver]?.didRelease(connection, now: now, failure: "Could not start AirPlay")
            }
        }
    }

    private func observation(_ category: String, message: String) -> OutputSlot.Availability {
        switch category {
        case "available", "not_sonos": return .available
        case "local": return .unsupported(message)
        default:
            guard let kind = ExternalPlayback.Kind(rawValue: category) else { return .unknown }
            // The slot assigns the stable identity for repeated observations.
            return .external(.init(kind: kind, description: message), occupationID: UUID())
        }
    }

    private func probeNeededOutputs(_ workspace: RoutingWorkspace, now: Date) {
        for (receiver, slot) in slots where !slot.claims.isEmpty && !nonSonos.contains(receiver) {
            guard probes.count < 2, probes[receiver] == nil, (probeDeadline[receiver] ?? .distantPast) <= now else { continue }
            switch slot.availability {
            case .external, .unknown: break
            case .available where slot.playing != nil: break
            default: continue
            }
            guard let script = Bundle.main.url(forResource: "stream", withExtension: "py"),
                  let transport = Bundle.main.url(forResource: "cliairplay", withExtension: nil) else { return }
            let process = Process()
            let output = Pipe()
            let ticket = UUID()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path, "--transport", transport.path, "--probe-sonos", receiver.name]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            probes[receiver] = ticket
            probeDeadline[receiver] = now.addingTimeInterval(4)
            process.terminationHandler = { [weak self] _ in
                let line = (try? output.fileHandleForReading.readToEnd()) ?? Data()
                let result = (try? JSONSerialization.jsonObject(with: line)) as? [String: String]
                Task { @MainActor [weak self] in
                    guard let self, self.probes[receiver] == ticket else { return }
                    self.probes.removeValue(forKey: receiver)
                    guard let current = self.slots[receiver], current.state == slot.state,
                          current.availability == slot.availability, !workspace.waitingForWake,
                          !current.claims.isEmpty, let category = result?["category"] else { return }
                    if category == "not_sonos" { self.nonSonos.insert(receiver) }
                    if current.playing != nil && category != "tv" { return }
                    self.slots[receiver]?.observedOccupancy(self.observation(category, message: result?["message"] ?? ""))
                    self.reconcile(workspace)
                }
            }
            do {
                try process.run()
                try? output.fileHandleForWriting.close()
            } catch {
                probes.removeValue(forKey: receiver)
            }
        }
    }

    private func report(_ action: String, _ receiver: Receiver.ID, _ connection: OutputSlot.Connection, note: String? = nil) {
        logger.notice("\(action, privacy: .public) output=\(receiver.name, privacy: .public) owner=\(connection.run.name, privacy: .public) operation=\(connection.operationID.uuidString, privacy: .public) detail=\(note ?? "", privacy: .public)")
    }
}

func verifyOutputSlots() -> Bool {
    let now = Date(timeIntervalSince1970: 1000)
    let all = PlaybackRun(route: .saved(UUID()), name: "All Sonos")
    let vibe = PlaybackRun(route: .saved(UUID()), name: "Kitchen Vibe")
    let tv = ExternalPlayback(kind: .tv, description: "TV input")
    var slot = OutputSlot()
    slot.request(all)
    guard slot.next(now: now, suspended: false, canStart: { _ in true }) == nil else { return false }
    slot.observedAvailable(true)
    guard case .attach(let first) = slot.next(now: now, suspended: false, canStart: { _ in true }),
          first.run == all else { return false }
    slot.didPlay(first)
    slot.request(vibe)
    guard slot.playing == all, slot.next(now: now, suspended: false, canStart: { _ in true }) == nil else { return false }
    slot.request(vibe, priority: .takeover)
    guard slot.next(now: now, suspended: false, canStart: { _ in true }) == .detach(first),
          slot.next(now: now, suspended: false, canStart: { _ in true }) == nil else { return false }
    slot.didRelease(first, now: now, failure: nil)
    guard case .attach(let second) = slot.next(now: now, suspended: false, canStart: { _ in true }),
          second.run == vibe else { return false }
    slot.revoke(vibe)
    guard slot.next(now: now, suspended: false, canStart: { _ in true }) == .detach(second) else { return false }
    slot.didPlay(second)
    guard slot.playing == nil, slot.next(now: now, suspended: false, canStart: { _ in true }) == nil else { return false }
    slot.didRelease(second, now: now, failure: nil)
    guard case .attach(let returned) = slot.next(now: now, suspended: false, canStart: { _ in true }),
          returned.run == all else { return false }
    slot.didRelease(second, now: now, failure: nil)
    guard slot.connection == returned else { return false }
    slot.didPlay(returned)
    slot.observedOccupancy(.external(tv, occupationID: UUID()))
    guard slot.next(now: now, suspended: false, canStart: { _ in true }) == .detach(returned) else { return false }
    slot.didRelease(returned, now: now, failure: nil)
    slot.observedOccupancy(.unknown)
    guard slot.next(now: now, suspended: false, canStart: { _ in true }) == nil else { return false }
    slot.request(all, priority: .takeover)
    guard case .attach(let force) = slot.next(now: now, suspended: false, canStart: { _ in true }),
          force.overrideTV else { return false }
    slot.didPlay(force)
    slot.observedOccupancy(.external(tv, occupationID: UUID()))
    guard slot.next(now: now, suspended: false, canStart: { _ in true }) == .detach(force) else { return false }
    slot.didRelease(force, now: now, failure: nil)
    guard slot.next(now: now, suspended: false, canStart: { _ in true }) == nil else { return false }
    slot.observedOccupancy(.available)
    guard case .attach(let afterTV) = slot.next(now: now, suspended: false, canStart: { _ in true }),
          !afterTV.overrideTV else { return false }
    slot.didRelease(afterTV, now: now, failure: "network")
    guard slot.next(now: now, suspended: false, canStart: { _ in true }) == nil else { return false }
    slot.revoke(all)
    slot.observedAvailable(false)
    slot.observedAvailable(true)
    guard !slot.requested(by: all),
          slot.next(now: now + 30, suspended: false, canStart: { _ in true }) == nil else { return false }
    print("OUTPUT_CLAIMS_RESTORE_PRIORITY_RESPECT_STOP_AND_FENCE_LATE_ACK")
    return true
}
