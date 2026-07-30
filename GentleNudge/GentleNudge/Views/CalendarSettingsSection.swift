import SwiftUI
import SwiftData

// MARK: - Settings section

/// The Calendar block in Settings: the opt-in, the permission, how far ahead to
/// look, which calendars to read, what the app has learned to add on its own, and
/// a manual "Scan now" with the result of the last pass.
///
/// Its own file (and its own view) so `SettingsView` doesn't grow another 150
/// lines; it renders as `Section`s, so it drops straight into that `List`.
struct CalendarSettingsSection: View {
    @Environment(CalendarScanCoordinator.self) private var coordinator

    @AppStorage(Constants.DefaultsKeys.calendarScanEnabled)
    private var scanEnabled = false
    @AppStorage(Constants.DefaultsKeys.calendarDaysAhead)
    private var daysAhead = Constants.defaultCalendarDaysAhead

    @State private var isScanning = false

    private var authorization: CalendarService.AuthorizationStatus {
        coordinator.authorizationStatus
    }

    var body: some View {
        Section {
            Toggle(isOn: $scanEnabled) {
                Label("Suggest from Calendar", systemImage: "calendar.badge.plus")
            }
            .onChange(of: scanEnabled) { _, isOn in
                // Turning it on should do something visible now. Without this the
                // first scan waits for the next foreground, which reads as broken.
                guard isOn else { return }
                Task {
                    if authorization == .notDetermined {
                        await coordinator.requestAccessAndScan()
                    } else if authorization == .authorized {
                        await coordinator.scan()
                    }
                }
            }

            if scanEnabled {
                permissionRow

                if authorization == .authorized {
                    Stepper(value: $daysAhead, in: Constants.calendarDaysAheadRange) {
                        HStack {
                            Label("Look ahead", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                            Spacer()
                            Text("\(daysAhead) day\(daysAhead == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }

                    NavigationLink {
                        CalendarPickerView()
                    } label: {
                        Label("Calendars to Scan", systemImage: "calendar")
                    }

                    NavigationLink {
                        CalendarAutoRulesView()
                    } label: {
                        Label("What Gets Added Automatically", systemImage: "wand.and.sparkles")
                    }

                    scanNowRow
                }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("""
            Gentle Nudge reads the next \(daysAhead) day\(daysAhead == 1 ? "" : "s") of events and \
            proposes action items — a gift before a birthday, a reservation before a dinner. \
            Birthdays and anniversaries are added for you; everything else waits for your \
            approval on Today, and the more you approve or skip a kind of event, the less it \
            asks. Your calendar is only ever read, never changed.
            """)
        }
    }

    // MARK: Permission

    @ViewBuilder
    private var permissionRow: some View {
        switch authorization {
        case .authorized:
            HStack {
                Label("Calendar Access", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AppColors.success)
                Spacer()
                Text("Granted")
                    .foregroundStyle(.secondary)
            }
        case .notDetermined:
            Button {
                Task { await coordinator.requestAccessAndScan() }
            } label: {
                Label("Grant Calendar Access", systemImage: "lock.open")
            }
        case .denied:
            VStack(alignment: .leading, spacing: Constants.Spacing.xxs) {
                Label("Calendar Access Denied", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(AppColors.warning)
                Text("Enable calendar access for Gentle Nudge in System Settings, then come back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Manual scan

    @ViewBuilder
    private var scanNowRow: some View {
        Button {
            Task {
                isScanning = true
                await coordinator.scan()
                isScanning = false
            }
        } label: {
            HStack {
                Label("Scan Now", systemImage: "arrow.clockwise")
                Spacer()
                if isScanning || coordinator.state == .scanning {
                    ProgressView()
                }
            }
        }
        .disabled(isScanning || coordinator.state == .scanning)

        if let outcome = coordinator.lastOutcome, let lastScanAt = coordinator.lastScanAt {
            VStack(alignment: .leading, spacing: 2) {
                Text(outcome.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Last checked \(lastScanAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }

        if case let .failed(message) = coordinator.state {
            Text(message)
                .font(.caption)
                .foregroundStyle(AppColors.destructive)
        }
    }
}

// MARK: - Calendar picker

/// Per-calendar opt-out, so a noisy shared work calendar can be left out while
/// birthdays stay in. An empty selection means "every calendar", which is also the
/// starting state — the list shows that explicitly rather than looking broken.
struct CalendarPickerView: View {
    @State private var calendars: [CalendarInfo] = []
    @State private var selected: Set<String> = Constants.calendarSelectedIDs ?? []
    @State private var isLoading = true

    var body: some View {
        List {
            Section {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading calendars…")
                            .foregroundStyle(.secondary)
                    }
                } else if calendars.isEmpty {
                    Text("No calendars found.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(calendars) { calendar in
                        Button {
                            toggle(calendar.id)
                        } label: {
                            HStack {
                                Image(systemName: calendar.isBirthday ? "gift" : "calendar")
                                    .foregroundStyle(calendar.isBirthday ? .pink : .secondary)
                                    .frame(width: 20)
                                Text(calendar.title)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if isOn(calendar.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(AppColors.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isOn(calendar.id) ? [.isSelected] : [])
                    }
                }
            } footer: {
                Text(selected.isEmpty
                     ? "Every calendar is being scanned. Tap any calendar to narrow it down."
                     : "Only the ticked calendars are scanned.")
            }

            if !selected.isEmpty {
                Section {
                    Button("Scan All Calendars") {
                        selected = []
                        persist()
                    }
                }
            }
        }
        .navigationTitle("Calendars to Scan")
        .task {
            calendars = await CalendarService.shared.availableCalendars()
            isLoading = false
        }
    }

    /// With no explicit selection every calendar is scanned, so every row reads as
    /// on — otherwise the default state would look like "nothing is enabled".
    private func isOn(_ id: String) -> Bool {
        selected.isEmpty || selected.contains(id)
    }

    private func toggle(_ id: String) {
        if selected.isEmpty {
            // First tap out of "all": start from everything, minus this one.
            selected = Set(calendars.map(\.id))
            selected.remove(id)
        } else if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        // Ticking everything back on is the same as "all calendars".
        if selected.count == calendars.count { selected = [] }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(selected), forKey: Constants.DefaultsKeys.calendarSelectedIDs)
    }
}

// MARK: - Auto-approve rules

/// The learning, made legible: one row per kind of event, showing what the app
/// currently does with it and the tally that got it there — plus a way to override
/// either direction, or hand it back to the counters.
struct CalendarAutoRulesView: View {
    @Environment(CalendarScanCoordinator.self) private var coordinator
    @Query private var rules: [CalendarAutoRule]

    enum Mode: String, CaseIterable, Identifiable {
        case ask
        case always
        case never

        var id: String { rawValue }

        var label: String {
            switch self {
            case .ask: return "Ask me"
            case .always: return "Always add"
            case .never: return "Never suggest"
            }
        }
    }

    var body: some View {
        List {
            ForEach(CalendarEventKind.allCases) { kind in
                Section {
                    Picker(selection: binding(for: kind)) {
                        ForEach(Mode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    } label: {
                        Label(kind.label, systemImage: kind.icon)
                    }
                    .pickerStyle(.menu)

                    if let rule = rule(for: kind), rule.acceptCount + rule.dismissCount > 0 {
                        HStack {
                            Text(tallyText(rule))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if rule.userOverridden {
                                Button("Use Learned") {
                                    coordinator.clearOverride(kind: kind)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Automatic Adds")
    }

    private func rule(for kind: CalendarEventKind) -> CalendarAutoRule? {
        rules.first { $0.kind == kind }
    }

    private func mode(for kind: CalendarEventKind) -> Mode {
        guard let rule = rule(for: kind) else {
            // No decisions yet: birthdays and anniversaries start on, per the
            // seed in `CalendarAutoRule.rule(for:in:)`.
            return kind.isSelfEvident ? .always : .ask
        }
        if rule.suppressed { return .never }
        return rule.autoApprove ? .always : .ask
    }

    private func binding(for kind: CalendarEventKind) -> Binding<Mode> {
        Binding(
            get: { mode(for: kind) },
            set: { newMode in
                coordinator.setRule(
                    kind: kind,
                    autoApprove: newMode == .always,
                    suppressed: newMode == .never
                )
            }
        )
    }

    private func tallyText(_ rule: CalendarAutoRule) -> String {
        var parts: [String] = []
        if rule.acceptCount > 0 { parts.append("\(rule.acceptCount) added") }
        if rule.dismissCount > 0 { parts.append("\(rule.dismissCount) skipped") }
        let tally = parts.joined(separator: ", ")
        return rule.userOverridden ? "Set by you · \(tally)" : "Learned from \(tally)"
    }
}
