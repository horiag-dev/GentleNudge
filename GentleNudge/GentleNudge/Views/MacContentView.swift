#if os(macOS)
import SwiftUI
import SwiftData

// MARK: - Main Mac Content View

struct MacContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var reminders: [Reminder]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var selectedSidebarItem: SidebarItem? = .today
    @State private var selectedReminder: Reminder?
    @State private var showingAddReminder = false
    @State private var showingSettings = false
    @State private var searchText = ""

    enum SidebarItem: Hashable {
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
            return reminder.isOverdue || reminder.isDueToday || reminder.priority == .high
        }
        .sorted { r1, r2 in
            if r1.isOverdue != r2.isOverdue { return r1.isOverdue }
            if r1.isDueToday != r2.isDueToday { return r1.isDueToday }
            return r1.priority.rawValue > r2.priority.rawValue
        }
    }

    private var habitReminders: [Reminder] {
        reminders.filter { $0.isHabit && !$0.isCompleted }
            .sorted { $0.title < $1.title }
    }

    private var scheduledReminders: [Reminder] {
        reminders.filter { !$0.isCompleted && !$0.isHabit && $0.dueDate != nil }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
    }

    private var allActiveReminders: [Reminder] {
        reminders.filter { !$0.isCompleted && !$0.isHabit }
    }

    private var recurringReminders: [Reminder] {
        reminders.filter { $0.isRecurring && !$0.isCompleted }
            .sorted { r1, r2 in
                // Sort by recurrence frequency (daily first) then by next due date
                if r1.recurrence.rawValue != r2.recurrence.rawValue {
                    return r1.recurrence.rawValue < r2.recurrence.rawValue
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

                    SmartListCard(
                        icon: "heart.circle.fill",
                        color: .pink,
                        title: "Habits",
                        count: habitReminders.count,
                        isSelected: selectedSidebarItem == .habits
                    ) { selectedSidebarItem = .habits }

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
            // MARK: Main Content
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
            }
        }
        .sheet(isPresented: $showingAddReminder) {
            MacAddReminderSheet()
        }
        .sheet(isPresented: $showingSettings) {
            MacSettingsSheet()
        }
    }

    // MARK: - Today List View (matches iOS TodayView order)

    private var todayListView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                // Habits Section
                if !habitReminders.isEmpty {
                    MacSectionCard(title: "Habits", icon: "heart.circle.fill", color: .pink) {
                        // Progress bar
                        let completed = habitReminders.filter { $0.isCompletedToday }.count
                        VStack(spacing: 8) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.pink.opacity(0.2))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.pink)
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

                // Needs Attention Section
                if !needsAttentionReminders.isEmpty {
                    MacSectionCard(title: "Needs Attention", icon: "exclamationmark.circle.fill", color: .red) {
                        ForEach(needsAttentionReminders) { reminder in
                            MacReminderRow(reminder: reminder, isHabit: false, isSelected: selectedReminder?.id == reminder.id, showSnooze: true) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedReminder = selectedReminder?.id == reminder.id ? nil : reminder
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
                    if !categoryReminders.isEmpty {
                        MacSectionCard(title: category.name, icon: category.icon, color: category.color) {
                            ForEach(categoryReminders) { reminder in
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
            return habitReminders
        case .category(let cat):
            return remindersForCategory(cat)
        case .none:
            return []
        }
    }

    private var sidebarTitle: String {
        switch selectedSidebarItem {
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
        case .today: return .blue
        case .scheduled: return .red
        case .all: return .gray
        case .recurring: return .orange
        case .completed: return .gray
        case .habits: return .pink
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.headline)
            }

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Mac Reminder Row

struct MacReminderRow: View {
    @Bindable var reminder: Reminder
    let isHabit: Bool
    let isSelected: Bool
    var showSnooze: Bool = false
    let onTap: () -> Void

    private var isMuted: Bool {
        reminder.isDistantRecurring
    }

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox
            Button {
                withAnimation(.spring(response: 0.3)) {
                    if isHabit {
                        reminder.isCompletedToday ? reminder.clearHabitCompletion() : reminder.markHabitDoneToday()
                    } else {
                        reminder.isCompleted ? reminder.markIncomplete() : reminder.markCompleted()
                    }
                }
            } label: {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChecked ? .green : .secondary)
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

                    if reminder.recurrence != .none && !isMuted {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.trianglehead.2.clockwise")
                            Text(reminder.recurrence.label)
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                }
            }

            Spacer()

            // Snooze button for needs attention items
            if showSnooze {
                Button {
                    snoozeToTomorrow()
                } label: {
                    Text("Snooze")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.orange)
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
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

    private func formatDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func dateColor(_ date: Date) -> Color {
        if date < Date() { return .red }
        if Calendar.current.isDateInToday(date) { return .orange }
        return .secondary
    }

    private func snoozeToTomorrow() {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        reminder.dueDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
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
                        withAnimation { reminder.isCompleted ? reminder.markIncomplete() : reminder.markCompleted() }
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

                    // Category
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Category").font(.caption).foregroundStyle(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(categories.filter { $0.name != "Habits" }) { category in
                                CategoryPill(
                                    category: category,
                                    isSelected: reminder.category?.id == category.id,
                                    action: { reminder.category = reminder.category?.id == category.id ? nil : category }
                                )
                            }
                        }
                    }

                    // Due Date
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Due Date").font(.caption).foregroundStyle(.secondary)
                        if let dueDate = reminder.dueDate {
                            DatePicker("", selection: Binding(get: { dueDate }, set: { reminder.dueDate = $0 }))
                                .labelsHidden()
                            Button("Remove", role: .destructive) { reminder.dueDate = nil }
                                .font(.caption)
                        } else {
                            Button("Add due date") {
                                reminder.dueDate = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date.tomorrow)
                            }
                        }
                    }

                    // Priority
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Priority").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(ReminderPriority.allCases, id: \.self) { p in
                                PriorityPill(priority: p, isSelected: reminder.priority == p) {
                                    reminder.priority = p
                                }
                            }
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

struct PriorityPill: View {
    let priority: ReminderPriority
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon = priority.icon {
                    Image(systemName: icon)
                }
                Text(priority.label)
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(isSelected ? (priority == .none ? .gray : priority.color) : AppColors.secondaryBackground)
            .foregroundStyle(isSelected ? .white : (priority == .none ? .primary : priority.color))
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
        .modelContainer(for: [Reminder.self, Category.self], inMemory: true)
}
#endif
