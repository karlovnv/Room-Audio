import Combine
import SwiftUI

struct SavedGroupSource: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case app, device }
    let kind: Kind
    let identifier: String
    let name: String
    var id: String { "\(kind.rawValue):\(identifier)" }

    @MainActor
    init?(choice: RouteSourceChoice, apps: [RunningAudioApp], inputs: [AudioInput]) {
        switch choice {
        case .application(let pid):
            guard let app = apps.first(where: { $0.id == pid }) ?? RunningAudioApp.list().first(where: { $0.id == pid }) else { return nil }
            self.init(kind: .app, identifier: app.bundleID ?? app.name, name: app.name)
        case .device(let id):
            guard let input = inputs.first(where: { $0.id == id }) else { return nil }
            self.init(kind: .device, identifier: input.uid, name: input.name)
        }
    }

    init(kind: Kind, identifier: String, name: String) {
        self.kind = kind
        self.identifier = identifier
        self.name = name
    }

    @MainActor
    func choice(apps: [RunningAudioApp], inputs: [AudioInput]) -> RouteSourceChoice? {
        switch kind {
        case .app:
            return apps.first { ($0.bundleID ?? $0.name) == identifier }.map { .application($0.id) }
        case .device:
            return inputs.first { $0.uid == identifier }.map { .device($0.id) }
        }
    }
}

struct GroupInput: Identifiable, Codable, Equatable {
    let source: SavedGroupSource
    var gain: Double = 100
    var muted = false
    var playLocally = false
    var id: String { source.id }
}

struct SpeakerGroup: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var members: Set<Receiver.ID>
    var source: SavedGroupSource?
    var playLocally = false
    var mixInputs: [GroupInput]? = nil

    var configuredInputs: [GroupInput] {
        if let mixInputs { return mixInputs }
        return source.map { [GroupInput(source: $0, playLocally: playLocally)] } ?? []
    }

    var inputSummary: String {
        let inputs = configuredInputs
        guard let first = inputs.first else { return "No sources" }
        return first.source.name + (inputs.count > 1 ? " + \(inputs.count - 1)" : "")
    }

    mutating func setInputs(_ inputs: [GroupInput]) {
        var seen = Set<String>()
        mixInputs = inputs.filter { seen.insert($0.id).inserted }
        source = mixInputs?.first?.source
        playLocally = mixInputs?.first?.playLocally ?? false
    }
}

struct GroupVolumeBalance: Codable {
    private var levelsBeforeZero: [Receiver.ID: Double] = [:]

    mutating func resized(_ levels: [Receiver.ID: Double], maximum: Double) -> [Receiver.ID: Double] {
        let previousMaximum = levels.values.max() ?? 0
        if previousMaximum > 0 {
            if maximum == 0 { levelsBeforeZero = levels }
            return levels.mapValues { ($0 / previousMaximum) * maximum }
        }
        let previousLevels = levelsBeforeZero.filter { levels[$0.key] != nil }
        guard let strongest = previousLevels.values.max(), strongest > 0 else {
            return levels.mapValues { _ in maximum }
        }
        return levels.reduce(into: [:]) { result, level in
            result[level.key] = ((previousLevels[level.key] ?? strongest) / strongest) * maximum
        }
    }
}

struct OutputVolumePreferences: Codable {
    static let key = "room-audio.output-volume-preferences"
    var levels: [String: Double] = [:]
    var groupBalances: [String: GroupVolumeBalance] = [:]
}

@MainActor
final class SpeakerGroups: ObservableObject {
    @Published private(set) var groups: [SpeakerGroup]
    @Published private(set) var tvDeviceNames: [String: String]
    private let defaults: UserDefaults
    private let key = "room-audio.saved-speaker-groups.v1"
    private let tvNamesKey = "room-audio.tv-device-names.v1"
    private var sessions: [UUID: SynchronizedGroup] = [:]
    private var observations: [UUID: Set<AnyCancellable>] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tvDeviceNames = defaults.dictionary(forKey: tvNamesKey) as? [String: String] ?? [:]
        if let data = defaults.data(forKey: key) {
            groups = (try? JSONDecoder().decode([SpeakerGroup].self, from: data)) ?? []
        } else {
            groups = []
        }
        for group in groups { register(group.id) }
    }

    private func register(_ id: UUID) {
        let session = SynchronizedGroup()
        sessions[id] = session
        observations[id] = [
            session.objectWillChange.sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            },
            session.stream.$mixStatus.dropFirst().sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            },
            session.stream.$skippedReceivers.dropFirst().sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            },
            session.stream.connectionUpdates.dropFirst().sink { [weak self] _ in
                MainActor.assumeIsolated { self?.objectWillChange.send() }
            }
        ]
    }

    func session(for id: UUID) -> SynchronizedGroup? { sessions[id] }
    var isConnecting: Bool { sessions.values.contains(where: \.isConnecting) }

    func owner(of receiver: String) -> SynchronizedGroup? {
        sessions.values.first { $0.members.contains(receiver) }
    }

    func ownerName(of receiver: String) -> String? {
        groups.first { sessions[$0.id]?.members.contains(receiver) == true }?.name
    }

    func latestAttempt(for receiver: Receiver.ID) -> (SpeakerGroup, SynchronizedGroup)? {
        groups.compactMap { group -> (SpeakerGroup, SynchronizedGroup)? in
            guard group.members.contains(receiver), let session = sessions[group.id],
                  session.attempted(receiver.name) else { return nil }
            return (group, session)
        }.max { $0.1.attemptedAt < $1.1.attemptedAt }
    }

    func setTVDeviceName(_ name: String, for receiver: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tvDeviceNames[receiver] = name.isEmpty ? nil : name
        defaults.set(tvDeviceNames, forKey: tvNamesKey)
    }

    func tvOccupation(for receiver: String) -> String {
        if let name = tvDeviceNames[receiver] { return "TV input in use: \(name)" }
        return "TV input in use · device name unavailable"
    }

    var hasActiveGroups: Bool {
        sessions.values.contains { $0.preparing || $0.stream.active || !$0.members.isEmpty }
    }

    func stopAll() { for session in sessions.values { session.stop() } }

    func save(_ group: SpeakerGroup) {
        var saved = group
        saved.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saved.name.isEmpty, !saved.members.isEmpty else { return }
        if let index = groups.firstIndex(where: { $0.id == saved.id }) {
            groups[index] = saved
        } else {
            register(saved.id)
            groups.append(saved)
        }
        persist()
    }

    func remove(_ id: UUID) {
        guard let session = sessions[id], session.members.isEmpty, !session.stream.active,
              !session.preparing else { return }
        observations[id] = nil
        sessions[id] = nil
        groups.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(groups) { defaults.set(data, forKey: key) }
    }
}

struct GroupAvailability {
    let ready: [Receiver.ID]
    let busy: [String]
    let unavailable: [String]
    let exclusions: [String: String]

    init(members: Set<Receiver.ID>, available: Set<Receiver.ID>, owner: (Receiver.ID) -> String?) {
        var ready: [Receiver.ID] = []
        var busy: [String] = []
        var unavailable: [String] = []
        var exclusions: [String: String] = [:]
        for member in members.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            if let source = owner(member) {
                busy.append("\(member.name) (\(source))")
                exclusions[member.name] = "In use by: \(source)"
            } else if !available.contains(member) {
                unavailable.append(member.name)
                exclusions[member.name] = "Output unavailable"
            } else {
                ready.append(member)
            }
        }
        self.ready = ready
        self.busy = busy
        self.unavailable = unavailable
        self.exclusions = exclusions
    }

    var details: String? {
        var notes: [String] = []
        if !busy.isEmpty { notes.append("Busy: " + busy.joined(separator: ", ")) }
        if !unavailable.isEmpty { notes.append("Unavailable: " + unavailable.joined(separator: ", ")) }
        return notes.isEmpty ? nil : notes.joined(separator: " · ")
    }
}

@MainActor
func verifySavedGroups() {
    let domain = "room-audio.check.\(UUID())"
    guard let defaults = UserDefaults(suiteName: domain) else { exit(1) }
    let passed = { () -> Bool in
        defer { defaults.removePersistentDomain(forName: domain) }
        let k = Receiver.ID(name: "Kitchen", domain: "local.")
        let l = Receiver.ID(name: "Living Room", domain: "local.")
        let missing = Receiver.ID(name: "Offline", domain: "local.")
        let source = SavedGroupSource(kind: .device, identifier: "test-device-uid", name: "BlackHole 2ch")
        let group = SpeakerGroup(name: "Whole Home", members: [k, l, missing], source: source)
        let store = SpeakerGroups(defaults: defaults)
        store.save(group)
        let reloaded = SpeakerGroups(defaults: defaults)
        guard reloaded.groups == [group], reloaded.session(for: group.id) != nil,
              source.choice(apps: [], inputs: [.init(id: 993, name: "BlackHole 2ch", uid: "test-device-uid")]) == .device(993) else { return false }
        print("GROUP_PERSISTED_WITH_SOURCE_AND_MEMBERS")
        var mixed = group
        mixed.playLocally = true
        guard mixed.configuredInputs == [GroupInput(source: source, playLocally: true)] else { return false }
        let application = SavedGroupSource(kind: .app, identifier: "com.google.Chrome", name: "Google Chrome")
        let configured = [GroupInput(source: application, gain: 68, playLocally: true),
                          GroupInput(source: source, gain: 24, muted: true)]
        mixed.setInputs(configured + configured)
        reloaded.save(mixed)
        guard SpeakerGroups(defaults: defaults).groups.first?.configuredInputs == configured else { return false }
        mixed.setInputs([])
        reloaded.save(mixed)
        guard SpeakerGroups(defaults: defaults).groups.first?.configuredInputs.isEmpty == true else { return false }
        let emptyWorkspace = RoutingWorkspace(defaults: defaults)
        guard let emptySession = emptyWorkspace.savedGroups.session(for: mixed.id) else { return false }
        let route = AirPlayRoute.saved(mixed.id)
        emptyWorkspace.startSavedGroup(mixed, session: emptySession)
        guard let run = emptyWorkspace.airPlay.runs[route] else { return false }
        emptyWorkspace.updateGroupInputs(configured, in: mixed.id)
        emptyWorkspace.updateGroupInputs([], in: mixed.id)
        guard emptyWorkspace.airPlay.runs[route] == run,
              mixed.members.allSatisfy({ emptyWorkspace.airPlay.requested($0, by: route) }),
              SpeakerGroups(defaults: defaults).groups.first?.configuredInputs.isEmpty == true else { return false }
        emptyWorkspace.stopSavedGroup(mixed, session: emptySession)
        guard emptyWorkspace.airPlay.runs[route] == nil else { return false }
        print("GROUP_WITH_ZERO_SOURCES_CAN_START_AND_KEEP_OUTPUT_REQUESTS")
        reloaded.save(group)
        print("MIXER_INPUTS_MIGRATE_AND_PERSIST_LEVELS_AND_MUTE")
        let plan = GroupAvailability(members: group.members, available: [k, l]) { $0 == k ? "Telegram" : nil }
        guard plan.ready == [l], plan.busy == ["Kitchen (Telegram)"], plan.unavailable == ["Offline"] else { return false }
        guard let session = reloaded.session(for: group.id) else { return false }
        session.recordAttempt(receivers: Set(plan.ready.map(\.name)), exclusions: plan.exclusions)
        guard session.transmittingReceivers.isEmpty,
              reloaded.latestAttempt(for: k)?.0.id == group.id,
              session.reason(for: "Kitchen") == "In use by: Telegram",
              session.reason(for: "Offline") == "Output unavailable" else { return false }
        print("GROUP_PARTIAL_START_SKIPS_BUSY_AND_OFFLINE")
        var balance = GroupVolumeBalance()
        let original: [Receiver.ID: Double] = [k: 30, l: 60, missing: 0]
        let reduced = balance.resized(original, maximum: 40)
        let zero = balance.resized(reduced, maximum: 0)
        guard reduced == [k: 20, l: 40, missing: 0],
              zero == [k: 0, l: 0, missing: 0],
              balance.resized(zero, maximum: 80) == [k: 40, l: 80, missing: 0],
              balance.resized(original, maximum: 100) == [k: 50, l: 100, missing: 0] else { return false }
        print("GROUP_VOLUME_PRESERVES_PROPORTIONS_THROUGH_ZERO")
        let workspace = RoutingWorkspace(defaults: defaults)
        let routeK = OutputRoute(.airplay(k))
        let routeL = OutputRoute(.airplay(l))
        workspace.setRouteVolume(30, route: routeK)
        workspace.setRouteVolume(60, route: routeL)
        let speakers = SpeakerGroup(name: "All Sonos", members: [k, l], source: nil)
        let restoredWorkspace = RoutingWorkspace(defaults: defaults)
        guard restoredWorkspace.groupVolumeLevels(for: speakers, session: session) == [k: 30, l: 60] else { return false }
        restoredWorkspace.setGroupVolume(0, for: speakers, session: session)
        let mutedWorkspace = RoutingWorkspace(defaults: defaults)
        guard mutedWorkspace.groupVolumeLevels(for: speakers, session: session) == [k: 0, l: 0] else { return false }
        mutedWorkspace.setGroupVolume(40, for: speakers, session: session)
        let adjustedWorkspace = RoutingWorkspace(defaults: defaults)
        guard adjustedWorkspace.groupVolumeLevels(for: speakers, session: session) == [k: 20, l: 40] else { return false }
        print("SPEAKER_LEVELS_AND_MUTED_GROUP_BALANCE_SURVIVE_RESTART")
        adjustedWorkspace.prepareSavedGroupsForSleep()
        adjustedWorkspace.resumeSavedGroupsAfterWake()
        adjustedWorkspace.airPlay.reconcile(adjustedWorkspace)
        adjustedWorkspace.stopDiscovery()
        guard adjustedWorkspace.airPlay.runs.isEmpty, !adjustedWorkspace.hasActiveRoutes else { return false }
        print("INACTIVE_SAVED_GROUP_REMAINS_OFF_AFTER_WAKE")
        guard verifyOutputSlots(), verifyInputSlotTransitions() else { return false }
        reloaded.setTVDeviceName(" LG OLED ", for: l.name)
        let tvNames = SpeakerGroups(defaults: defaults)
        guard tvNames.tvOccupation(for: l.name) == "TV input in use: LG OLED",
              tvNames.tvOccupation(for: k.name) == "TV input in use · device name unavailable" else { return false }
        print("TV_DEVICE_NAME_PERSISTED")
        var edited = group
        edited.members.remove(missing)
        edited.name = "Home"
        reloaded.save(edited)
        guard SpeakerGroups(defaults: defaults).groups == [edited] else { return false }
        edited.members = [k]
        reloaded.save(edited)
        let single = SpeakerGroup(name: "Single Output", members: [l], source: source)
        reloaded.save(single)
        var empty = edited
        empty.members = []
        reloaded.save(empty)
        guard SpeakerGroups(defaults: defaults).groups == [edited, single] else { return false }
        print("SINGLE_OUTPUT_GROUP_CREATED_AND_EDITED")
        reloaded.remove(group.id)
        reloaded.remove(single.id)
        guard SpeakerGroups(defaults: defaults).groups.isEmpty else { return false }
        print("GROUP_EDIT_AND_DELETE_PERSISTED")
        return true
    }()
    exit(passed ? 0 : 1)
}

@MainActor
struct SavedGroupsSection: View {
    @ObservedObject var workspace: RoutingWorkspace
    @ObservedObject var groups: SpeakerGroups
    let simpleMode: Bool

    var body: some View {
        Section("Groups") {
            ForEach(groups.groups) { group in
                if let session = groups.session(for: group.id) {
                    SavedGroupRow(group: group, session: session, stream: session.stream,
                                  workspace: workspace, groups: groups, simpleMode: simpleMode)
                }
            }
        }
    }
}

@MainActor
struct SavedGroupRow: View {
    let group: SpeakerGroup
    @ObservedObject var session: SynchronizedGroup
    @ObservedObject var stream: Streaming
    @ObservedObject var workspace: RoutingWorkspace
    @ObservedObject var groups: SpeakerGroups
    let simpleMode: Bool
    var compact = false
    var allowsGroupEditing = true
    @Environment(\.openWindow) private var openWindow
    @State private var expanded = false

    private var active: Bool { workspace.airPlay.runs[.saved(group.id)] != nil }
    private var recovering: Bool { workspace.isReconnecting(group: group.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if compact {
                compactHeader
                compactSummary
                if expanded { compactMembers }
            } else {
                header
                sourcesLink
                if !simpleMode {
                    Text(group.members.map(\.name).sorted().joined(separator: " · "))
                        .lineLimit(1).font(.caption).foregroundStyle(.secondary)
                }
                volumeControl
                summary
                compactMembers
            }
        }
        .padding(.vertical, 4)
    }

    private var sourcesLink: some View {
        Button(group.configuredInputs.isEmpty ? "Choose Sources…" : group.inputSummary) {
            RoomAudioDelegate.openSourcesWindow(openWindow, id: group.id)
        }
        .buttonStyle(TextActionStyle(linkColor: true))
        .accessibilityLabel("Sources for \(group.name)")
        .accessibilityValue(group.inputSummary)
    }

    private var connected: Set<String> {
        Set(workspace.airPlay.playing(.saved(group.id)).map(\.name))
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hifispeaker.2").accessibilityHidden(true)
                    Text(group.name).lineLimit(1)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2).foregroundStyle(.secondary).accessibilityHidden(true)
                    if workspace.isReconnecting(group: group.id) || session.isConnecting {
                        ConnectionIcon(reconnecting: workspace.isReconnecting(group: group.id))
                    }
                }
                .font(.headline)
            }
            .buttonStyle(TextActionStyle())
            .accessibilityValue(expanded ? "Outputs expanded" : "Outputs collapsed")
            .help(expanded ? "Hide group outputs" : "Show group outputs")
            .frame(width: VolumeSlider.compactCaptionWidth, alignment: .leading)
            HStack(spacing: 8) {
                volumeControl.opacity(active || recovering ? 1 : 0)
                    .disabled(!active && !recovering)
                    .accessibilityHidden(!active && !recovering)
                transmissionControl.frame(width: 28)
            }
        }
    }

    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                sourcesLink.lineLimit(1)
                if active || recovering {
                    Text("·").accessibilityHidden(true)
                    Text("\(connected.count)/\(group.members.count)")
                        .fixedSize()
                        .accessibilityLabel("\(connected.count) of \(group.members.count) connected")
                        .help("\(connected.count) of \(group.members.count) connected")
                    if !connected.isEmpty && !stream.hasRecentSignal {
                        if stream.mixStatus.values.contains(where: \.captured) {
                            Image(systemName: "pause.fill")
                                .imageScale(.small)
                                .accessibilityLabel("No audio signal")
                                .help("No audio signal")
                        } else if !group.configuredInputs.isEmpty {
                            Text("· Waiting for sources").lineLimit(1)
                        }
                    }
                } else if !expanded {
                    let names = group.members.map(\.name).sorted().joined(separator: " · ")
                    Text("· \(names)").lineLimit(1).help(names)
                }
                if allowsGroupEditing {
                    Spacer(minLength: 4)
                    editGroupButton
                }
            }
            if let error = session.error { Text(error) }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.leading, 19)
    }

    private var compactMembers: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(group.members.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, id: \.self) { receiver in
                let name = receiver.name
                let slot = workspace.airPlay.slots[receiver]
                let available = workspace.destinations.contains(.airplay(receiver))
                let requested = workspace.airPlay.requested(receiver, by: .saved(group.id))
                let owner = workspace.otherSource(for: receiver, session: session)
                let external: ExternalPlayback? = if case .external(let source, _) = slot?.availability { source } else { nil }
                let changing = slot?.connection?.run.route == .saved(group.id) && slot?.playing == nil
                HStack(spacing: 6) {
                    Text(name)
                    if changing { ConnectionIcon(reconnecting: recovering) }
                    let status = if !available { "Unavailable" }
                    else if let external {
                        external.kind == .tv ? groups.tvOccupation(for: name) : external.description
                    }
                    else if let owner { "In use by \(owner)" }
                    else if connected.contains(name) { "Connected" }
                    else if changing { "Connecting…" }
                    else if !requested && active { "Disconnected from group" }
                    else if case .retry(_, let reason) = slot?.state { reason }
                    else if case .unsupported(let reason) = slot?.availability { reason }
                    else if requested { "Waiting to connect" }
                    else { "Available" }
                    Text(status).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if available && !changing && (owner != nil && external == nil || external?.kind == .tv) {
                        Button("Take Over") { workspace.attachSavedReceiver(receiver, group: group, session: session, takeover: true) }
                            .buttonStyle(TextActionStyle(linkColor: true))
                            .accessibilityLabel("Take over \(name) for \(group.name)")
                    } else if available && active && !requested && external == nil {
                        Button("Connect") { workspace.attachSavedReceiver(receiver, group: group, session: session) }
                            .buttonStyle(TextActionStyle(linkColor: true))
                    }
                }
            }
        }
        .font(.caption)
        .padding(.leading, 19)
    }

    private var volumeControl: some View {
        let maximum = workspace.groupVolumeLevels(for: group, session: session).values.max()
        return VolumeSlider(name: group.name, value: Binding(
            get: { workspace.groupVolumeLevels(for: group, session: session).values.max() ?? 0 },
            set: { workspace.setGroupVolume($0, for: group, session: session) }
        ), showsSignalColumn: !simpleMode, available: maximum != nil, hidesCaption: compact)
        .disabled(maximum == nil || stream.stopping)
        .help("Volume of the loudest output in the group")
    }

    private var header: some View {
        HStack {
            Label(group.name, systemImage: "hifispeaker.2").font(.headline)
            let reconnecting = workspace.isReconnecting(group: group.id)
            if reconnecting || session.isConnecting { ConnectionIcon(reconnecting: reconnecting) }
            Spacer()
            if allowsGroupEditing { editGroupButton }
            transmissionControl
        }
    }

    private var editGroupButton: some View {
        Button {
            RoomAudioDelegate.openGroupWindow(openWindow, id: group.id)
        } label: {
            Image(systemName: "pencil")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Edit group \(group.name)")
        .help("Edit Group")
    }

    private var transmissionControl: some View {
        Button {
            if active || recovering { workspace.stopSavedGroup(group, session: session) }
            else { workspace.startSavedGroup(group, session: session) }
        } label: {
            transmissionLabel(active || recovering ? "Stop Streaming" : "Stream",
                              active: active || recovering, compact: simpleMode)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(active || recovering ? "Stop \(group.name)" : "Stream to \(group.name)")
    }

    @ViewBuilder private var summary: some View {
        let playing = connected
        let names = playing.sorted().joined(separator: ", ")
        let detail = if !playing.isEmpty { names }
            else if session.preparing { "Preparing…" }
            else if stream.active { stream.status }
            else { "" }
        Text("\(playing.count) of \(group.members.count) connected" + (detail.isEmpty ? "" : " · " + detail))
            .font(.caption).foregroundStyle(.secondary)
        if !playing.isEmpty {
            Text(stream.hasRecentSignal ? "Audio signal detected" : "No signal from the source")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let error = session.error, active || !group.members.contains(where: { session.reason(for: $0.name) != nil }) {
            Text(error).font(.caption).foregroundStyle(.secondary)
        }
        ForEach(group.members.map(\.name).sorted(), id: \.self) { name in
            if let detail = failure(for: name) {
                Text("\(name): \(detail)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func failure(for name: String) -> String? {
        guard let reason = session.reason(for: name) else { return nil }
        return stream.receiversBlockedByTV.contains(name) && reason == tvInputBusyMessage
            ? groups.tvOccupation(for: name) : reason
    }
}

@MainActor
extension RoutingWorkspace {
    func otherSource(for id: Receiver.ID, session: SynchronizedGroup) -> String? {
        guard let connection = airPlay.slots[id]?.connection else { return nil }
        if case .saved(let groupID) = connection.run.route, savedGroups.session(for: groupID) === session { return nil }
        return connection.run.name
    }

    func receiverVolume(_ id: Receiver.ID) -> Int { Int(speakerVolume(id).rounded()) }

    func savedGroupForRoute(_ route: AirPlayRoute) -> SpeakerGroup? {
        guard case .saved(let id) = route else { return nil }
        return savedGroups.groups.first { $0.id == id }
    }

    func attachSavedReceiver(_ receiver: Receiver.ID, group: SpeakerGroup, session: SynchronizedGroup, takeover: Bool = false) {
        if airPlay.runs[.saved(group.id)] != nil {
            airPlay.attach(receiver, to: .saved(group.id), takeover: takeover)
            airPlay.reconcile(self)
        } else if takeover {
            var selection = group
            selection.members = [receiver]
            startSavedGroup(selection, session: session, overrideTV: receiver)
        }
    }

    private func speakerVolume(_ id: Receiver.ID) -> Double {
        let destination = RouteDestination.airplay(id)
        return routes[destination.id]?.volume ?? storedVolume(for: destination)
    }

    func groupVolumeLevels(for group: SpeakerGroup, session: SynchronizedGroup) -> [Receiver.ID: Double] {
        let route = AirPlayRoute.saved(group.id)
        let controlled = airPlay.runs[route] != nil
            ? airPlay.playing(route)
            : group.members.filter { otherSource(for: $0, session: session) == nil }
        return Dictionary(uniqueKeysWithValues: controlled.map { ($0, speakerVolume($0)) })
    }

    func setGroupVolume(_ maximum: Double, for group: SpeakerGroup, session: SynchronizedGroup) {
        let current = groupVolumeLevels(for: group, session: session)
        guard !current.isEmpty else { return }
        let updated = volumePreferences.groupBalances[group.id.uuidString, default: GroupVolumeBalance()]
            .resized(current, maximum: maximum)
        objectWillChange.send()
        var playingLevels: [String: Int] = [:]
        for (id, volume) in updated {
            let destination = RouteDestination.airplay(id)
            routes[destination.id]?.volume = volume
            volumePreferences.levels[destination.visibilityKey] = volume
            if session.members.contains(id.name) { playingLevels[id.name] = Int(volume.rounded()) }
        }
        persistVolumePreferences()
        session.setVolumes(playingLevels)
    }

    func updateGroupInputs(_ inputs: [GroupInput], in groupID: UUID) {
        guard var group = savedGroups.groups.first(where: { $0.id == groupID }) else { return }
        group.setInputs(inputs)
        savedGroups.save(group)
        if let session = savedGroups.session(for: groupID), session.active {
            session.setMix(resolveMix(for: group), title: group.inputSummary)
        }
    }

    func refreshSavedGroupMixes() {
        for group in savedGroups.groups where airPlay.runs[.saved(group.id)] != nil {
            guard let session = savedGroups.session(for: group.id), session.active, !session.stream.stopping else { continue }
            session.setMix(resolveMix(for: group), title: group.inputSummary)
        }
    }

    func resolveMix(for group: SpeakerGroup) -> [MixInput] {
        group.configuredInputs.map { input in
            let source: AudioSource?
            let unavailable: String?
            switch input.source.kind {
            case .app:
                let app = apps.first { ($0.bundleID ?? $0.name) == input.source.identifier }
                let objects = app?.audioProcessObjects ?? []
                source = objects.isEmpty ? nil : .application(objects, playLocally: input.playLocally)
                unavailable = app == nil ? "App is closed" : "Waiting for audio"
            case .device:
                source = inputs.first { $0.uid == input.source.identifier }.map { .device($0.id) }
                unavailable = "Input unavailable"
            }
            return MixInput(id: input.id, source: source, gain: input.gain, muted: input.muted,
                            unavailable: source == nil ? unavailable : nil)
        }
    }

    func startSavedGroup(_ group: SpeakerGroup, session: SynchronizedGroup, overrideTV receiver: Receiver.ID? = nil) {
        session.error = nil
        airPlay.start(.saved(group.id), name: group.name, receivers: group.members,
                      backend: .group(session), source: nil, takeover: receiver)
        airPlay.reconcile(self)
    }

    func stopSavedGroup(_ group: SpeakerGroup, session: SynchronizedGroup) {
        airPlay.stop(.saved(group.id))
        airPlay.reconcile(self)
    }

    func stopReceiver(_ receiver: Receiver.ID) {
        guard let route = airPlay.slots[receiver]?.connection?.run.route else { return }
        if case .individual = route { airPlay.stop(route) }
        else { airPlay.stop(route, receiver: receiver) }
        airPlay.reconcile(self)
    }

    func prepareSavedGroupsForSleep() {
        guard !waitingForWake else { return }
        waitingForWake = true
        airPlay.reconcile(self)
    }

    func resumeSavedGroupsAfterWake() {
        guard waitingForWake else { return }
        waitingForWake = false
        discovery.stop()
        discovery.start()
        airPlay.reconcile(self)
    }

}

let tvInputBusyMessage = "TV input in use"

struct ForcePlayButton: View {
    let receiver: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bolt.circle.fill").imageScale(.large)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Force Play on \(receiver)")
        .help("Switch \(receiver) from the TV input to Room Audio")
    }
}
