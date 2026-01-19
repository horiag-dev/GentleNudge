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
                            reminder.markIncomplete()
                        } else {
                            completeReminder()
                        }
                    }
                } label: {
                    Image(systemName: reminder.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.body)
                        .foregroundStyle(reminder.isCompleted ? .green : .secondary)
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

                    // Priority, Date & Recurrence
                    HStack(spacing: 6) {
                        if let icon = reminder.priority.icon {
                            Image(systemName: icon)
                                .font(.caption2)
                                .foregroundStyle(reminder.priority.color)
                        }

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
