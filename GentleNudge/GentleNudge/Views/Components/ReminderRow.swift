import SwiftUI
import SwiftData

struct ReminderRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var reminder: Reminder

    @State private var isPressed = false

    var body: some View {
        NavigationLink {
            ReminderDetailView(reminder: reminder)
        } label: {
            HStack(spacing: Constants.Spacing.sm) {
                // Completion Button
                Button {
                    withAnimation(Constants.Animation.spring) {
                        HapticManager.notification(reminder.isCompleted ? .warning : .success)
                        if reminder.isCompleted {
                            reminder.markIncomplete()
                        } else {
                            completeReminder()
                        }
                    }
                } label: {
                    Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(reminder.isCompleted ? .green : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: Constants.Spacing.xxs) {
                    // Title
                    Text(reminder.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundStyle(reminder.isCompleted ? .secondary : .primary)
                        .strikethrough(reminder.isCompleted)
                        .lineLimit(2)

                    HStack(spacing: Constants.Spacing.xs) {
                        // Due Date
                        if let formattedDate = reminder.formattedDueDate {
                            Label(formattedDate, systemImage: "calendar")
                                .font(.caption)
                                .foregroundStyle(reminder.isOverdue ? .red : .secondary)
                        }

                        // Priority
                        if let icon = reminder.priority.icon {
                            Image(systemName: icon)
                                .font(.caption)
                                .foregroundStyle(reminder.priority.color)
                        }

                        // Recurrence Badge
                        if reminder.isRecurring {
                            RecurrenceBadge(recurrence: reminder.recurrence)
                        }
                    }

                    // AI Enhanced Description
                    if let aiDescription = reminder.aiEnhancedDescription, !aiDescription.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "sparkles")
                                .font(.caption2)
                            Text(aiDescription)
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(Constants.Spacing.sm)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                withAnimation {
                    if reminder.isCompleted {
                        reminder.markIncomplete()
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
                        reminder.markIncomplete()
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
        // If recurring, create next occurrence before marking complete
        if reminder.isRecurring, let nextReminder = reminder.createNextOccurrence() {
            modelContext.insert(nextReminder)
        }
        reminder.markCompleted()
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
