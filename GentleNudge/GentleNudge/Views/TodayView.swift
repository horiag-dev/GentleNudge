import SwiftUI
import SwiftData

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(CalendarScanCoordinator.self) private var calendarCoordinator
    @Query private var reminders: [Reminder]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query private var calendarSuggestions: [CalendarSuggestion]

    @State private var searchText = ""
    @State private var briefingVM = MorningBriefingViewModel()
    /// Manual entry is the rare path (the AI assistant and Voice do the heavy
    /// lifting), so it lives here as a quiet "+" in the header — not in the bar.
    @State private var showingAddReminder = false
    @AppStorage(Constants.DefaultsKeys.habitVisibility)
    private var habitVisibilityRaw = HabitVisibility.all.rawValue

    /// Three-way habit surfacing mode (replaces the old show/hide boolean).
    private var habitVisibility: HabitVisibility {
        HabitVisibility(rawValue: habitVisibilityRaw) ?? .all
    }

    /// Calendar proposals waiting on a yes/no.
    private var calendarPending: [CalendarSuggestion] {
        CalendarSuggestion.pending(from: calendarSuggestions)
    }

    /// Calendar items added automatically today — shown with an Undo so an
    /// unattended add is never a surprise the user can't take back.
    private var calendarAutoAdded: [CalendarSuggestion] {
        CalendarSuggestion.autoAddedToday(from: calendarSuggestions)
    }

    /// Lightweight, Sendable snapshots for the once-a-day briefing.
    private var reminderSummaries: [MorningBriefingService.ReminderSummary] {
        reminders.map {
            MorningBriefingService.ReminderSummary(
                title: $0.title,
                categoryName: $0.category?.name,
                dueDate: $0.dueDate,
                isHabit: $0.isHabit,
                isCompleted: $0.isCompleted
            )
        }
    }

    // MARK: - Categorized Reminders (computed from @Query for full reactivity)

    private struct CategorizedReminders {
        let habits: [Reminder]
        let needsAttention: [Reminder]
        let upcoming: [Reminder]
        let needsAttentionByCategory: [(category: Category?, reminders: [Reminder])]
        let byCategory: [UUID: [Reminder]]
        let uncategorized: [Reminder]

        var isEmpty: Bool {
            habits.isEmpty && needsAttention.isEmpty && upcoming.isEmpty
                && byCategory.isEmpty && uncategorized.isEmpty
        }
    }

    private var categorizedReminders: CategorizedReminders {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        let filterBlock: (Reminder) -> Bool = searchText.isEmpty ? { _ in true } : { reminder in
            reminder.title.localizedCaseInsensitiveContains(searchText) ||
            reminder.notes.localizedCaseInsensitiveContains(searchText)
        }

        var habits: [Reminder] = []
        var needsAttention: [Reminder] = []
        var upcoming: [Reminder] = []
        var byCategory: [UUID: [Reminder]] = [:]
        var uncategorized: [Reminder] = []

        for reminder in reminders {
            guard !reminder.isCompleted else { continue }
            guard filterBlock(reminder) else { continue }

            if reminder.isHabit {
                // Habits never join the other buckets; the visibility mode
                // decides which ones surface (all / none / only selected)
                if habitVisibility.shows(reminder) {
                    habits.append(reminder)
                }
                continue
            }

            let daysUntil: Int?
            if let dueDate = reminder.dueDate {
                let due = calendar.startOfDay(for: dueDate)
                daysUntil = calendar.dateComponents([.day], from: today, to: due).day
            } else {
                daysUntil = nil
            }

            let isOverdue = daysUntil.map { $0 < 0 } ?? false
            let isDueToday = daysUntil == 0
            let isUpcomingSoon = daysUntil.map { $0 >= 1 && $0 <= 2 } ?? false

            if isOverdue || isDueToday {
                needsAttention.append(reminder)
            } else if isUpcomingSoon {
                upcoming.append(reminder)
            } else if let categoryId = reminder.category?.id {
                byCategory[categoryId, default: []].append(reminder)
            } else {
                // Items without a category (e.g. imported) must still be visible
                uncategorized.append(reminder)
            }
        }

        habits.sort { $0.title < $1.title }
        // In-progress items pin to the top of every active bucket (they're what
        // the user is actively working on), then the existing order applies.
        uncategorized.sort { r1, r2 in
            if r1.isInProgress != r2.isInProgress { return r1.isInProgress }
            return r1.createdAt > r2.createdAt
        }
        needsAttention.sort { r1, r2 in
            if r1.isInProgress != r2.isInProgress { return r1.isInProgress }
            if r1.isOverdue != r2.isOverdue { return r1.isOverdue }
            if r1.isDueToday != r2.isDueToday { return r1.isDueToday }
            return r1.priority.rawValue > r2.priority.rawValue
        }
        upcoming.sort { r1, r2 in
            if r1.isInProgress != r2.isInProgress { return r1.isInProgress }
            return (r1.dueDate ?? .distantFuture) < (r2.dueDate ?? .distantFuture)
        }

        // Group needs attention by category
        var grouped: [UUID?: [Reminder]] = [:]
        for reminder in needsAttention {
            grouped[reminder.category?.id, default: []].append(reminder)
        }

        var needsAttentionByCategory: [(category: Category?, reminders: [Reminder])] = []
        for category in categories {
            if let catReminders = grouped[category.id], !catReminders.isEmpty {
                needsAttentionByCategory.append((category: category, reminders: catReminders))
            }
        }
        if let uncategorized = grouped[nil], !uncategorized.isEmpty {
            needsAttentionByCategory.append((category: nil, reminders: uncategorized))
        }

        return CategorizedReminders(
            habits: habits,
            needsAttention: needsAttention,
            upcoming: upcoming,
            needsAttentionByCategory: needsAttentionByCategory,
            byCategory: byCategory,
            uncategorized: uncategorized
        )
    }

    /// Inline title row: the large "Gentle Nudge" title and the quiet manual-add
    /// "+" on one line — replacing the nav-bar large title + `.topBarTrailing`
    /// toolbar item, which put the "+" on a row above the title.
    private var titleRow: some View {
        HStack {
            Text("Gentle Nudge")
                .font(.largeTitle)
                .fontWeight(.bold)
            Spacer()
            #if os(iOS)
            Button {
                HapticManager.impact(.light)
                showingAddReminder = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2)
            }
            .accessibilityLabel("New Reminder")
            #endif
        }
        .padding(.horizontal)
        .padding(.top, Constants.Spacing.sm)
    }

    /// Custom search field just below the title row (replacing the nav-bar
    /// `.searchable`, which would otherwise render above the custom title). Same
    /// `searchText` binding, so filtering and the "No Results" state are intact.
    private var searchField: some View {
        HStack(spacing: Constants.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search reminders", text: $searchText)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Constants.Spacing.sm)
        .padding(.vertical, Constants.Spacing.xs)
        .background(AppColors.secondaryBackground, in: Capsule())
        .padding(.horizontal)
        .padding(.top, Constants.Spacing.xs)
        .padding(.bottom, Constants.Spacing.sm)
    }

    var body: some View {
        NavigationStack {
            let data = categorizedReminders

            VStack(spacing: 0) {
                titleRow
                searchField

                ScrollView {
                    LazyVStack(spacing: Constants.Spacing.md) {
                    // AI morning briefing (once per day, dismissible)
                    if searchText.isEmpty {
                        MorningBriefingCard(state: briefingVM.state) {
                            withAnimation(Constants.Animation.standard) { briefingVM.dismiss() }
                        }
                    }

                    // Habits Section - Daily Checklist
                    if !data.habits.isEmpty {
                        HabitsSection(habits: data.habits)
                    }

                    // Action items the assistant derived from the calendar —
                    // above Needs Attention because they're time-boxed by an
                    // event date the user can't move. Hidden while searching
                    // (the section doesn't read the query).
                    if searchText.isEmpty, !calendarPending.isEmpty || !calendarAutoAdded.isEmpty {
                        CalendarSuggestionsSection(
                            pending: calendarPending,
                            autoAddedToday: calendarAutoAdded
                        )
                    }

                    // Urgent / Time-sensitive / High Priority - grouped by category
                    if !data.needsAttention.isEmpty {
                        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                            TodaySectionHeader(
                                icon: "exclamationmark.circle.fill",
                                tint: AppColors.destructive,
                                title: "Needs Attention",
                                count: "\(data.needsAttention.count)"
                            )

                            VStack(alignment: .leading, spacing: Constants.Spacing.md) {
                                ForEach(Array(data.needsAttentionByCategory.enumerated()), id: \.offset) { _, group in
                                    VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                                        // Category header
                                        if let category = group.category {
                                            HStack(spacing: Constants.Spacing.xxs) {
                                                Image(systemName: category.icon)
                                                    .font(.caption2.weight(.semibold))
                                                Text(category.name)
                                                    .font(.caption.weight(.semibold))
                                            }
                                            .foregroundStyle(category.color)
                                        } else {
                                            Text("Uncategorized")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }

                                        // Reminders in this category
                                        ForEach(group.reminders) { reminder in
                                            NeedsAttentionRow(reminder: reminder)
                                        }
                                    }
                                }
                            }
                        }
                        .todaySectionCard(tint: AppColors.destructive)
                    }

                    // Upcoming - due in the next 2 days
                    if !data.upcoming.isEmpty {
                        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
                            TodaySectionHeader(
                                icon: "calendar.badge.clock",
                                tint: AppColors.accent,
                                title: "Upcoming",
                                count: "\(data.upcoming.count)"
                            )

                            VStack(spacing: Constants.Spacing.xs) {
                                ForEach(data.upcoming) { reminder in
                                    UpcomingReminderRow(reminder: reminder)
                                }
                            }
                        }
                        .todaySectionCard(tint: AppColors.accent)
                    }

                    // Categories with reminders
                    ForEach(categories.filter { !$0.isHabits }) { category in
                        let categoryReminders = data.byCategory[category.id] ?? []
                        if !categoryReminders.isEmpty {
                            HomeCategorySection(
                                category: category,
                                reminders: categoryReminders
                            )
                        }
                    }

                    // Items without a category (e.g. imported) — keep them visible
                    if !data.uncategorized.isEmpty {
                        UncategorizedSection(reminders: data.uncategorized)
                    }

                    // Empty states
                    if data.isEmpty {
                        if searchText.isEmpty {
                            ContentUnavailableView(
                                "All Caught Up",
                                systemImage: "checkmark.circle",
                                description: Text("Nothing needs your attention right now. Ask the Assistant or tap + to add a reminder.")
                            )
                            .padding(.top, Constants.Spacing.xl)
                        } else {
                            ContentUnavailableView(
                                "No Results",
                                systemImage: "magnifyingglass",
                                description: Text("No reminders match \"\(searchText)\"")
                            )
                            .padding(.top, Constants.Spacing.xl)
                        }
                    }
                    }
                    .padding()
                }
            }
            .background(AppColors.background)
            .navigationTitle("Gentle Nudge")
            #if os(iOS)
            // Title + search now live in the custom header (`titleRow` /
            // `searchField`), with the manual-add "+" on the title's line. Hide
            // the system nav bar so there's no duplicate title and no separate
            // top row for the "+".
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
            #endif
            .hidesNativeTabBar()
        }
        #if os(iOS)
        .sheet(isPresented: $showingAddReminder) {
            AddReminderView()
        }
        #endif
        .task {
            await briefingVM.refreshIfNeeded(reminders: reminderSummaries)
        }
        // Once-a-day calendar pass, gated inside the coordinator. Separate task
        // so a slow triage call can't hold up the briefing.
        .task {
            await calendarCoordinator.scanIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await briefingVM.refreshIfNeeded(reminders: reminderSummaries) }
                Task { await calendarCoordinator.scanIfNeeded() }
            }
        }
        .onChange(of: reminders) { _, _ in
            // Data may finish loading (e.g. CloudKit sync) after the first pass.
            Task { await briefingVM.refreshIfNeeded(reminders: reminderSummaries) }
        }
        // The app changing what it does unasked has to be announced once, not
        // discovered later in Settings.
        .alert(
            "Noted",
            isPresented: Binding(
                get: { calendarCoordinator.learningNotice != nil },
                set: { if !$0 { calendarCoordinator.learningNotice = nil } }
            )
        ) {
            Button("OK") { calendarCoordinator.learningNotice = nil }
        } message: {
            Text(calendarCoordinator.learningNotice ?? "")
        }
    }
}

// MARK: - Morning Briefing Card (in-app, path b)

/// A dismissible card shown once per day at the top of the Today screen with an
/// AI-prioritized (or locally-summarized) briefing. Renders nothing when hidden.
struct MorningBriefingCard: View {
    let state: MorningBriefingViewModel.DisplayState
    let onDismiss: () -> Void

    var body: some View {
        switch state {
        case .hidden:
            EmptyView()

        case .loading:
            container {
                HStack(spacing: Constants.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing your morning briefing…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

        case .shown(let briefing):
            container {
                VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                    HStack(spacing: Constants.Spacing.xs) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(AppColors.accent)
                        Text("Morning Briefing")
                            .font(.headline)
                        Spacer()
                        Button(action: onDismiss) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                                // ~44pt hit target without growing the visible icon.
                                .contentShape(Rectangle().inset(by: -12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss briefing")
                    }
                    Text(briefing.inAppBriefing)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func container<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .todaySectionCard(tint: AppColors.accent)
    }
}

// MARK: - Shared Today chrome

/// One header style for every Today section — tinted icon, headline title, and a
/// right-aligned count — so the sections read as one system.
struct TodaySectionHeader: View {
    let icon: String
    let tint: Color
    let title: String
    var count: String?

    var body: some View {
        HStack(spacing: Constants.Spacing.xs) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
            Spacer()
            if let count {
                Text(count)
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

extension View {
    /// Shared container chrome for a Today section: consistent padding, a soft
    /// tint wash, and a continuous corner radius.
    func todaySectionCard(tint: Color) -> some View {
        self
            .padding(Constants.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Constants.CornerRadius.lg, style: .continuous)
                    .fill(tint.opacity(0.08))
            )
    }

    /// Shared chrome for a reminder card inside a section: solid fill plus a
    /// hairline border so cards keep their edge in both light and dark mode.
    func todayRowCard() -> some View {
        self
            .background(
                AppColors.background,
                in: RoundedRectangle(cornerRadius: Constants.CornerRadius.md, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Constants.CornerRadius.md, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}

// MARK: - Habits Section

struct HabitsSection: View {
    let habits: [Reminder]

    private var completedCount: Int {
        habits.filter { $0.isCompletedToday }.count
    }

    private let habitColor: Color = .teal

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
            TodaySectionHeader(
                icon: "leaf.circle.fill",
                tint: habitColor,
                title: "Habits",
                count: "\(completedCount)/\(habits.count)"
            )

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(habitColor.opacity(0.2))
                        .frame(height: 5)

                    Capsule()
                        .fill(habitColor)
                        .frame(width: geo.size.width * CGFloat(completedCount) / CGFloat(max(habits.count, 1)), height: 5)
                        .animation(.spring, value: completedCount)
                }
            }
            .frame(height: 5)

            VStack(spacing: Constants.Spacing.xs) {
                ForEach(habits) { habit in
                    HabitRow(habit: habit)
                }
            }
        }
        .todaySectionCard(tint: habitColor)
    }
}

struct HabitRow: View {
    @Bindable var habit: Reminder
    @State private var showingHeatmap = false

    var isCompletedToday: Bool {
        habit.isCompletedToday
    }

    private var currentStreak: Int {
        let calendar = Calendar.current
        var streak = 0
        var checkDate = calendar.startOfDay(for: Date())

        if !habit.wasCompletedOn(date: checkDate) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: checkDate) else {
                return 0
            }
            checkDate = yesterday
        }

        while habit.wasCompletedOn(date: checkDate) {
            streak += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: checkDate) else {
                break
            }
            checkDate = previousDay
        }

        return streak
    }

    /// One-element VoiceOver summary: title, today's status, streak, and the
    /// same 14-day window the mini heatmap draws.
    private var accessibilityRowLabel: String {
        var parts = [habit.title, isCompletedToday ? "Done today" : "Not done today"]
        if currentStreak > 0 {
            parts.append("\(currentStreak) day streak")
        }
        parts.append("Done \(habit.completionCount(days: 14)) of the last 14 days")
        return parts.joined(separator: ", ")
    }

    private func toggleDoneToday() {
        withAnimation(Constants.Animation.spring) {
            HapticManager.impact(.medium)
            if isCompletedToday {
                habit.clearHabitCompletion()
            } else {
                habit.markHabitDoneToday()
            }
        }
    }

    var body: some View {
        HStack(spacing: Constants.Spacing.sm) {
            Button {
                toggleDoneToday()
            } label: {
                Image(systemName: isCompletedToday ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isCompletedToday ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    // ~44pt hit target without growing the visible icon.
                    .contentShape(Rectangle().inset(by: -10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isCompletedToday ? "Done today" : "Mark done today")

            Text(habit.title)
                .font(.body)
                .foregroundStyle(isCompletedToday ? .secondary : .primary)
                .strikethrough(isCompletedToday)

            Spacer()

            // Streak indicator
            if currentStreak > 0 {
                Image(systemName: "flame.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            #if os(iOS)
            // Mini heatmap (last 14 days)
            HabitMiniHeatmap(habit: habit)
            #endif
        }
        .padding(.vertical, Constants.Spacing.xs)
        .padding(.horizontal, Constants.Spacing.sm)
        .todayRowCard()
        #if os(iOS)
        .contentShape(Rectangle())
        .onTapGesture {
            showingHeatmap = true
        }
        // Swipe-left reveals Done only — no Delete (habit deletion deliberately
        // stays in the detail view). Routes through the same mark-done-today
        // mechanism as the leading circle; idempotent when already done today.
        .reminderSwipeActions([
            RowSwipeAction(title: "Done", systemImage: "checkmark", tint: AppColors.success) {
                withAnimation(Constants.Animation.spring) {
                    HapticManager.impact(.medium)
                    habit.markHabitDoneToday()
                }
            }
        ])
        .sheet(isPresented: $showingHeatmap) {
            HabitDetailSheet(habit: habit)
        }
        #endif
        // VoiceOver: one element per row (title + status + history), with the
        // toggle and detail-sheet tap re-exposed as named actions.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityRowLabel)
        #if os(iOS)
        // Deterministic default activation (double-tap): open the detail sheet.
        .accessibilityAction {
            showingHeatmap = true
        }
        #endif
        .accessibilityActions {
            Button(isCompletedToday ? "Mark not done today" : "Mark done today") {
                toggleDoneToday()
            }
            #if os(iOS)
            Button("Open habit details") {
                showingHeatmap = true
            }
            #endif
        }
    }
}

#if os(iOS)
struct HabitDetailSheet: View {
    @Bindable var habit: Reminder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Constants.Spacing.lg) {
                    // 8 weeks: the stats row and the drawn grid share this one
                    // window (the grid used to draw 8 weeks while the stats
                    // counted 16, so "done X of 112 days" didn't describe the
                    // visible grid). 8 keeps the sheet's compact heatmap size.
                    HabitHeatmapView(habit: habit, weeks: 8)

                    // Stats
                    VStack(spacing: Constants.Spacing.sm) {
                        HabitStatRow(title: "Last 7 days", value: "\(habit.completionCount(days: 7))/7")
                        HabitStatRow(title: "Last 30 days", value: "\(habit.completionCount(days: 30))/30")
                        HabitStatRow(title: "Total completions", value: "\(habit.habitCompletionDates.count)")
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: Constants.CornerRadius.md)
                            .fill(Color.secondary.opacity(0.1))
                    )
                }
                .padding()
            }
            .background(AppColors.background)
            .navigationTitle(habit.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct HabitStatRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
    }
}
#endif

// MARK: - Upcoming Reminder Row

struct UpcomingReminderRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var reminder: Reminder
    @State private var showingDetail = false

    private var daysUntilText: String {
        guard let days = reminder.daysUntilDue else { return "" }
        if days == 1 { return "Tomorrow" }
        return "in \(days) days"
    }

    /// One-element VoiceOver summary: title, due wording, in-progress state.
    private var accessibilityRowLabel: String {
        var parts = [reminder.title]
        if reminder.isCompleted {
            parts.append("Completed")
        } else {
            if !daysUntilText.isEmpty {
                parts.append("Due \(daysUntilText.lowercased())")
            }
            if reminder.isInProgress {
                parts.append("In progress")
            }
        }
        return parts.joined(separator: ", ")
    }

    private func toggleCompletion() {
        withAnimation(Constants.Animation.spring) {
            HapticManager.impact(.medium)
            if reminder.isCompleted {
                reminder.uncomplete(in: modelContext)
            } else {
                completeReminder()
            }
        }
    }

    var body: some View {
        HStack(spacing: Constants.Spacing.sm) {
            // Completion toggle
            Button {
                toggleCompletion()
            } label: {
                // In-progress reads at a glance: half-filled indigo circle.
                // Tapping still completes, exactly as before.
                Image(systemName: reminder.isCompleted
                    ? "checkmark.circle.fill"
                    : (reminder.isInProgress ? "circle.lefthalf.filled" : "circle"))
                    .font(.body)
                    .foregroundStyle(reminder.isCompleted
                        ? Color.green
                        : (reminder.isInProgress ? Color.indigo : Color.secondary))
                    // ~44pt hit target without growing the visible icon.
                    .contentShape(Rectangle().inset(by: -12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reminder.isCompleted ? "Mark not done" : "Mark complete")

            // Content
            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                HStack(spacing: Constants.Spacing.xs) {
                    // Category
                    if let category = reminder.category {
                        HStack(spacing: 2) {
                            Image(systemName: category.icon)
                                .font(.system(size: 10))
                            Text(category.name)
                                .font(.caption2)
                        }
                        .foregroundStyle(category.color)
                    }

                    // Due date
                    Text(daysUntilText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppColors.accent)

                    // Recurrence badge
                    if reminder.isRecurring {
                        RecurrenceBadge(recurrence: reminder.recurrence, compact: true)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, Constants.Spacing.xs)
        .padding(.horizontal, Constants.Spacing.sm)
        .todayRowCard()
        .contentShape(Rectangle())
        .onTapGesture {
            showingDetail = true
        }
        // Long-press toggles in-progress directly (see NeedsAttentionRow for
        // the gesture-ordering rationale).
        .onLongPressGesture {
            guard !reminder.isCompleted && !reminder.isHabit else { return }
            withAnimation(Constants.Animation.spring) {
                HapticManager.impact(.light)
                reminder.setInProgress(!reminder.isInProgress)
            }
        }
        // Swipe-left reveals Complete/Delete behind the card (reveal-then-tap;
        // see NeedsAttentionRow for the attachment-order rationale).
        .reminderSwipeActions([
            RowSwipeAction(title: "Complete", systemImage: "checkmark", tint: AppColors.success) {
                toggleCompletion()
            },
            RowSwipeAction(title: "Delete", systemImage: "trash", tint: AppColors.destructive) {
                withAnimation {
                    modelContext.delete(reminder)
                }
            },
        ])
        .sheet(isPresented: $showingDetail) {
            NavigationStack {
                ReminderDetailView(reminder: reminder)
            }
            .presentationDetents([.medium, .large])
        }
        // VoiceOver: one element per row, with the toggle, the (otherwise
        // unreachable) long-press in-progress toggle, and the open tap all
        // re-exposed as named actions.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityRowLabel)
        // Deterministic default activation (double-tap): open the detail.
        .accessibilityAction {
            showingDetail = true
        }
        .accessibilityActions {
            Button(reminder.isCompleted ? "Mark not done" : "Complete") {
                toggleCompletion()
            }
            // Same guard as the long-press gesture.
            if !reminder.isCompleted && !reminder.isHabit {
                Button(reminder.isInProgress ? "Mark not started" : "Mark In Progress") {
                    withAnimation(Constants.Animation.spring) {
                        HapticManager.impact(.light)
                        reminder.setInProgress(!reminder.isInProgress)
                    }
                }
            }
            Button("Open") {
                showingDetail = true
            }
            // Parity with the sighted-user swipe Delete.
            Button("Delete", role: .destructive) {
                withAnimation {
                    modelContext.delete(reminder)
                }
            }
        }
    }

    private func completeReminder() {
        reminder.complete(in: modelContext)
    }
}

// MARK: - Needs Attention Row

struct NeedsAttentionRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var reminder: Reminder
    @State private var showingDetail = false

    /// One-element VoiceOver summary: title, due/overdue wording (via the same
    /// `dueText` the row draws), in-progress state.
    private var accessibilityRowLabel: String {
        var parts = [reminder.title]
        if reminder.isCompleted {
            parts.append("Completed")
        } else {
            if let dueDate = reminder.dueDate {
                parts.append(dueText(dueDate))
            }
            if reminder.isInProgress {
                parts.append("In progress")
            }
        }
        return parts.joined(separator: ", ")
    }

    private func toggleCompletion() {
        withAnimation(Constants.Animation.spring) {
            HapticManager.impact(.medium)
            if reminder.isCompleted {
                reminder.uncomplete(in: modelContext)
            } else {
                completeReminder()
            }
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Constants.Spacing.xs) {
            // Completion toggle
            Button {
                toggleCompletion()
            } label: {
                // In-progress reads at a glance: half-filled indigo circle.
                // Tapping still completes, exactly as before.
                Image(systemName: reminder.isCompleted
                    ? "checkmark.circle.fill"
                    : (reminder.isInProgress ? "circle.lefthalf.filled" : "circle"))
                    .font(.body)
                    .foregroundStyle(reminder.isCompleted
                        ? Color.green
                        : (reminder.isInProgress ? Color.indigo : Color.secondary))
                    .contentTransition(.symbolEffect(.replace))
                    // ~44pt hit target without growing the visible icon.
                    .contentShape(Rectangle().inset(by: -12))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityLabel(reminder.isCompleted ? "Mark not done" : "Mark complete")

            // Title and metadata
            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(reminder.isCompleted ? .secondary : .primary)
                    .strikethrough(reminder.isCompleted)
                    .fixedSize(horizontal: false, vertical: true)

                // Due date and recurrence info (category shown in group header)
                HStack(spacing: 6) {
                    if let dueDate = reminder.dueDate {
                        Text(dueText(dueDate))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(dueColor(dueDate))
                    }

                    if reminder.isRecurring {
                        RecurrenceBadge(recurrence: reminder.recurrence)
                    }
                }
            }

            Spacer(minLength: Constants.Spacing.xs)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, Constants.Spacing.sm)
        .todayRowCard()
        // The whole card opens the detail sheet (buttons still win their taps),
        // not just the title text.
        .contentShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md, style: .continuous))
        .onTapGesture {
            showingDetail = true
        }
        // Long-press toggles the in-progress sub-state directly — the only
        // in-list way to set it (the indigo half-filled circle shows it).
        // Attached AFTER the tap gesture: when the hold reaches the long-press
        // threshold the long press claims the interaction, so releasing does
        // not also fire the tap-to-open above.
        .onLongPressGesture {
            guard !reminder.isCompleted && !reminder.isHabit else { return }
            withAnimation(Constants.Animation.spring) {
                HapticManager.impact(.light)
                reminder.setInProgress(!reminder.isInProgress)
            }
        }
        // Swipe-left reveals Complete/Delete behind the card (reveal-then-tap;
        // a full swipe never auto-triggers). Attached AFTER the tap/long-press
        // so the whole card slides as one unit and, when open, the modifier's
        // tap-catcher wins the tap (closing instead of opening the detail).
        .reminderSwipeActions([
            RowSwipeAction(title: "Complete", systemImage: "checkmark", tint: AppColors.success) {
                toggleCompletion()
            },
            RowSwipeAction(title: "Delete", systemImage: "trash", tint: AppColors.destructive) {
                withAnimation {
                    modelContext.delete(reminder)
                }
            },
        ])
        .sheet(isPresented: $showingDetail) {
            NavigationStack {
                ReminderDetailView(reminder: reminder)
            }
            .presentationDetents([.medium, .large])
        }
        // VoiceOver: one element per row, with the toggle, the (otherwise
        // unreachable) long-press in-progress toggle, and the open tap all
        // re-exposed as named actions.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityRowLabel)
        // Deterministic default activation (double-tap): open the detail.
        .accessibilityAction {
            showingDetail = true
        }
        .accessibilityActions {
            Button(reminder.isCompleted ? "Mark not done" : "Complete") {
                toggleCompletion()
            }
            // Same guard as the long-press gesture.
            if !reminder.isCompleted && !reminder.isHabit {
                Button(reminder.isInProgress ? "Mark not started" : "Mark In Progress") {
                    withAnimation(Constants.Animation.spring) {
                        HapticManager.impact(.light)
                        reminder.setInProgress(!reminder.isInProgress)
                    }
                }
            }
            Button("Open") {
                showingDetail = true
            }
            // Parity with the sighted-user swipe Delete.
            Button("Delete", role: .destructive) {
                withAnimation {
                    modelContext.delete(reminder)
                }
            }
        }
    }

    private func completeReminder() {
        reminder.complete(in: modelContext)
    }

    /// Overdue wording that says what it means ("3 days overdue") instead of a
    /// bare "3 days ago", plus Today/Tomorrow shortcuts.
    private func dueText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Due today"
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        }
        let today = calendar.startOfDay(for: Date())
        let day = calendar.startOfDay(for: date)
        if day < today, let days = calendar.dateComponents([.day], from: day, to: today).day {
            return days == 1 ? "1 day overdue" : "\(days) days overdue"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    /// Whole-day comparison so an item due later today reads as "due" (warning),
    /// not already "overdue" (red).
    private func dueColor(_ date: Date) -> Color {
        let calendar = Calendar.current
        if calendar.startOfDay(for: date) < calendar.startOfDay(for: Date()) {
            return AppColors.destructive
        }
        if calendar.isDateInToday(date) {
            return AppColors.warning
        }
        return .secondary
    }
}

// MARK: - Uncategorized Section

struct UncategorizedSection: View {
    let reminders: [Reminder]

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
            TodaySectionHeader(
                icon: "questionmark.folder.fill",
                tint: .gray,
                title: "Uncategorized",
                count: "\(reminders.count)"
            )

            VStack(spacing: Constants.Spacing.xxs) {
                ForEach(reminders) { reminder in
                    ReminderRow(reminder: reminder)
                }
            }
        }
        .todaySectionCard(tint: .gray)
    }
}

// MARK: - Home Category Section

struct HomeCategorySection: View {
    let category: Category
    let reminders: [Reminder]

    // Active: non-recurring, or recurring that's due soon (within 3 days)
    private var activeReminders: [Reminder] {
        reminders.filter { !$0.isDistantRecurring }
            .sorted { r1, r2 in
                // In-progress pinned first, then due soon, then priority
                if r1.isInProgress != r2.isInProgress { return r1.isInProgress }
                if r1.isDueToday != r2.isDueToday { return r1.isDueToday }
                if r1.isOverdue != r2.isOverdue { return r1.isOverdue }
                return r1.priority.rawValue > r2.priority.rawValue
            }
    }

    // Upcoming: recurring items due later (muted)
    private var upcomingRecurring: [Reminder] {
        reminders.filter { $0.isDistantRecurring }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
            // Header
            NavigationLink {
                CategoryDetailView(category: category)
            } label: {
                HStack(spacing: Constants.Spacing.xs) {
                    Image(systemName: category.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(category.color)
                    Text(category.name)
                        .font(.headline)
                    Spacer()
                    Text("\(reminders.count)")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)

            // Active reminders
            if !activeReminders.isEmpty {
                VStack(spacing: Constants.Spacing.xxs) {
                    ForEach(activeReminders) { reminder in
                        ReminderRow(reminder: reminder)
                    }
                }
            }

            // Upcoming recurring (collapsed section)
            if !upcomingRecurring.isEmpty {
                DisclosureGroup {
                    VStack(spacing: Constants.Spacing.xxs) {
                        ForEach(upcomingRecurring) { reminder in
                            ReminderRow(reminder: reminder)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "repeat")
                            .font(.caption2)
                        Text("Upcoming (\(upcomingRecurring.count))")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .tint(.secondary)
            }
        }
        .todaySectionCard(tint: category.color)
    }
}

// MARK: - Category Detail View

struct CategoryDetailView: View {
    let category: Category
    @Query private var reminders: [Reminder]

    // Active: non-recurring, or recurring due soon
    private var activeReminders: [Reminder] {
        reminders.filter { $0.category?.id == category.id && !$0.isCompleted && !$0.isDistantRecurring }
            .sorted { r1, r2 in
                // In-progress pinned first, then due soon, then priority
                if r1.isInProgress != r2.isInProgress { return r1.isInProgress }
                if r1.isDueToday != r2.isDueToday { return r1.isDueToday }
                if r1.isOverdue != r2.isOverdue { return r1.isOverdue }
                return r1.priority.rawValue > r2.priority.rawValue
            }
    }

    // Upcoming recurring
    private var upcomingRecurring: [Reminder] {
        reminders.filter { $0.category?.id == category.id && !$0.isCompleted && $0.isDistantRecurring }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private var completedReminders: [Reminder] {
        reminders.filter { $0.category?.id == category.id && $0.isCompleted }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(5)
            .map { $0 }
    }

    private var hasAnyReminders: Bool {
        !activeReminders.isEmpty || !upcomingRecurring.isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Constants.Spacing.sm) {
                if !hasAnyReminders {
                    ContentUnavailableView(
                        "No Reminders",
                        systemImage: category.icon,
                        description: Text("Add reminders to \(category.name)")
                    )
                    .padding(.top, Constants.Spacing.xl)
                } else {
                    // Active reminders
                    if !activeReminders.isEmpty {
                        Section {
                            ForEach(activeReminders) { reminder in
                                ReminderRow(reminder: reminder)
                            }
                        } header: {
                            if !upcomingRecurring.isEmpty {
                                HStack {
                                    Text("Active")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                            }
                        }
                    }

                    // Upcoming recurring
                    if !upcomingRecurring.isEmpty {
                        Section {
                            ForEach(upcomingRecurring) { reminder in
                                ReminderRow(reminder: reminder)
                            }
                        } header: {
                            HStack(spacing: 4) {
                                Image(systemName: "repeat")
                                    .font(.caption)
                                Text("Upcoming Recurring")
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(upcomingRecurring.count)")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .foregroundStyle(.secondary)
                            .padding(.top, activeReminders.isEmpty ? 0 : Constants.Spacing.md)
                        }
                    }
                }

                // Recently completed
                if !completedReminders.isEmpty {
                    Section {
                        ForEach(completedReminders) { reminder in
                            ReminderRow(reminder: reminder)
                        }
                    } header: {
                        HStack {
                            Text("Recently Completed")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.top, Constants.Spacing.lg)
                    }
                }
            }
            .padding()
        }
        .background(AppColors.background)
        .navigationTitle(category.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Reminder.self, Category.self, CalendarSuggestion.self, CalendarAutoRule.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    TodayView()
        .modelContainer(container)
        .environment(CalendarScanCoordinator(modelContainer: container))
}
