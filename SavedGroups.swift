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
        guard let first = inputs.first else { return "Нет источников" }
        return first.source.name + (inputs.count > 1 ? " + \(inputs.count - 1)" : "")
    }

    mutating func setInputs(_ inputs: [GroupInput]) {
        var seen = Set<String>()
        mixInputs = inputs.filter { seen.insert($0.id).inserted }
        source = mixInputs?.first?.source
        playLocally = mixInputs?.first?.playLocally ?? false
    }
}

struct SavedGroupPlayback {
    var receivers: Set<Receiver.ID>
    var hasPlayed = false
    var retry = RecoveryRetry()
    var receiverRetries: [Receiver.ID: RecoveryRetry] = [:]
}

struct RecoveryRetry {
    private var attempts = 0
    private(set) var nextAttempt = Date.distantPast
    private static let delays: [TimeInterval] = [3, 5, 8, 15, 25]

    var exhausted: Bool { attempts >= Self.delays.count }

    mutating func delay(from now: Date) {
        guard !exhausted else { return }
        nextAttempt = now.addingTimeInterval(Self.delays[attempts])
        attempts += 1
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
        if let name = tvDeviceNames[receiver] { return "ТВ-вход занят: \(name)" }
        return "ТВ-вход занят · имя устройства недоступно"
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
                exclusions[member.name] = "уже используется: \(source)"
            } else if !available.contains(member) {
                unavailable.append(member.name)
                exclusions[member.name] = "колонка недоступна"
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
        if !busy.isEmpty { notes.append("Заняты: " + busy.joined(separator: ", ")) }
        if !unavailable.isEmpty { notes.append("Недоступны: " + unavailable.joined(separator: ", ")) }
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
        let group = SpeakerGroup(name: "Весь дом", members: [k, l, missing], source: source)
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
        reloaded.save(group)
        print("MIXER_INPUTS_MIGRATE_AND_PERSIST_LEVELS_AND_MUTE")
        let plan = GroupAvailability(members: group.members, available: [k, l]) { $0 == k ? "Telegram" : nil }
        guard plan.ready == [l], plan.busy == ["Kitchen (Telegram)"], plan.unavailable == ["Offline"] else { return false }
        guard let session = reloaded.session(for: group.id) else { return false }
        session.recordAttempt(receivers: Set(plan.ready.map(\.name)), exclusions: plan.exclusions)
        guard session.transmittingReceivers.isEmpty,
              reloaded.latestAttempt(for: k)?.0.id == group.id,
              session.reason(for: "Kitchen") == "уже используется: Telegram",
              session.reason(for: "Offline") == "колонка недоступна" else { return false }
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
        adjustedWorkspace.recoverSavedGroups(now: .distantFuture)
        adjustedWorkspace.stopDiscovery()
        guard adjustedWorkspace.groupPlayback.isEmpty, adjustedWorkspace.recoveringGroups.isEmpty,
              !adjustedWorkspace.hasActiveRoutes else { return false }
        print("INACTIVE_SAVED_GROUP_REMAINS_OFF_AFTER_WAKE")
        adjustedWorkspace.setRecoveringReceivers([k], in: speakers.id)
        guard adjustedWorkspace.isReconnecting, adjustedWorkspace.isReconnecting(group: speakers.id),
              adjustedWorkspace.isReconnecting(receiver: k), !adjustedWorkspace.isReconnecting(receiver: l) else { return false }
        adjustedWorkspace.stopSavedGroup(speakers, session: session)
        guard !adjustedWorkspace.isReconnecting else { return false }
        print("RECONNECTION_INDICATOR_FOLLOWS_PENDING_RECEIVER")
        reloaded.setTVDeviceName(" LG OLED ", for: l.name)
        let tvNames = SpeakerGroups(defaults: defaults)
        guard tvNames.tvOccupation(for: l.name) == "ТВ-вход занят: LG OLED",
              tvNames.tvOccupation(for: k.name) == "ТВ-вход занят · имя устройства недоступно" else { return false }
        print("TV_DEVICE_NAME_PERSISTED")
        var edited = group
        edited.members.remove(missing)
        edited.name = "Дома"
        reloaded.save(edited)
        guard SpeakerGroups(defaults: defaults).groups == [edited] else { return false }
        edited.members = [k]
        reloaded.save(edited)
        let single = SpeakerGroup(name: "Одна колонка", members: [l], source: source)
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
        Section("Группы") {
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
    @Environment(\.openWindow) private var openWindow
    @State private var expanded = false

    private var active: Bool { session.active }
    private var recovering: Bool { workspace.recoveringGroups.contains(group.id) }

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
            }
        }
        .padding(.vertical, 4)
    }

    private var sourcesLink: some View {
        Button(group.configuredInputs.isEmpty ? "Выбрать источники…" : group.inputSummary) {
            RoomAudioDelegate.openGroupWindow(openWindow, id: group.id)
        }
        .buttonStyle(TextActionStyle(linkColor: true))
        .accessibilityLabel("Источники группы \(group.name)")
        .accessibilityValue(group.inputSummary)
    }

    private var connected: Set<String> {
        session.transmittingReceivers.intersection(group.members.map(\.name))
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
            .accessibilityValue(expanded ? "Состав раскрыт" : "Состав свёрнут")
            .help(expanded ? "Свернуть состав" : "Показать состав")
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
                sourcesLink
                if active || recovering {
                    Text("· \(connected.count) из \(group.members.count) подключено")
                        .fixedSize()
                }
            }
            if !active, !recovering, !expanded {
                Text(group.members.map(\.name).sorted().joined(separator: " · ")).lineLimit(1)
            }
            if !connected.isEmpty && !stream.hasRecentSignal { Text("Нет сигнала") }
            if let error = session.error { Text(error) }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.leading, 19)
    }

    private var compactMembers: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(group.members.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, id: \.self) { receiver in
                let name = receiver.name
                let available = workspace.destinations.contains(.airplay(receiver))
                let owner = workspace.otherSource(for: receiver, session: session)
                let busyTV = stream.receiversBlockedByTV.contains(name)
                HStack(spacing: 6) {
                    Text(name)
                    if workspace.receiverTransfers[receiver] == group.id { ConnectionIcon(reconnecting: false) }
                    let status = if !available { "Недоступна" }
                    else if let owner { "Занята · \(owner)" }
                    else if connected.contains(name) { "Подключена" }
                    else if session.isConnecting(to: name) { "Подключение…" }
                    else if let failure = failure(for: name),
                            failure != "колонка недоступна", !failure.hasPrefix("уже используется:") { failure }
                    else { "Свободна" }
                    Text(status).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if available && (owner != nil || busyTV) {
                        Button("Забрать") {
                            if owner != nil { workspace.takeReceiver(receiver, into: group, session: session) }
                            else { workspace.forcePlay(receiver, group: group, session: session) }
                        }
                        .buttonStyle(TextActionStyle(linkColor: true))
                        .accessibilityLabel("Забрать \(name) в \(group.name)")
                        .disabled(!workspace.canTakeReceiver(receiver, into: group, session: session))
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
        .help("Громкость самой громкой колонки, доступной группе")
    }

    private var header: some View {
        HStack {
            Label(group.name, systemImage: "hifispeaker.2").font(.headline)
            let reconnecting = workspace.isReconnecting(group: group.id)
            if reconnecting || session.isConnecting { ConnectionIcon(reconnecting: reconnecting) }
            Spacer()
            if !simpleMode {
                Button {
                    RoomAudioDelegate.openGroupWindow(openWindow, id: group.id)
                } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Изменить группу \(group.name)")
            }
            transmissionControl
        }
    }

    private var transmissionControl: some View {
        Button {
            if active || recovering { workspace.stopSavedGroup(group, session: session) }
            else { workspace.startSavedGroup(group, session: session) }
        } label: {
            transmissionLabel(active || recovering ? "Остановить передачу" : "Передавать",
                              active: active || recovering, compact: simpleMode)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(active || recovering ? "Остановить \(group.name)" : "Передавать на \(group.name)")
        .disabled((stream.stopping && !recovering) || (!active && !recovering && group.configuredInputs.isEmpty))
        .disabled(!active && !recovering && workspace.receiverTransfers.values.contains(group.id))
    }

    @ViewBuilder private var summary: some View {
        let playing = connected
        let names = playing.sorted().joined(separator: ", ")
        let detail = if !playing.isEmpty { names }
            else if session.preparing { "Подготовка…" }
            else if stream.active { stream.status }
            else { "" }
        Text("Подключены \(playing.count) из \(group.members.count)" + (detail.isEmpty ? "" : " · " + detail))
            .font(.caption).foregroundStyle(.secondary)
        if !playing.isEmpty {
            Text(stream.hasRecentSignal ? "Есть звуковой сигнал" : "Нет сигнала от источника")
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
    private func availability(for group: SpeakerGroup, session: SynchronizedGroup) -> GroupAvailability {
        let available = Set(destinations.compactMap { if case .airplay(let id) = $0 { id } else { nil } })
        return GroupAvailability(members: group.members, available: available) { id in
            otherSource(for: id, session: session)
        }
    }

    func otherSource(for id: Receiver.ID, session: SynchronizedGroup, includeTransfer: Bool = true) -> String? {
        if session.members.contains(id.name) { return nil }
        if let name = savedGroups.ownerName(of: id.name) { return name }
        if synchronizedGroup.members.contains(id.name) { return synchronizedGroup.sourceName ?? "быстрая группа" }
        if let route = routes[.airplay(id)], route.starting || route.stream.active {
            return route.runningSourceName ?? "отдельный маршрут"
        }
        if includeTransfer, let target = receiverTransfers[id], savedGroups.session(for: target) !== session {
            return "переключение"
        }
        return nil
    }

    func canTakeReceiver(_ receiver: Receiver.ID, into group: SpeakerGroup, session: SynchronizedGroup) -> Bool {
        guard group.members.contains(receiver), destinations.contains(.airplay(receiver)),
              receiverTransfers[receiver] == nil, !waitingForWake, !recoveringGroups.contains(group.id),
              !session.stream.stopping else { return false }
        return session.active ? session.stream.isTransmitting : !group.configuredInputs.isEmpty
    }

    func takeReceiver(_ receiver: Receiver.ID, into group: SpeakerGroup, session: SynchronizedGroup) {
        guard canTakeReceiver(receiver, into: group, session: session),
              otherSource(for: receiver, session: session, includeTransfer: false) != nil else { return }
        let name = receiver.name
        // Reserve the output until the old transport confirms that its session ended.
        receiverTransfers[receiver] = group.id
        session.error = nil
        if let owner = savedGroups.owner(of: name) {
            stopSavedGroupReceiver(receiver, session: owner)
        } else if synchronizedGroup.members.contains(name) {
            synchronizedGroup.stream.stopReceiver(name)
        } else {
            routes[.airplay(receiver)]?.stop()
        }

        receiverTransferTasks[receiver] = Task {
            defer {
                if !Task.isCancelled {
                    receiverTransfers.removeValue(forKey: receiver)
                    receiverTransferTasks.removeValue(forKey: receiver)
                }
            }
            let deadline = ContinuousClock().now + .seconds(6)
            while otherSource(for: receiver, session: session, includeTransfer: false) != nil {
                guard ContinuousClock().now < deadline else {
                    session.error = "\(name): не удалось освободить выход."
                    return
                }
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            guard !Task.isCancelled, !waitingForWake,
                  let latest = savedGroups.groups.first(where: { $0.id == group.id }),
                  latest.members.contains(receiver), destinations.contains(.airplay(receiver)) else { return }
            if session.active {
                let volume = Int(speakerVolume(receiver).rounded())
                guard session.joinTransferredReceiver(name, volume: volume) else {
                    session.error = "\(name): не удалось подключить к \(group.name)."
                    return
                }
                groupPlayback[group.id]?.receivers.insert(receiver)
            } else {
                var selection = latest
                selection.members = [receiver]
                startSavedGroup(selection, session: session)
            }
        }
    }

    func cancelReceiverTransfers(to group: UUID? = nil) {
        let cancelled = receiverTransfers.filter { group == nil || $0.value == group }.keys
        for receiver in cancelled {
            receiverTransferTasks.removeValue(forKey: receiver)?.cancel()
            receiverTransfers.removeValue(forKey: receiver)
        }
    }

    private func speakerVolume(_ id: Receiver.ID) -> Double {
        let destination = RouteDestination.airplay(id)
        return routes[destination.id]?.volume ?? storedVolume(for: destination)
    }

    func groupVolumeLevels(for group: SpeakerGroup, session: SynchronizedGroup) -> [Receiver.ID: Double] {
        group.members.reduce(into: [:]) { levels, id in
            if otherSource(for: id, session: session) == nil { levels[id] = speakerVolume(id) }
        }
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

    func forcePlay(_ receiver: Receiver.ID, group: SpeakerGroup, session: SynchronizedGroup) {
        guard availability(for: group, session: session).ready.contains(receiver) else {
            session.error = "\(receiver.name) недоступна для переключения."
            return
        }
        if session.stream.isTransmitting {
            session.error = nil
            session.joinTVReceiver(receiver.name, volume: Int(speakerVolume(receiver).rounded()))
            groupPlayback[group.id]?.receivers.insert(receiver)
        } else if !session.active {
            startSavedGroup(group, session: session, overrideTV: receiver)
        }
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
        for group in savedGroups.groups where groupPlayback[group.id] != nil {
            guard let session = savedGroups.session(for: group.id), session.active, !session.stream.stopping else { continue }
            session.setMix(resolveMix(for: group), title: group.inputSummary)
        }
    }

    private func resolveMix(for group: SpeakerGroup) -> [MixInput] {
        group.configuredInputs.map { input in
            let source: AudioSource?
            let unavailable: String?
            switch input.source.kind {
            case .app:
                let app = apps.first { ($0.bundleID ?? $0.name) == input.source.identifier }
                let objects = app?.audioProcessObjects ?? []
                source = objects.isEmpty ? nil : .application(objects, playLocally: input.playLocally)
                unavailable = app == nil ? "Приложение закрыто" : "Ожидание звука"
            case .device:
                source = inputs.first { $0.uid == input.source.identifier }.map { .device($0.id) }
                unavailable = "Вход недоступен"
            }
            return MixInput(id: input.id, source: source, gain: input.gain, muted: input.muted,
                            unavailable: source == nil ? unavailable : nil)
        }
    }

    func startSavedGroup(_ group: SpeakerGroup, session: SynchronizedGroup, overrideTV receiver: Receiver.ID? = nil) {
        guard !session.active else { return }
        guard !waitingForWake else { return }
        groupPlayback.removeValue(forKey: group.id)
        recoveringGroups.remove(group.id)
        setRecoveringReceivers([], in: group.id)
        session.error = nil
        let plan = availability(for: group, session: session)
        do {
            guard !plan.ready.isEmpty else { throw StreamError(plan.details ?? "Нет доступных колонок.") }
            if let receiver {
                guard session.stream.receiversBlockedByTV.contains(receiver.name), plan.ready.contains(receiver) else {
                    throw StreamError("\(receiver.name) больше недоступна для переключения.")
                }
            }
            guard !group.configuredInputs.isEmpty else { throw StreamError("Выбери источники группы.") }
            let volumes = Dictionary(plan.ready.map { ($0.name, Int(speakerVolume($0).rounded())) },
                                     uniquingKeysWith: { first, _ in first })
            session.start(.mix(resolveMix(for: group)), title: group.inputSummary, volumes: volumes,
                          clock: clock, protectSonos: true, overrideTV: Set(receiver.map { [$0.name] } ?? []),
                          exclusions: plan.exclusions)
            groupPlayback[group.id] = SavedGroupPlayback(receivers: Set(plan.ready))
        } catch {
            if receiver == nil {
                session.recordAttempt(receivers: Set(plan.ready.map(\.name)), exclusions: plan.exclusions)
            }
            session.error = error.localizedDescription
        }
    }

    func stopSavedGroup(_ group: SpeakerGroup, session: SynchronizedGroup) {
        cancelReceiverTransfers(to: group.id)
        groupPlayback.removeValue(forKey: group.id)
        recoveringGroups.remove(group.id)
        setRecoveringReceivers([], in: group.id)
        session.stop()
    }

    func stopSavedGroupReceiver(_ receiver: Receiver.ID, session: SynchronizedGroup) {
        if let group = savedGroups.groups.first(where: { savedGroups.session(for: $0.id) === session }) {
            groupPlayback[group.id]?.receivers.remove(receiver)
            if groupPlayback[group.id]?.receivers.isEmpty == true {
                stopSavedGroup(group, session: session)
                return
            }
        }
        session.stream.stopReceiver(receiver.name)
    }

    func prepareSavedGroupsForSleep() {
        guard !waitingForWake else { return }
        cancelReceiverTransfers()
        waitingForWake = true
        for id in Array(groupPlayback.keys) {
            guard let session = savedGroups.session(for: id) else { continue }
            if session.hasTransmitted || session.stream.isTransmitting {
                groupPlayback[id]?.hasPlayed = true
            }
            if groupPlayback[id]?.hasPlayed == true {
                recoveringGroups.insert(id)
            } else {
                groupPlayback.removeValue(forKey: id)
            }
            setRecoveringReceivers([], in: id)
            session.stop()
        }
    }

    func resumeSavedGroupsAfterWake() {
        guard waitingForWake else { return }
        waitingForWake = false
        discovery.stop()
        discovery.start()
        for id in Array(groupPlayback.keys) {
            groupPlayback[id]?.retry = RecoveryRetry()
            groupPlayback[id]?.retry.delay(from: .now)
            groupPlayback[id]?.receiverRetries = [:]
        }
    }

    func recoverSavedGroups(now: Date = .now) {
        guard !waitingForWake else { return }
        for id in Array(groupPlayback.keys) {
            guard var playback = groupPlayback[id],
                  var group = savedGroups.groups.first(where: { $0.id == id }),
                  let session = savedGroups.session(for: id) else {
                groupPlayback.removeValue(forKey: id)
                recoveringGroups.remove(id)
                setRecoveringReceivers([], in: id)
                continue
            }
            if session.stream.isTransmitting, !session.stream.stopping {
                playback.hasPlayed = true
                playback.retry = RecoveryRetry()
                recoveringGroups.remove(id)
                playback.receivers = playback.receivers.filter { !session.stream.receiversBlockedByTV.contains($0.name) }
                let reconnecting = recoverGroupReceivers(&playback, session: session, now: now)
                setRecoveringReceivers(reconnecting, in: id)
                groupPlayback[id] = playback
                continue
            }
            if session.active { continue }
            setRecoveringReceivers([], in: id)
            playback.hasPlayed = playback.hasPlayed || session.hasTransmitted
            let retryable = playback.hasPlayed || !session.stream.failedReceivers.isEmpty || recoveringGroups.contains(id)
            guard retryable, !playback.receivers.isEmpty else {
                groupPlayback.removeValue(forKey: id)
                recoveringGroups.remove(id)
                continue
            }
            if recoveringGroups.insert(id).inserted {
                playback.retry.delay(from: now)
                groupPlayback[id] = playback
                continue
            }
            guard now >= playback.retry.nextAttempt else { continue }
            guard !playback.retry.exhausted else {
                session.error = "Не удалось восстановить передачу автоматически."
                stopSavedGroup(group, session: session)
                continue
            }
            playback.retry.delay(from: now)
            groupPlayback[id] = playback
            group.members.formIntersection(playback.receivers)
            let plan = availability(for: group, session: session)
            guard !plan.ready.isEmpty else { continue }
            let volumes = Dictionary(plan.ready.map { ($0.name, Int(speakerVolume($0).rounded())) },
                                     uniquingKeysWith: { first, _ in first })
            session.start(.mix(resolveMix(for: group)), title: group.inputSummary, volumes: volumes,
                          clock: clock, protectSonos: true, exclusions: plan.exclusions)
        }
    }

    private func recoverGroupReceivers(_ playback: inout SavedGroupPlayback, session: SynchronizedGroup,
                                       now: Date) -> Set<Receiver.ID> {
        var reconnecting: Set<Receiver.ID> = []
        for receiver in playback.receivers {
            if session.transmittingReceivers.contains(receiver.name) {
                playback.receiverRetries.removeValue(forKey: receiver)
                continue
            }
            if playback.receiverRetries[receiver] != nil,
               ["Подключение", "Синхронизация"].contains(session.stream.receivers[receiver.name] ?? "") {
                reconnecting.insert(receiver)
                continue
            }
            guard session.stream.failedReceivers.contains(receiver.name),
                  otherSource(for: receiver, session: session) == nil else {
                continue
            }
            var retry = playback.receiverRetries[receiver, default: RecoveryRetry()]
            guard !retry.exhausted else { continue }
            reconnecting.insert(receiver)
            guard now >= retry.nextAttempt else { continue }
            retry.delay(from: now)
            playback.receiverRetries[receiver] = retry
            session.stream.rejoinFailedReceiver(receiver.name, volume: Int(speakerVolume(receiver).rounded()))
        }
        return reconnecting
    }
}

let tvInputBusyMessage = "занят ТВ-вход"

struct ForcePlayButton: View {
    let receiver: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bolt.circle.fill").imageScale(.large)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Force Play на \(receiver)")
        .help("Force Play — переключить \(receiver) с телевизора на Room Audio")
    }
}
