#if os(macOS)
import SwiftUI
import SwiftData

// MARK: - Main Mac Content View

struct MacContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Query private var reminders: [Reminder]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var selectedSidebarItem: SidebarItem? = .today
    @State private var selectedReminder: Reminder?
    @State private var showingAddReminder = false
    @State private var showingSettings = false
    @State private var searchText = ""
    @State private var briefingVM = MorningBriefingViewModel()
    @AppStorage(Constants.DefaultsKeys.showHabits) private var showHabits = true

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

    enum SidebarItem: Hashable {
        case chat
        case today
        case scheduled
        case all
        case recurring
        case completed
        case habits
        case category(Category)
    }

    // MARK: - Computed Properties (same order as iOS TodayView)

    private var needsAttentionReminders: [Reminder] {
        reminders.filter { reminder in
            guard !reminder.isHabit, !reminder.isCompleted else { return false }
            // Only overdue or due today (not urgent-only items)
            return reminder.isOverdue || reminder.isDueToday
        }
        .sorted { r1, r2 in
            // In-progress pinned first, then the existing urgency order
            if r1.isInProgress != r2.isInProgress { return r1.isInProgress }
            if r1.isOverdue != r2.isOverdue { return r1.isOverdue }
            if r1.isDueToday != r2.isDueToday { return r1.isDueToday }
            return r1.priority.rawValue > r2.priority.rawValue
        }
    }

    // Needs attention grouped by category
    private var needsAttentionByCategory: [(category: Category?, reminders: [Reminder])] {
        var grouped: [UUID?: [Reminder]] = [:]
        for reminder in needsAttentionReminders {
            let key = reminder.category?.id
            grouped[key, default: []].append(reminder)
        }

        var result: [(category: Category?, reminders: [Reminder])] = []
        for category in categories {
            if let reminders = grouped[category.id], !reminders.isEmpty {
                result.append((category: category, reminders: reminders))
            }
        }
        if let uncategorized = grouped[nil], !uncategorized.isEmpty {
            result.append((category: nil, reminders: uncategorized))
        }
        return result
    }

    private var habitReminders: [Reminder] {
        reminders.filter { $0.isHabit && !$0.isCompleted }
            .sorted { $0.title < $1.title }
    }

    private var scheduledReminders: [Reminder] {
        reminders.filter { !$0.isCompleted && !$0.isHabit && $0.dueDate != nil }
            .sorted { r1, r2 in
                // In-progress pinned first, then soonest due date
                if r1.isInProgress != r2.isInProgress { return r1.isInProgress }
                return (r1.dueDate ?? .distantFuture) < (r2.dueDate ?? .distantFuture)
            }
    }

    private var allActiveReminders: [Reminder] {
        reminders.filter { !$0.isCompleted && !$0.isHabit }
            // Stable: in-progress rises to the top, everything else keeps its order
            .sorted { $0.isInProgress && !$1.isInProgress }
    }

    private var recurringReminders: [Reminder] {
        reminders.filter { $0.isRecurring && !$0.isCompleted }
            .sorted { r1, r2 in
                // In-progress first, then recurrence frequency (daily first),
                // then next due date
                if r1.isInProgress != r2.isInProgress { return r1.isInProgress }
                if r1.recurrence.sortOrder != r2.recurrence.sortOrder {
                    return r1.recurrence.sortOrder < r2.recurrence.sortOrder
                }
                return (r1.dueDate ?? .distantFuture) < (r2.dueDate ?? .distantFuture)
            }
    }

    private var completedReminders: [Reminder] {
        reminders.filter { $0.isCompleted }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    private func remindersForCategory(_ category: Category) -> [Reminder] {
        reminders.filter { $0.category?.id == category.id && !$0.isCompleted && !$0.isHabit }
            // Stable: in-progress rises to the top, everything else keeps its order
            .sorted { $0.isInProgress && !$1.isInProgress }
    }

    private var categoriesWithReminders: [Category] {
        categories.filter { cat in
            cat.name != "Habits" && reminders.contains { $0.category?.id == cat.id && !$0.isCompleted }
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView {
            // MARK: Sidebar
            VStack(spacing: 0) {
                // Search
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(AppColors.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 12)
                .padding(.top, 8)

                // Smart Lists Grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    SmartListCard(
                        icon: "calendar.circle.fill",
                        color: .blue,
                        title: "Today",
                        count: needsAttentionReminders.count,
                        isSelected: selectedSidebarItem == .today
                    ) { selectedSidebarItem = .today }

                    SmartListCard(
                        icon: "calendar.badge.clock",
                        color: .red,
                        title: "Scheduled",
                        count: scheduledReminders.count,
                        isSelected: selectedSidebarItem == .scheduled
                    ) { selectedSidebarItem = .scheduled }

                    SmartListCard(
                        icon: "tray.circle.fill",
                        color: .gray,
                        title: "All",
                        count: allActiveReminders.count,
                        isSelected: selectedSidebarItem == .all
                    ) { selectedSidebarItem = .all }

                    SmartListCard(
                        icon: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill",
                        color: .orange,
                        title: "Recurring",
                        count: recurringReminders.count,
                        isSelected: selectedSidebarItem == .recurring
                    ) { selectedSidebarItem = .recurring }

                    if showHabits {
                        SmartListCard(
                            icon: "leaf.circle.fill",
                            color: .teal,
                            title: "Habits",
                            count: habitReminders.count,
                            isSelected: selectedSidebarItem == .habits
                        ) { selectedSidebarItem = .habits }
                    }

                    SmartListCard(
                        icon: "checkmark.circle.fill",
                        color: .gray,
                        title: "Completed",
                        count: completedReminders.count,
                        isSelected: selectedSidebarItem == .completed
                    ) { selectedSidebarItem = .completed }
                }
                .padding(12)

                Divider()
                    .padding(.horizontal, 12)

                // My Lists
                List(selection: $selectedSidebarItem) {
                    Section("My Lists") {
                        ForEach(categories.filter { $0.name != "Habits" }) { category in
                            Label {
                                HStack {
                                    Text(category.name)
                                    Spacer()
                                    Text("\(remindersForCategory(category).count)")
                                        .foregroundStyle(.secondary)
                                        .font(.callout)
                                }
                            } icon: {
                                Image(systemName: category.icon)
                                    .foregroundStyle(category.color)
                            }
                            .tag(SidebarItem.category(category))
                        }
                    }

                    Section {
                        HStack(spacing: 6) {
                            Image(systemName: "icloud.fill")
                                .foregroundStyle(FileManager.default.ubiquityIdentityToken != nil ? .green : .orange)
                                .font(.caption)
                            Text(FileManager.default.ubiquityIdentityToken != nil ? "iCloud" : "Local")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("\(reminders.count)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gear")
                    }
                }
            }
        } detail: {
            // MARK: Main Content — reminders on the left, Assistant docked on the
            // right and always open.
            HSplitView {
                // Reminder List
                VStack(spacing: 0) {
                    // Header
                    HStack {
                        Text(sidebarTitle)
                            .font(.largeTitle)
                            .fontWeight(.bold)
                            .foregroundStyle(sidebarColor)
                        Spacer()
                        Button { showingAddReminder = true } label: {
                            Image(systemName: "plus")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut("n", modifiers: .command)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                    // Reminder List - same structure as iOS TodayView
                    if selectedSidebarItem == .today {
                        todayListView
                    } else {
                        standardListView
                    }
                }
                .frame(minWidth: 400)
                .background(AppColors.background)

                // Detail Panel (only shows when reminder selected)
                if let reminder = selectedReminder {
                    MacReminderDetailPanel(reminder: reminder, onClose: { selectedReminder = nil })
                        .frame(minWidth: 320, idealWidth: 380, maxWidth: 420)
                        .transition(.move(edge: .trailing))
                }

                // Assistant — always-open, docked on the right (Mac).
                ChatView(onOpenSettings: { showingSettings = true })
                    .frame(minWidth: 320, idealWidth: 380, maxWidth: 520)
            }
        }
        .sheet(isPresented: $showingAddReminder) {
            MacAddReminderSheet()
        }
        .sheet(isPresented: $showingSettings) {
            MacSettingsSheet()
        }
        .onChange(of: showHabits) { _, isShown in
            // Don't leave the hidden Habits list selected
            if !isShown && selectedSidebarItem == .habits {
                selectedSidebarItem = .today
            }
        }
        .task {
            await briefingVM.refreshIfNeeded(reminders: reminderSummaries)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await briefingVM.refreshIfNeeded(reminders: reminderSummaries) }
            }
        }
        .onChange(of: reminders) { _, _ in
            // Data may finish loading (e.g. CloudKit sync) after the first pass.
            Task { await briefingVM.refreshIfNeeded(reminders: reminderSummaries) }
        }
    }

    // MARK: - Today List View (matches iOS TodayView order)

    private var todayListView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // AI morning briefing (once per day, dismissible)
                MorningBriefingCard(state: briefingVM.state) {
                    withAnimation(Constants.Animation.standard) { briefingVM.dismiss() }
                }

                // All-clear state
                if (!showHabits || habitReminders.isEmpty)
                    && needsAttentionReminders.isEmpty
                    && categoriesWithReminders.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 48))
                            .foregroundStyle(.tertiary)
                        Text("All caught up!")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                }

                // Habits Section
                if showHabits && !habitReminders.isEmpty {
                    MacSectionCard(title: "Habits", icon: "leaf.circle.fill", color: .teal) {
                        // Progress bar
                        let completed = habitReminders.filter { $0.isCompletedToday }.count
                        VStack(spacing: 8) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.teal.opacity(0.2))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.teal)
                                        .frame(width: geo.size.width * CGFloat(completed) / CGFloat(max(habitReminders.count, 1)))
                                }
                            }
                            .frame(height: 6)

                            ForEach(habitReminders) { habit in
                                MacReminderRow(reminder: habit, isHabit: true, isSelected: selectedReminder?.id == habit.id) {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        selectedReminder = selectedReminder?.id == habit.id ? nil : habit
                                    }
                                }
                            }
                        }
                    }
                }

                // Needs Attention Section - grouped by category
                if !needsAttentionReminders.isEmpty {
                    MacSectionCard(title: "Needs Attention", icon: "exclamationmark.circle.fill", color: .red) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(needsAttentionByCategory.enumerated()), id: \.offset) { _, group in
                                // Category header
                                if let category = group.category {
                                    HStack(spacing: 4) {
                                        Image(systemName: category.icon)
                                            .font(.caption2)
                                        Text(category.name)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                    }
                                    .foregroundStyle(category.color)
                                    .padding(.top, 6)
                                    .padding(.bottom, 2)
                                } else {
                                    Text("Uncategorized")
                                        .font(.caption)
                                        .fontWeight(.medium)
                                        .foregroundStyle(.secondary)
                                        .padding(.top, 6)
                                        .padding(.bottom, 2)
                                }

                                ForEach(group.reminders) { reminder in
                                    MacReminderRow(reminder: reminder, isHabit: false, isSelected: selectedReminder?.id == reminder.id) {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            selectedReminder = selectedReminder?.id == reminder.id ? nil : reminder
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Category Sections
                ForEach(categoriesWithReminders) { category in
                    let categoryReminders = remindersForCategory(category).filter { r in
                        !needsAttentionReminders.contains { $0.id == r.id }
                    }
                    let activeReminders = categoryReminders.filter { !$0.isDistantRecurring }
                    let upcomingRecurring = categoryReminders.filter { $0.isDistantRecurring }
                        .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }

                    if !categoryReminders.isEmpty {
                        MacSectionCard(title: category.name, icon: category.icon, color: category.color) {
                            VStack(alignment: .leading, spacing: 2) {
                                // Active reminders
                                ForEach(activeReminders) { reminder in
                                    MacReminderRow(reminder: reminder, isHabit: false, isSelected: selectedReminder?.id == reminder.id) {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            selectedReminder = selectedReminder?.id == reminder.id ? nil : reminder
                                        }
                                    }
                                }

                                // Upcoming recurring section
                                if !upcomingRecurring.isEmpty {
                                    HStack(spacing: 4) {
                                        Image(systemName: "repeat")
                                            .font(.caption2)
                                        Text("Upcoming")
                                            .font(.caption)
                                        Text("(\(upcomingRecurring.count))")
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .foregroundStyle(.secondary)
                                    .padding(.top, activeReminders.isEmpty ? 0 : 8)
                                    .padding(.bottom, 2)

                                    ForEach(upcomingRecurring) { reminder in
                                        MacReminderRow(reminder: reminder, isHabit: false, isSelected: selectedReminder?.id == reminder.id) {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                selectedReminder = selectedReminder?.id == reminder.id ? nil : reminder
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: - Standard List View

    private var standardListView: some View {
        List(selection: $selectedReminder) {
            ForEach(displayedReminders) { reminder in
                MacReminderRow(reminder: reminder, isHabit: selectedSidebarItem == .habits, isSelected: selectedReminder?.id == reminder.id) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedReminder = selectedReminder?.id == reminder.id ? nil : reminder
                    }
                }
                .tag(reminder)
                .listRowSeparator(.visible)
            }
            .onDelete(perform: deleteReminders)
        }
        .listStyle(.plain)
        .overlay {
            if displayedReminders.isEmpty {
                emptyStateView
            }
        }
    }

    private var displayedReminders: [Reminder] {
        switch selectedSidebarItem {
        case .chat:
            return []
        case .today:
            return needsAttentionReminders
        case .scheduled:
            return scheduledReminders
        case .all:
            return allActiveReminders
        case .recurring:
            return recurringReminders
        case .completed:
            return completedReminders
        case .habits:
            return showHabits ? habitReminders : []
        case .category(let cat):
            return remindersForCategory(cat)
        case .none:
            return []
        }
    }

    private var sidebarTitle: String {
        switch selectedSidebarItem {
        case .chat: return "Assistant"
        case .today: return "Today"
        case .scheduled: return "Scheduled"
        case .all: return "All"
        case .recurring: return "Recurring"
        case .completed: return "Completed"
        case .habits: return "Habits"
        case .category(let cat): return cat.name
        case .none: return "Reminders"
        }
    }

    private var sidebarColor: Color {
        switch selectedSidebarItem {
        case .chat: return .accentColor
        case .today: return .blue
        case .scheduled: return .red
        case .all: return .gray
        case .recurring: return .orange
        case .completed: return .gray
        case .habits: return .teal
        case .category(let cat): return cat.color
        case .none: return .primary
        }
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        switch selectedSidebarItem {
        case .chat: return "Assistant"
        case .today: return "All caught up!"
        case .scheduled: return "No scheduled reminders"
        case .all: return "No reminders"
        case .recurring: return "No recurring reminders"
        case .completed: return "No completed reminders"
        case .habits: return "No habits yet"
        case .category(let cat): return "No reminders in \(cat.name)"
        case .none: return "Select a list"
        }
    }

    private func deleteReminders(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(displayedReminders[index])
        }
    }
}

// MARK: - Smart List Card

struct SmartListCard: View {
    let icon: String
    let color: Color
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(color)
                    Spacer()
                    Text("\(count)")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.primary)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(isSelected ? color.opacity(0.15) : AppColors.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? color : .clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mac Section Card

struct MacSectionCard<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
            }

            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Mac Reminder Row

struct MacReminderRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var reminder: Reminder
    let isHabit: Bool
    let isSelected: Bool
    let onTap: () -> Void

    private var isMuted: Bool {
        reminder.isDistantRecurring
    }

    private var currentStreak: Int {
        guard isHabit else { return 0 }
        let calendar = Calendar.current
        var streak = 0
        var checkDate = calendar.startOfDay(for: Date())

        if !reminder.wasCompletedOn(date: checkDate) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: checkDate) else {
                return 0
            }
            checkDate = yesterday
        }

        while reminder.wasCompletedOn(date: checkDate) {
            streak += 1
            guard let previousDay = calendar.date(byAdding: .day, value: -1, to: checkDate) else {
                break
            }
            checkDate = previousDay
        }

        return streak
    }

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox
            Button {
                withAnimation(.spring(response: 0.3)) {
                    if isHabit {
                        reminder.isCompletedToday ? reminder.clearHabitCompletion() : reminder.markHabitDoneToday()
                    } else {
                        reminder.isCompleted ? reminder.uncomplete(in: modelContext) : completeReminder()
                    }
                }
            } label: {
                // In-progress reads at a glance: half-filled indigo circle.
                // Tapping still completes, exactly as before.
                Image(systemName: isChecked
                    ? "checkmark.circle.fill"
                    : (isInProgress ? "circle.lefthalf.filled" : "circle"))
                    .font(.title3)
                    .foregroundStyle(isChecked
                        ? Color.green
                        : (isInProgress ? Color.indigo : Color.secondary))
            }
            .buttonStyle(.plain)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .lineLimit(2)
                    .strikethrough(isChecked)
                    .foregroundStyle(isChecked || isMuted ? .secondary : .primary)

                HStack(spacing: 8) {
                    if let category = reminder.category, !isHabit {
                        Text(category.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if isMuted, let dueText = reminder.daysUntilDueText {
                        // Show "in X days" for distant recurring
                        HStack(spacing: 2) {
                            Image(systemName: "repeat")
                                .font(.system(size: 9))
                            Text(dueText)
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    } else if let dueDate = reminder.dueDate, !isHabit {
                        Text(formatDate(dueDate))
                            .font(.caption)
                            .foregroundStyle(dateColor(dueDate))
                    }

                    if reminder.isRecurring && !isMuted {
                        RecurrenceBadge(
                            recurrence: reminder.recurrence,
                            compact: false
                        )
                    }
                }
            }

            Spacer()

            // Streak indicator for habits
            if isHabit && currentStreak > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "flame.fill")
                        .font(.caption)
                    Text("\(currentStreak)")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundStyle(.orange)
            }

            // In-progress toggle for active, non-habit reminders — the slot the
            // old Snooze button occupied. "Start" flags the reminder as begun;
            // clicking the indigo "In Progress" badge clears it.
            if !isHabit && !reminder.isCompleted {
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        reminder.setInProgress(!reminder.isInProgress)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: reminder.isInProgress ? "circle.lefthalf.filled" : "play.circle")
                            .font(.caption2)
                        Text(reminder.isInProgress ? "In Progress" : "Start")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(reminder.isInProgress ? Color.indigo : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (reminder.isInProgress ? Color.indigo : Color.secondary).opacity(0.15),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reminder.isInProgress ? "Mark as not started" : "Mark as in progress")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .opacity(isMuted ? 0.6 : 1.0)
    }

    private var isChecked: Bool {
        isHabit ? reminder.isCompletedToday : reminder.isCompleted
    }

    /// The glanceable leading indicator only applies to normal reminders —
    /// habits have no in-progress notion.
    private var isInProgress: Bool {
        !isHabit && reminder.isInProgress
    }

    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        }
        if calendar.isDateInTomorrow(date) {
            return "Tomorrow"
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        // Overdue: relative wording is clearer than a bare past date
        let today = calendar.startOfDay(for: Date())
        let day = calendar.startOfDay(for: date)
        if day < today, let days = calendar.dateComponents([.day], from: day, to: today).day {
            return "\(days) days ago"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func dateColor(_ date: Date) -> Color {
        if date < Date() { return .red }
        if Calendar.current.isDateInToday(date) { return .orange }
        return .secondary
    }

    private func completeReminder() {
        reminder.complete(in: modelContext)
    }
}

// MARK: - Mac Reminder Detail Panel

struct MacReminderDetailPanel: View {
    @Bindable var reminder: Reminder
    let onClose: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var showDeleteConfirmation = false
    @State private var isEnhancing = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Details")
                    .font(.headline)
                Spacer()
                Button { onClose() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()
            .background(AppColors.secondaryBackground)

            Divider()

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Complete toggle
                    Button {
                        withAnimation {
                            if reminder.isCompleted {
                                reminder.uncomplete(in: modelContext)
                            } else {
                                reminder.complete(in: modelContext)
                            }
                        }
                    } label: {
                        Label(
                            reminder.isCompleted ? "Completed" : "Mark Complete",
                            systemImage: reminder.isCompleted ? "checkmark.circle.fill" : "circle"
                        )
                        .foregroundStyle(reminder.isCompleted ? .green : .primary)
                    }
                    .buttonStyle(.plain)

                    Divider()

                    // Title
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Title").font(.caption).foregroundStyle(.secondary)
                        TextField("Title", text: $reminder.title, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.body)
                    }

                    // Notes
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes").font(.caption).foregroundStyle(.secondary)
                        TextField("Notes", text: $reminder.notes, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(3...6)
                    }

                    Divider()

                    // Category (required)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            Text("Category").font(.caption).foregroundStyle(.secondary)
                            if reminder.category == nil {
                                Text("(required)")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                        FlowLayout(spacing: 6) {
                            ForEach(categories.filter { $0.name != "Habits" }) { category in
                                CategoryPill(
                                    category: category,
                                    isSelected: reminder.category?.id == category.id,
                                    action: { reminder.category = category }
                                )
                            }
                        }
                    }

                    // Due Date
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Due Date").font(.caption).foregroundStyle(.secondary)
                        if let dueDate = reminder.dueDate {
                            DatePicker("", selection: Binding(get: { dueDate }, set: { reminder.dueDate = $0 }), displayedComponents: [.date])
                                .labelsHidden()

                            // Recurrence — only meaningful for a dated reminder, mirroring
                            // the iOS editor. Bind straight to `reminder.recurrence`; the
                            // effective month anchor is always re-derived from the current
                            // due date by `Reminder.monthAnchorDay`, so editing the date or
                            // cadence never leaves a stale `recurrenceAnchorDay` that
                            // contradicts the new value — we deliberately don't write it here.
                            RecurrencePicker(recurrence: $reminder.recurrence)

                            if let detailed = reminder.detailedRecurrence {
                                HStack(spacing: 4) {
                                    Image(systemName: "info.circle")
                                        .foregroundStyle(.purple)
                                    Text(detailed)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            // Match the iOS "Clear date": dropping the due date also
                            // clears recurrence (a recurring reminder needs a due date).
                            Button("Remove", role: .destructive) {
                                reminder.dueDate = nil
                                reminder.recurrence = .none
                            }
                            .font(.caption)
                        } else {
                            HStack(spacing: 6) {
                                Button("Today") {
                                    reminder.dueDate = Calendar.current.startOfDay(for: Date())
                                }
                                Button("Tomorrow") {
                                    reminder.dueDate = Calendar.current.startOfDay(for: Date.tomorrow)
                                }
                                Button("Weekend") {
                                    reminder.dueDate = Date.nextWeekend
                                }
                            }
                            .font(.caption)
                        }
                    }

                    Divider()

                    // Metadata
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Created: \(reminder.createdAt.formatted())")
                        if let completed = reminder.completedAt {
                            Text("Completed: \(completed.formatted())")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                    // Delete
                    Button(role: .destructive) { showDeleteConfirmation = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .foregroundStyle(.red)
                }
                .padding()
            }
        }
        .background(AppColors.background)
        .confirmationDialog("Delete?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { modelContext.delete(reminder); onClose() }
        }
    }
}

// MARK: - Supporting Views

struct CategoryPill: View {
    let category: Category
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: category.icon)
                Text(category.name)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? category.color : category.color.opacity(0.15))
            .foregroundStyle(isSelected ? .white : category.color)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Sheets

struct MacAddReminderSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            AddReminderView()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .frame(width: 480, height: 620)
    }
}

struct MacSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .frame(width: 550, height: 700)
    }
}

#Preview {
    MacContentView()
        .modelContainer(for: [Reminder.self, Category.self, UserMemory.self], inMemory: true)
}
#endif
