#if os(macOS)
import SwiftUI
import SwiftData

// MARK: - Main Mac Content View

struct MacContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(CalendarScanCoordinator.self) private var calendarCoordinator
    @Query private var reminders: [Reminder]
    @Query(sort: \Category.sortOrder) private var categories: [Category]
    @Query private var calendarSuggestions: [CalendarSuggestion]

    @State private var selectedSidebarItem: SidebarItem? = .today
    @State private var selectedReminder: Reminder?
    @State private var showingAddReminder = false
    @State private var showingSettings = false
    @State private var searchText = ""
    @State private var briefingVM = MorningBriefingViewModel()
    /// Per-launch dismissal of the in-memory data-loss banner (deliberately not
    /// persisted — the warning must return on every launch while it applies).
    @State private var storageWarningDismissed = false
    @AppStorage(Constants.DefaultsKeys.habitVisibility)
    private var habitVisibilityRaw = HabitVisibility.all.rawValue

    /// Three-way habit surfacing mode (replaces the old show/hide boolean).
    private var habitVisibility: HabitVisibility {
        HabitVisibility(rawValue: habitVisibilityRaw) ?? .all
    }

    /// Calendar proposals waiting on a yes/no (same list and order as iOS).
    private var calendarPending: [CalendarSuggestion] {
        CalendarSuggestion.pending(from: calendarSuggestions)
    }

    /// Calendar items added automatically today, shown with an Undo.
    private var calendarAutoAdded: [CalendarSuggestion] {
        CalendarSuggestion.autoAddedToday(from: calendarSuggestions)
    }

    /// The sidebar search field's text, trimmed. Non-empty filters the current
    /// list (title/notes, case-insensitive — same rule as iOS `.searchable` in
    /// `AllRemindersView`) and swaps the composite Today page for the flat
    /// filtered list so results are actually visible.
    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    private func applySearch(_ items: [Reminder]) -> [Reminder] {
        guard !searchQuery.isEmpty else { return items }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery) ||
            $0.notes.localizedCaseInsensitiveContains(searchQuery)
        }
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

    // MARK: - Derived lists (same membership/order as iOS TodayView)

    /// Every list the sidebar and content derive from the store. `body` builds
    /// ONE instance per render (`makeDerivedLists()`) and threads it through,
    /// so no derived list is ever filtered/sorted more than once per render.
    /// The old per-list computed vars re-filtered + re-sorted the entire store
    /// on every ACCESS — the Today view's per-category "not already in Needs
    /// Attention" exclusion evaluated one of them inside a per-reminder filter
    /// closure, making that section O(N²).
    private struct DerivedLists {
        /// Overdue/due-today, in-progress pinned first (Today + sidebar count).
        var needsAttention: [Reminder] = []
        /// The same set as ids, for O(1) exclusion in the per-category filters.
        var needsAttentionIDs: Set<UUID> = []
        /// Needs-attention grouped by category (category order, uncategorized last).
        var needsAttentionByCategory: [(category: Category?, reminders: [Reminder])] = []
        /// ALL active habits, title-sorted (Habits sidebar list is the
        /// management/browse surface; visibility mode only governs Today).
        var habits: [Reminder] = []
        /// Habits surfaced on Today under the current visibility mode.
        var visibleHabits: [Reminder] = []
        var scheduled: [Reminder] = []
        var allActive: [Reminder] = []
        var recurring: [Reminder] = []
        var completed: [Reminder] = []
        /// Active, non-habit reminders per category id (in-progress pinned
        /// first, store order otherwise) — sidebar counts + category lists.
        var byCategory: [UUID: [Reminder]] = [:]
        /// Non-"Habits" categories that have at least one active reminder
        /// (habits included, matching the old membership test exactly).
        var categoriesWithReminders: [Category] = []
    }

    /// Single pass over the store; each output keeps the exact membership rules
    /// and sort comparators of the computed vars it replaced (Swift sorts are
    /// stable, and the pass preserves store order, so ties break identically).
    private func makeDerivedLists() -> DerivedLists {
        var lists = DerivedLists()
        var categoryIDsWithActive: Set<UUID> = []

        for reminder in reminders {
            if reminder.isCompleted {
                lists.completed.append(reminder)
                continue
            }
            if let categoryID = reminder.category?.id {
                categoryIDsWithActive.insert(categoryID)
            }
            // Habits leave the pass here, BEFORE any of the general-purpose
            // lists — matching iOS, where a habit only ever reaches the Habits
            // section. Every habit is daily-recurring, so testing `isRecurring`
            // first used to file all of them into the Recurring smart list,
            // where they stayed visible even under "Hide habits".
            if reminder.isHabit {
                lists.habits.append(reminder)
                continue
            }
            if reminder.isRecurring {
                lists.recurring.append(reminder)
            }
            lists.allActive.append(reminder)
            if reminder.dueDate != nil {
                lists.scheduled.append(reminder)
            }
            // Only overdue or due today (not urgent-only items)
            if reminder.isOverdue || reminder.isDueToday {
                lists.needsAttention.append(reminder)
            }
            if let categoryID = reminder.category?.id {
                lists.byCategory[categoryID, default: []].append(reminder)
            }
        }

        // In-progress pinned first, then the existing urgency order
        lists.needsAttention.sort { r1, r2 in
            if r1.isInProgress != r2.isInProgress { return r1.isInProgress }
            if r1.isOverdue != r2.isOverdue { return r1.isOverdue }
            if r1.isDueToday != r2.isDueToday { return r1.isDueToday }
            return r1.priority.rawValue > r2.priority.rawValue
        }
        lists.needsAttentionIDs = Set(lists.needsAttention.map(\.id))

        lists.habits.sort { $0.title < $1.title }
        lists.visibleHabits = lists.habits.filter { habitVisibility.shows($0) }

        // In-progress pinned first, then soonest due date
        lists.scheduled.sort { r1, r2 in
            if r1.isInProgress != r2.isInProgress { return r1.isInProgress }
            return (r1.dueDate ?? .distantFuture) < (r2.dueDate ?? .distantFuture)
        }

        // Stable: in-progress rises to the top, everything else keeps its order
        lists.allActive.sort { $0.isInProgress && !$1.isInProgress }

        // In-progress first, then recurrence frequency (daily first), then
        // next due date
        lists.recurring.sort { r1, r2 in
            if r1.isInProgress != r2.isInProgress { return r1.isInProgress }
            if r1.recurrence.sortOrder != r2.recurrence.sortOrder {
                return r1.recurrence.sortOrder < r2.recurrence.sortOrder
            }
            return (r1.dueDate ?? .distantFuture) < (r2.dueDate ?? .distantFuture)
        }

        lists.completed.sort { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }

        // Stable: in-progress rises to the top, everything else keeps its order
        for key in lists.byCategory.keys {
            lists.byCategory[key]?.sort { $0.isInProgress && !$1.isInProgress }
        }

        // Needs attention grouped by category
        var grouped: [UUID?: [Reminder]] = [:]
        for reminder in lists.needsAttention {
            grouped[reminder.category?.id, default: []].append(reminder)
        }
        for category in categories {
            if let group = grouped[category.id], !group.isEmpty {
                lists.needsAttentionByCategory.append((category: category, reminders: group))
            }
        }
        if let uncategorized = grouped[nil], !uncategorized.isEmpty {
            lists.needsAttentionByCategory.append((category: nil, reminders: uncategorized))
        }

        lists.categoriesWithReminders = categories.filter {
            !$0.isHabits && categoryIDsWithActive.contains($0.id)
        }
        return lists
    }

    // MARK: - Body

    var body: some View {
        // ONE snapshot of every derived list per render — sidebar counts and
        // both content lists all read from it (mirrors TodayView's
        // `let data = categorizedReminders` pattern).
        let lists = makeDerivedLists()
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
                        count: lists.needsAttention.count,
                        isSelected: selectedSidebarItem == .today
                    ) { selectedSidebarItem = .today }

                    SmartListCard(
                        icon: "calendar.badge.clock",
                        color: .red,
                        title: "Scheduled",
                        count: lists.scheduled.count,
                        isSelected: selectedSidebarItem == .scheduled
                    ) { selectedSidebarItem = .scheduled }

                    SmartListCard(
                        icon: "tray.circle.fill",
                        color: .gray,
                        title: "All",
                        count: lists.allActive.count,
                        isSelected: selectedSidebarItem == .all
                    ) { selectedSidebarItem = .all }

                    SmartListCard(
                        icon: "arrow.trianglehead.2.clockwise.rotate.90.circle.fill",
                        color: .orange,
                        title: "Recurring",
                        count: lists.recurring.count,
                        isSelected: selectedSidebarItem == .recurring
                    ) { selectedSidebarItem = .recurring }

                    if habitVisibility != .none {
                        SmartListCard(
                            icon: "leaf.circle.fill",
                            color: .teal,
                            title: "Habits",
                            count: lists.habits.count,
                            isSelected: selectedSidebarItem == .habits
                        ) { selectedSidebarItem = .habits }
                    }

                    SmartListCard(
                        icon: "checkmark.circle.fill",
                        color: .gray,
                        title: "Completed",
                        count: lists.completed.count,
                        isSelected: selectedSidebarItem == .completed
                    ) { selectedSidebarItem = .completed }
                }
                .padding(12)

                Divider()
                    .padding(.horizontal, 12)

                // My Lists
                List(selection: $selectedSidebarItem) {
                    Section("My Lists") {
                        ForEach(categories.filter { !$0.isHabits }) { category in
                            Label {
                                HStack {
                                    Text(category.name)
                                    Spacer()
                                    Text("\(lists.byCategory[category.id]?.count ?? 0)")
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
                        // Single source of truth with Settings' Sync row: the
                        // ACTIVE storage mode chosen at launch, not the iCloud
                        // sign-in state (signed in ≠ CloudKit actually running —
                        // the two used to disagree here after a CloudKit init
                        // failure). Reuses SettingsView's label/icon/color.
                        HStack(spacing: 6) {
                            Image(systemName: SettingsView.syncIcon)
                                .foregroundStyle(SettingsView.syncColor)
                                .font(.caption)
                            Text(SettingsView.syncLabel)
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
                    .accessibilityLabel("Settings")
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
                        .accessibilityLabel("New Reminder")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                    // Reminder List - same structure as iOS TodayView. While a
                    // search is active, Today's composite page yields to the
                    // flat filtered list (the sections don't read the query).
                    if selectedSidebarItem == .today && searchQuery.isEmpty {
                        todayListView(lists)
                    } else {
                        standardListView(lists)
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
        // In-memory fallback = silent data loss. Mirror the iOS banner across
        // the whole window (dismissible per launch); mode is fixed at launch.
        .safeAreaInset(edge: .top, spacing: 0) {
            if AppState.shared.storageMode == .memory && !storageWarningDismissed {
                StorageWarningBanner(dismissed: $storageWarningDismissed)
            }
        }
        .sheet(isPresented: $showingAddReminder) {
            MacAddReminderSheet()
        }
        .sheet(isPresented: $showingSettings) {
            MacSettingsSheet()
        }
        .onChange(of: habitVisibilityRaw) { _, _ in
            // Don't leave the hidden Habits list selected
            if habitVisibility == .none && selectedSidebarItem == .habits {
                selectedSidebarItem = .today
            }
        }
        .task {
            await briefingVM.refreshIfNeeded(reminders: reminderSummaries)
        }
        // Once-a-day calendar pass, gated inside the coordinator. Its own task so
        // a slow triage call can't hold up the briefing.
        .task {
            await calendarCoordinator.scanIfNeeded()
        }
        // Daily local snapshot. The Mac used to skip this entirely (only the iOS
        // root called it), so a Mac-only day left no backup behind.
        .task {
            await DailyBackup.run(context: modelContext)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task { await briefingVM.refreshIfNeeded(reminders: reminderSummaries) }
                Task { await calendarCoordinator.scanIfNeeded() }
            }
        }
        .onChange(of: reminders) { _, _ in
            // If the reminder shown in the detail panel was deleted out from
            // under us (assistant tool call, another device via CloudKit),
            // clear the selection before the panel body reads an invalidated
            // model. Check `isDeleted` first so we never touch properties of
            // an already-invalidated model.
            if let sel = selectedReminder,
               sel.isDeleted || !reminders.contains(where: { $0.id == sel.id }) {
                selectedReminder = nil
            }
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

    // MARK: - Today List View (matches iOS TodayView order)

    private func todayListView(_ lists: DerivedLists) -> some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // AI morning briefing (once per day, dismissible)
                MorningBriefingCard(state: briefingVM.state) {
                    withAnimation(Constants.Animation.standard) { briefingVM.dismiss() }
                }

                // All-clear state
                if lists.visibleHabits.isEmpty
                    && lists.needsAttention.isEmpty
                    && lists.categoriesWithReminders.isEmpty
                    && calendarPending.isEmpty
                    && calendarAutoAdded.isEmpty {
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

                // Action items derived from the calendar (same placement as iOS:
                // above Needs Attention, since an event date can't be moved).
                if !calendarPending.isEmpty || !calendarAutoAdded.isEmpty {
                    CalendarSuggestionsSection(
                        pending: calendarPending,
                        autoAddedToday: calendarAutoAdded
                    )
                }

                // Habits Section
                if !lists.visibleHabits.isEmpty {
                    MacSectionCard(title: "Habits", icon: "leaf.circle.fill", color: .teal) {
                        // Progress bar
                        let completed = lists.visibleHabits.filter { $0.isCompletedToday }.count
                        VStack(spacing: 8) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.teal.opacity(0.2))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.teal)
                                        .frame(width: geo.size.width * CGFloat(completed) / CGFloat(max(lists.visibleHabits.count, 1)))
                                }
                            }
                            .frame(height: 6)

                            ForEach(lists.visibleHabits) { habit in
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
                if !lists.needsAttention.isEmpty {
                    MacSectionCard(title: "Needs Attention", icon: "exclamationmark.circle.fill", color: .red) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(lists.needsAttentionByCategory.enumerated()), id: \.offset) { _, group in
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
                ForEach(lists.categoriesWithReminders) { category in
                    // O(1) set-membership exclusion (this used to re-evaluate the
                    // full filtered+sorted needs-attention list per reminder).
                    let categoryReminders = (lists.byCategory[category.id] ?? []).filter { r in
                        !lists.needsAttentionIDs.contains(r.id)
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

    private func standardListView(_ lists: DerivedLists) -> some View {
        // Bound once per render (was a computed var evaluated twice per body:
        // once for the ForEach and again for the empty-state overlay).
        let displayed = displayedReminders(lists)
        return List(selection: $selectedReminder) {
            ForEach(displayed) { reminder in
                MacReminderRow(reminder: reminder, isHabit: selectedSidebarItem == .habits, isSelected: selectedReminder?.id == reminder.id) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedReminder = selectedReminder?.id == reminder.id ? nil : reminder
                    }
                }
                .tag(reminder)
                .listRowSeparator(.visible)
            }
            .onDelete { offsets in
                deleteReminders(at: offsets, from: displayed)
            }
        }
        .listStyle(.plain)
        .overlay {
            if displayed.isEmpty {
                emptyStateView
            }
        }
    }

    private func displayedReminders(_ lists: DerivedLists) -> [Reminder] {
        let base: [Reminder]
        switch selectedSidebarItem {
        case .chat:
            base = []
        case .today:
            base = lists.needsAttention
        case .scheduled:
            base = lists.scheduled
        case .all:
            base = lists.allActive
        case .recurring:
            base = lists.recurring
        case .completed:
            base = lists.completed
        case .habits:
            // The Habits list is the management surface: it shows ALL habits
            // (not just the focus selection); only "Hide habits" empties it.
            base = habitVisibility == .none ? [] : lists.habits
        case .category(let cat):
            base = lists.byCategory[cat.id] ?? []
        case .none:
            base = []
        }
        // The sidebar search filters whatever list is showing (no-op when empty).
        return applySearch(base)
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
        if !searchQuery.isEmpty {
            return "No matches for “\(searchQuery)”"
        }
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

    private func deleteReminders(at offsets: IndexSet, from displayed: [Reminder]) {
        for index in offsets {
            let reminder = displayed[index]
            // Don't leave the detail panel bound to a deleted model.
            if selectedReminder?.id == reminder.id {
                selectedReminder = nil
            }
            modelContext.delete(reminder)
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

    /// One-element VoiceOver summary: title, then completion/due/in-progress
    /// (or done-today + streak for habits).
    private var accessibilityRowLabel: String {
        var parts = [reminder.title]
        if isHabit {
            parts.append(isChecked ? "Done today" : "Not done today")
            if currentStreak > 0 {
                parts.append("\(currentStreak) day streak")
            }
        } else if isChecked {
            parts.append("Completed")
        } else {
            if let dueDate = reminder.dueDate {
                let text = formatDate(dueDate)
                parts.append(reminder.isOverdue ? "Overdue, \(text)" : "Due \(text)")
            }
            if reminder.isInProgress {
                parts.append("In progress")
            }
        }
        return parts.joined(separator: ", ")
    }

    private var toggleAccessibilityName: String {
        if isHabit {
            return isChecked ? "Mark not done today" : "Mark done today"
        }
        return isChecked ? "Mark not done" : "Mark complete"
    }

    /// Title-case variant of the same wording for the right-click menu.
    private var completionMenuTitle: String {
        if isHabit {
            return isChecked ? "Mark Not Done Today" : "Mark Done Today"
        }
        return isChecked ? "Mark Not Done" : "Mark Complete"
    }

    private func toggleCompletion() {
        withAnimation(.spring(response: 0.3)) {
            if isHabit {
                reminder.isCompletedToday ? reminder.clearHabitCompletion() : reminder.markHabitDoneToday()
            } else {
                reminder.isCompleted ? reminder.uncomplete(in: modelContext) : completeReminder()
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox
            Button {
                toggleCompletion()
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
                    // ~44pt hit target without growing the visible icon.
                    .contentShape(Rectangle().inset(by: -10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(toggleAccessibilityName)

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

        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        // Press-and-hold toggles the in-progress sub-state directly (shown by
        // the indigo half-filled circle). Attached AFTER the tap gesture: a
        // completed long press claims the interaction, so releasing does not
        // also fire the selection tap above.
        .onLongPressGesture {
            guard !isHabit && !reminder.isCompleted else { return }
            withAnimation(.spring(response: 0.3)) {
                reminder.setInProgress(!reminder.isInProgress)
            }
        }
        // Right-click menu — the discoverable Mac idiom for the row's actions,
        // so complete/delete don't require opening the detail panel.
        .contextMenu {
            // Same toggle as the checkbox (done-today wording for habits).
            Button {
                toggleCompletion()
            } label: {
                Label(
                    completionMenuTitle,
                    systemImage: isChecked ? "circle" : "checkmark.circle"
                )
            }
            if !isHabit && !reminder.isCompleted {
                Button {
                    withAnimation(.spring(response: 0.3)) {
                        reminder.setInProgress(!reminder.isInProgress)
                    }
                } label: {
                    Label(
                        reminder.isInProgress ? "Mark Not Started" : "Mark In Progress",
                        systemImage: reminder.isInProgress ? "circle" : "circle.lefthalf.filled"
                    )
                }
            }
            // Delete matches the list/detail behavior (`modelContext.delete`;
            // the root's reminders observer clears any detail selection).
            // Habits are managed from their own surfaces — no surprise Delete
            // that would wipe a habit's whole history from a Today row.
            if !isHabit {
                Divider()
                Button(role: .destructive) {
                    modelContext.delete(reminder)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .opacity(isMuted ? 0.6 : 1.0)
        // VoiceOver: one element per row, with the checkbox, the (otherwise
        // unreachable) press-and-hold / right-click in-progress toggle, and
        // the selection tap re-exposed as named actions.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityRowLabel)
        // Deterministic default activation: same as clicking the row.
        .accessibilityAction {
            onTap()
        }
        .accessibilityActions {
            Button(toggleAccessibilityName) {
                toggleCompletion()
            }
            // Same guard as the press-and-hold and the right-click menu.
            if !isHabit && !reminder.isCompleted {
                Button(reminder.isInProgress ? "Mark Not Started" : "Mark In Progress") {
                    withAnimation(.spring(response: 0.3)) {
                        reminder.setInProgress(!reminder.isInProgress)
                    }
                }
            }
            Button(isSelected ? "Hide Details" : "Show Details") {
                onTap()
            }
        }
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
    @Environment(ChatCoordinator.self) private var coordinator
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var showDeleteConfirmation = false

    /// Local edit buffers: the title/notes fields bind here instead of straight
    /// to the `@Model`, so a keystroke doesn't invalidate every `@Query` in the
    /// app. The panel has no explicit Save, so drafts are committed back
    /// ~0.5s after the last keystroke (debounced), when the selected reminder
    /// changes, and on disappear — no edit is ever dropped. Only fields the
    /// user actually edited are committed (see the baselines below).
    @State private var titleDraft = ""
    @State private var notesDraft = ""
    /// Baselines = the last value each draft was loaded FROM the model with (or
    /// committed back to it). A field is **dirty** — i.e. the user actually typed
    /// in it — exactly when its draft differs from its baseline, so programmatic
    /// loads/reloads never count as user edits. Only dirty fields are committed;
    /// a clean field tracks external model changes (assistant rename, CloudKit
    /// merge) instead of clobbering them with a stale draft on close/switch.
    @State private var titleBaseline = ""
    @State private var notesBaseline = ""
    /// The reminder the drafts belong to. Kept separately from `reminder` so
    /// that when the selection switches (same view identity, new model), the
    /// pending edit still commits to the PREVIOUS reminder.
    @State private var draftTarget: Reminder?
    /// Pending debounced commit; cancelled and replaced on every keystroke.
    @State private var commitTask: Task<Void, Never>?

    private var titleIsDirty: Bool { titleDraft != titleBaseline }
    private var notesIsDirty: Bool { notesDraft != notesBaseline }

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
                .accessibilityLabel("Close details")
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

                    if Constants.isAPIKeyConfigured {
                        Button {
                            commitDrafts()
                            coordinator.startChat(about: reminder)
                        } label: {
                            Label("Chat about this", systemImage: "sparkles")
                                .font(.subheadline)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.purple.opacity(0.12))
                                .foregroundStyle(.purple)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Puts this reminder's details in the assistant, ready to ask about")
                    }

                    Divider()

                    // Title
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Title").font(.caption).foregroundStyle(.secondary)
                        TextField("Title", text: $titleDraft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.body)
                            // Only a USER edit (draft differs from its baseline)
                            // schedules a commit — programmatic reloads move the
                            // baseline with the draft, so they never count.
                            .onChange(of: titleDraft) { _, _ in if titleIsDirty { scheduleCommit() } }
                    }

                    // Notes
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Notes").font(.caption).foregroundStyle(.secondary)
                        TextField("Notes", text: $notesDraft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .lineLimit(3...6)
                            .onChange(of: notesDraft) { _, _ in if notesIsDirty { scheduleCommit() } }
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
                            ForEach(categories.filter { !$0.isHabits }) { category in
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
                            DatePicker("", selection: Binding(get: { dueDate }, set: { setDueDate($0) }), displayedComponents: [.date])
                                .labelsHidden()

                            // Recurrence — only meaningful for a dated reminder, mirroring
                            // the iOS editor. Date edits go through `setDueDate`, which
                            // clears the stored month anchor: `monthAnchorDay` trusts the
                            // stored anchor when the due date sits at a short month's end,
                            // so keeping it would resurrect the old schedule (e.g. "the
                            // 31st") after the user deliberately picked a new day.
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
                                setDueDate(nil)
                                reminder.recurrence = .none
                            }
                            .font(.caption)
                        } else {
                            HStack(spacing: 6) {
                                Button("Today") {
                                    setDueDate(Calendar.current.startOfDay(for: Date()))
                                }
                                Button("Tomorrow") {
                                    setDueDate(Calendar.current.startOfDay(for: Date.tomorrow))
                                }
                                Button("Weekend") {
                                    setDueDate(Date.nextWeekend)
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
        .onAppear {
            loadDrafts()
        }
        // Same view identity, new model: commit the pending edit to the
        // PREVIOUS reminder (still held by `draftTarget`), then rebind.
        .onChange(of: reminder.id) { _, _ in
            commitDrafts()
            loadDrafts()
        }
        // The bound model changed underneath us (assistant rename, CloudKit
        // merge). If the user hasn't touched the field, refresh the draft so the
        // panel shows the new value — and so a later commit can't write the
        // stale draft back over it. A dirty field keeps the user's in-flight
        // edit. The `draftTarget` guard skips the selection-switch case, which
        // the `reminder.id` handler above owns.
        .onChange(of: reminder.title) { _, newValue in
            guard draftTarget?.id == reminder.id, !titleIsDirty else { return }
            titleDraft = newValue
            titleBaseline = newValue
        }
        .onChange(of: reminder.notes) { _, newValue in
            guard draftTarget?.id == reminder.id, !notesIsDirty else { return }
            notesDraft = newValue
            notesBaseline = newValue
        }
        // Panel closed (or torn down): flush any pending debounced edit.
        .onDisappear {
            commitDrafts()
        }
        .confirmationDialog("Delete?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) { modelContext.delete(reminder); onClose() }
        }
    }

    /// All UI due-date edits go through here (mirroring the iOS editor):
    /// picking a new date defines a NEW schedule anchored to that date's own
    /// day-of-month, so any stored month anchor from the old schedule must be
    /// dropped — `monthAnchorDay` trusts the stored anchor when the due date
    /// sits at a short month's end, which would otherwise resurrect e.g. "the
    /// 31st" after the user deliberately moved a month-end date.
    private func setDueDate(_ date: Date?) {
        reminder.dueDate = date
        reminder.recurrenceAnchorDay = nil
    }

    // MARK: Draft commit plumbing

    private func loadDrafts() {
        titleDraft = reminder.title
        titleBaseline = reminder.title
        notesDraft = reminder.notes
        notesBaseline = reminder.notes
        draftTarget = reminder
    }

    /// Debounce: commit ~0.5s after the last keystroke. Each keystroke cancels
    /// and supersedes the pending task.
    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            commitDrafts()
        }
    }

    /// Writes the drafts back to the model they were loaded from — but ONLY the
    /// fields the user actually edited (draft differs from its baseline). An
    /// untouched panel never dirties the store, and a clean field can never
    /// revert an external edit (assistant rename, CloudKit merge) with a stale
    /// draft. Committing marks the field clean again.
    private func commitDrafts() {
        commitTask?.cancel()
        commitTask = nil
        guard let target = draftTarget, !target.isDeleted else { return }
        if titleIsDirty {
            if target.title != titleDraft { target.title = titleDraft }
            titleBaseline = titleDraft
        }
        if notesIsDirty {
            if target.notes != notesDraft { target.notes = notesDraft }
            notesBaseline = notesDraft
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
            // Contrast-aware: near-black on light fills (yellow, mint, …),
            // white on dark ones — white-on-yellow fails legibility.
            .foregroundStyle(isSelected ? category.contrastingForeground : category.color)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
    let container = try! ModelContainer(
        for: Reminder.self, Category.self, UserMemory.self,
        CalendarSuggestion.self, CalendarAutoRule.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    MacContentView()
        .modelContainer(container)
        .environment(CalendarScanCoordinator(modelContainer: container))
}
#endif
