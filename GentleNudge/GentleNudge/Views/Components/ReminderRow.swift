import SwiftUI
import SwiftData

struct ReminderRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var reminder: Reminder

    @State private var isPressed = false

    private var isMuted: Bool {
        reminder.isDistantRecurring
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
                }
                .buttonStyle(.plain)
                .padding(.top, 2)

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

                // In-progress toggle for active, non-habit reminders: "Start"
                // flags the reminder as begun; tapping the indigo "In Progress"
                // badge clears it.
                if !reminder.isCompleted && !reminder.isHabit {
                    Button {
                        withAnimation(Constants.Animation.spring) {
                            HapticManager.impact(.light)
                            reminder.setInProgress(!reminder.isInProgress)
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: reminder.isInProgress ? "circle.lefthalf.filled" : "play.circle")
                                .font(.caption2)
                            Text(reminder.isInProgress ? "In Progress" : "Start")
                        }
                        .font(.caption2.weight(.semibold))
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
        .contextMenu {
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
