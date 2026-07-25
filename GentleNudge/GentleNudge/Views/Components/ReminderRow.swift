import SwiftUI
import SwiftData

struct ReminderRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var reminder: Reminder

    @State private var isPressed = false
    /// Accessibility-only "Open" path: the visual open is the NavigationLink
    /// push, which a custom accessibility action can't trigger, so VoiceOver
    /// gets the detail as a sheet instead (same pattern as the Today rows).
    @State private var showingDetailSheet = false

    private var isMuted: Bool {
        reminder.isDistantRecurring
    }

    /// One-element VoiceOver summary for the combined row: title, then
    /// due/overdue/in-progress/completed status.
    private var accessibilityRowLabel: String {
        var parts = [reminder.title]
        if reminder.isCompleted {
            parts.append("Completed")
        } else {
            if reminder.isDueToday {
                parts.append("Due today")
            } else if reminder.isOverdue {
                parts.append("Overdue")
            } else if let dueDate = reminder.dueDate {
                parts.append("Due \(dueDate.formatted(date: .abbreviated, time: .omitted))")
            }
            if reminder.isInProgress {
                parts.append("In progress")
            }
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        NavigationLink {
            ReminderDetailView(reminder: reminder)
        } label: {
            HStack(alignment: .top, spacing: Constants.Spacing.xs) {
                // Completion Button
                Button {
                    withAnimation(Constants.Animation.spring) {
                        HapticManager.notification(reminder.isCompleted ? .warning : .success)
                        if reminder.isCompleted {
                            reminder.uncomplete(in: modelContext)
                        } else {
                            completeReminder()
                        }
                    }
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
                        .font(.subheadline)
                        .foregroundStyle(reminder.isCompleted || isMuted ? .secondary : .primary)
                        .strikethrough(reminder.isCompleted)
                        .fixedSize(horizontal: false, vertical: true)

                    // Date & Recurrence
                    HStack(spacing: 6) {
                        if reminder.isDueToday {
                            Text("Today")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        } else if reminder.isOverdue {
                            Text("Overdue")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        } else if let dueDate = reminder.dueDate {
                            Text(dueDate.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        // Recurrence badge
                        if reminder.isRecurring {
                            RecurrenceBadge(
                                recurrence: reminder.recurrence,
                                detailedText: isMuted ? reminder.daysUntilDueText : nil
                            )
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
                    .padding(.top, 4)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, Constants.Spacing.xs)
            .opacity(isMuted ? 0.6 : 1.0)
        }
        .buttonStyle(.plain)
        // This row's long-press affordance is its (pre-existing) context menu,
        // so the in-progress toggle lives there — a raw `.onLongPressGesture`
        // would race the menu's own long-press recognizer on iOS.
        .contextMenu {
            if !reminder.isCompleted && !reminder.isHabit {
                Button {
                    withAnimation(Constants.Animation.spring) {
                        HapticManager.impact(.light)
                        reminder.setInProgress(!reminder.isInProgress)
                    }
                } label: {
                    Label(
                        reminder.isInProgress ? "Mark Not Started" : "Mark In Progress",
                        systemImage: reminder.isInProgress ? "circle" : "circle.lefthalf.filled"
                    )
                }
            }

            Button {
                withAnimation {
                    if reminder.isCompleted {
                        reminder.uncomplete(in: modelContext)
                    } else {
                        completeReminder()
                    }
                }
            } label: {
                Label(
                    reminder.isCompleted ? "Mark Incomplete" : "Mark Complete",
                    systemImage: reminder.isCompleted ? "circle" : "checkmark.circle"
                )
            }

            Divider()

            Button(role: .destructive) {
                withAnimation {
                    modelContext.delete(reminder)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                withAnimation {
                    modelContext.delete(reminder)
                }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                withAnimation {
                    HapticManager.notification(.success)
                    if reminder.isCompleted {
                        reminder.uncomplete(in: modelContext)
                    } else {
                        completeReminder()
                    }
                }
            } label: {
                Label(
                    reminder.isCompleted ? "Undo" : "Done",
                    systemImage: reminder.isCompleted ? "arrow.uturn.backward" : "checkmark"
                )
            }
            .tint(.green)
        }
        // VoiceOver: one element per row (title + status), with every inner
        // control re-exposed as a named action — combining otherwise leaves
        // the toggle, context menu, and long-press unreachable.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityRowLabel)
        // Deterministic default activation (double-tap): open the detail.
        .accessibilityAction {
            showingDetailSheet = true
        }
        .accessibilityActions {
            Button(reminder.isCompleted ? "Mark not done" : "Complete") {
                withAnimation(Constants.Animation.spring) {
                    HapticManager.notification(reminder.isCompleted ? .warning : .success)
                    if reminder.isCompleted {
                        reminder.uncomplete(in: modelContext)
                    } else {
                        completeReminder()
                    }
                }
            }
            // Same guard as the context menu's in-progress toggle.
            if !reminder.isCompleted && !reminder.isHabit {
                Button(reminder.isInProgress ? "Mark not started" : "Mark In Progress") {
                    withAnimation(Constants.Animation.spring) {
                        HapticManager.impact(.light)
                        reminder.setInProgress(!reminder.isInProgress)
                    }
                }
            }
            Button("Open") {
                showingDetailSheet = true
            }
            Button("Delete", role: .destructive) {
                withAnimation {
                    modelContext.delete(reminder)
                }
            }
        }
        .sheet(isPresented: $showingDetailSheet) {
            NavigationStack {
                ReminderDetailView(reminder: reminder)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func completeReminder() {
        reminder.complete(in: modelContext)
    }
}

#Preview {
    let config = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try! ModelContainer(for: Reminder.self, Category.self, configurations: config)

    let category = Category(name: "Work", icon: "briefcase.fill", colorName: "green")
    container.mainContext.insert(category)

    let reminder = Reminder(title: "Review project proposal", notes: "Check the budget section", dueDate: Date(), category: category)
    container.mainContext.insert(reminder)

    return NavigationStack {
        ReminderRow(reminder: reminder)
            .padding()
    }
    .modelContainer(container)
}
