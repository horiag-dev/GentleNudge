#if os(macOS)
import SwiftUI
import SwiftData

struct MacContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var reminders: [Reminder]
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var selectedSection: SidebarSection? = .needsAttention
    @State private var selectedCategory: Category?
    @State private var showingAddReminder = false
    @State private var searchText = ""

    enum SidebarSection: Hashable {
        case needsAttention
        case habits
        case all
        case category(Category)
    }

    // Needs Attention: overdue, due today, or high priority
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

    private var allReminders: [Reminder] {
        reminders.filter { !$0.isCompleted && !$0.isHabit }
            .sorted { $0.priority.rawValue > $1.priority.rawValue }
    }

    private func remindersForCategory(_ category: Category) -> [Reminder] {
        reminders.filter { reminder in
            guard reminder.category?.id == category.id,
                  !reminder.isCompleted,
                  !reminder.isHabit else { return false }
            return true
        }
        .sorted { $0.priority.rawValue > $1.priority.rawValue }
    }

    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(selection: $selectedSection) {
                Section("Overview") {
                    Label {
                        HStack {
                            Text("Needs Attention")
                            Spacer()
                            if !needsAttentionReminders.isEmpty {
                                Text("\(needsAttentionReminders.count)")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.red.opacity(0.2))
                                    .clipShape(Capsule())
                            }
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .tag(SidebarSection.needsAttention)

                    Label {
                        HStack {
                            Text("Habits")
                            Spacer()
                            let completed = habitReminders.filter { $0.isCompletedToday }.count
                            Text("\(completed)/\(habitReminders.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "heart.circle.fill")
                            .foregroundStyle(.pink)
                    }
                    .tag(SidebarSection.habits)

                    Label("All Reminders", systemImage: "tray.full.fill")
                        .tag(SidebarSection.all)
                }

                Section("Categories") {
                    ForEach(categories.filter { $0.name != "Habits" }) { category in
                        Label {
                            HStack {
                                Text(category.name)
                                Spacer()
                                let count = remindersForCategory(category).count
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: category.icon)
                                .foregroundStyle(category.color)
                        }
                        .tag(SidebarSection.category(category))
                    }
                }

                Section("iCloud") {
                    HStack {
                        Image(systemName: "icloud.fill")
                            .foregroundStyle(FileManager.default.ubiquityIdentityToken != nil ? .green : .red)
                        Text(FileManager.default.ubiquityIdentityToken != nil ? "Connected" : "Not signed in")
                            .font(.caption)
                        Spacer()
                        Text("\(reminders.count) items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 250)
            .toolbar {
                ToolbarItem {
                    Button {
                        showingAddReminder = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        } detail: {
            // Detail view based on selection
            Group {
                switch selectedSection {
                case .needsAttention:
                    MacReminderListView(
                        title: "Needs Attention",
                        icon: "exclamationmark.circle.fill",
                        iconColor: .red,
                        reminders: needsAttentionReminders,
                        showSnooze: true
                    )
                case .habits:
                    MacHabitsView(habits: habitReminders)
                case .all:
                    MacReminderListView(
                        title: "All Reminders",
                        icon: "tray.full.fill",
                        iconColor: .secondary,
                        reminders: allReminders,
                        showSnooze: false
                    )
                case .category(let category):
                    MacReminderListView(
                        title: category.name,
                        icon: category.icon,
                        iconColor: category.color,
                        reminders: remindersForCategory(category),
                        showSnooze: false
                    )
                case .none:
                    ContentUnavailableView("Select a section", systemImage: "sidebar.left")
                }
            }
            .searchable(text: $searchText, prompt: "Search reminders")
        }
        .sheet(isPresented: $showingAddReminder) {
            MacAddReminderView()
        }
    }
}

// MARK: - Mac Reminder List View

struct MacReminderListView: View {
    let title: String
    let icon: String
    let iconColor: Color
    let reminders: [Reminder]
    let showSnooze: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                    .font(.title2)
                Text(title)
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(reminders.count) items")
                    .foregroundStyle(.secondary)
            }
            .padding()

            Divider()

            if reminders.isEmpty {
                ContentUnavailableView("No Reminders", systemImage: icon)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(reminders) { reminder in
                        MacReminderRow(reminder: reminder, showSnooze: showSnooze)
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

// MARK: - Mac Reminder Row

struct MacReminderRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var reminder: Reminder
    let showSnooze: Bool

    var body: some View {
        HStack(spacing: 12) {
            // Checkbox
            Button {
                withAnimation {
                    if reminder.isCompleted {
                        reminder.markIncomplete()
                    } else {
                        reminder.markCompleted()
                    }
                }
            } label: {
                Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(reminder.isCompleted ? .green : .secondary)
            }
            .buttonStyle(.plain)

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(reminder.title)
                    .strikethrough(reminder.isCompleted)
                    .foregroundStyle(reminder.isCompleted ? .secondary : .primary)

                HStack(spacing: 8) {
                    if let category = reminder.category {
                        Label(category.name, systemImage: category.icon)
                            .font(.caption)
                            .foregroundStyle(category.color)
                    }

                    if let icon = reminder.priority.icon {
                        Image(systemName: icon)
                            .font(.caption)
                            .foregroundStyle(reminder.priority.color)
                    }

                    if reminder.isDueToday {
                        Text("Today")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else if reminder.isOverdue {
                        Text("Overdue")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            Spacer()

            // Snooze button
            if showSnooze {
                Button("Snooze") {
                    let calendar = Calendar.current
                    let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
                    reminder.dueDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // Delete
            Button {
                withAnimation {
                    modelContext.delete(reminder)
                }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Mac Habits View

struct MacHabitsView: View {
    let habits: [Reminder]

    private var completedCount: Int {
        habits.filter { $0.isCompletedToday }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "heart.circle.fill")
                    .foregroundStyle(.pink)
                    .font(.title2)
                Text("Daily Habits")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(completedCount)/\(habits.count) completed")
                    .foregroundStyle(.secondary)
            }
            .padding()

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.pink.opacity(0.2))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.pink)
                        .frame(width: geo.size.width * CGFloat(completedCount) / CGFloat(max(habits.count, 1)))
                        .animation(.spring, value: completedCount)
                }
            }
            .frame(height: 8)
            .padding(.horizontal)

            Divider()
                .padding(.top)

            if habits.isEmpty {
                ContentUnavailableView("No Habits", systemImage: "heart.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(habits) { habit in
                        MacHabitRow(habit: habit)
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

// MARK: - Mac Habit Row

struct MacHabitRow: View {
    @Bindable var habit: Reminder

    var isCompletedToday: Bool {
        habit.isCompletedToday
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation {
                    if isCompletedToday {
                        habit.clearHabitCompletion()
                    } else {
                        habit.markHabitDoneToday()
                    }
                }
            } label: {
                Image(systemName: isCompletedToday ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isCompletedToday ? .green : .secondary)
            }
            .buttonStyle(.plain)

            Text(habit.title)
                .strikethrough(isCompletedToday)
                .foregroundStyle(isCompletedToday ? .secondary : .primary)

            Spacer()

            if !habit.notes.isEmpty {
                Text(habit.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Mac Add Reminder View

struct MacAddReminderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Category.sortOrder) private var categories: [Category]

    @State private var title = ""
    @State private var notes = ""
    @State private var selectedCategory: Category?
    @State private var priority: ReminderPriority = .none
    @State private var hasDueDate = false
    @State private var dueDate = Date()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Spacer()
                Text("New Reminder")
                    .fontWeight(.semibold)
                Spacer()
                Button("Add") { addReminder() }
                    .keyboardShortcut(.return)
                    .disabled(title.isEmpty)
            }
            .padding()

            Divider()

            Form {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)

                TextField("Notes", text: $notes, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...6)

                Picker("Category", selection: $selectedCategory) {
                    Text("None").tag(nil as Category?)
                    ForEach(categories.filter { $0.name != "Habits" }) { category in
                        Label(category.name, systemImage: category.icon)
                            .tag(category as Category?)
                    }
                }

                Picker("Priority", selection: $priority) {
                    ForEach(ReminderPriority.allCases, id: \.self) { p in
                        Text(p.label).tag(p)
                    }
                }

                Toggle("Due Date", isOn: $hasDueDate)

                if hasDueDate {
                    DatePicker("Date", selection: $dueDate)
                }
            }
            .padding()
        }
        .frame(width: 400, height: 400)
    }

    private func addReminder() {
        let reminder = Reminder(
            title: title,
            notes: notes,
            dueDate: hasDueDate ? dueDate : nil,
            priority: priority,
            category: selectedCategory
        )
        modelContext.insert(reminder)
        dismiss()
    }
}

#Preview {
    MacContentView()
        .modelContainer(for: [Reminder.self, Category.self], inMemory: true)
}
#endif
