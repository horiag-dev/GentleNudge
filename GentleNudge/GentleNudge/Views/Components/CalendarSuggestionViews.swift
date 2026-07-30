import SwiftUI
import SwiftData

// MARK: - Section

/// The "From your calendar" block: action items the assistant proposed from the
/// user's upcoming events, plus anything it added on its own today (with an Undo,
/// so an automatic add is always reversible in the place the user sees it).
///
/// Shared by the iOS `TodayView` and the macOS Today page — one card design, one
/// set of decisions, so the learning behaves identically on both.
struct CalendarSuggestionsSection: View {
    let pending: [CalendarSuggestion]
    let autoAddedToday: [CalendarSuggestion]

    private let tint: Color = .indigo

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
            TodaySectionHeader(
                icon: "calendar.badge.plus",
                tint: tint,
                title: "From your calendar",
                count: pending.isEmpty ? nil : "\(pending.count)"
            )

            VStack(spacing: Constants.Spacing.xs) {
                ForEach(pending) { suggestion in
                    CalendarSuggestionCard(suggestion: suggestion)
                }
                ForEach(autoAddedToday) { suggestion in
                    CalendarAutoAddedRow(suggestion: suggestion)
                }
            }
        }
        .todaySectionCard(tint: tint)
    }
}

// MARK: - Pending card

/// One proposal awaiting a yes/no. The rationale is always shown: the user should
/// never have to guess why their calendar produced a task.
struct CalendarSuggestionCard: View {
    @Environment(CalendarScanCoordinator.self) private var coordinator
    let suggestion: CalendarSuggestion

    private var dueText: String? {
        suggestion.suggestedDueDate.map {
            ReminderRepository.displayDate($0, calendar: .current, timeZone: .current)
        }
    }

    private var sourceText: String {
        let date = CalendarScanCoordinator.eventDateText(suggestion.eventStart, calendar: .current)
        return "\(suggestion.eventTitle) · \(date)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
            HStack(alignment: .top, spacing: Constants.Spacing.xs) {
                Image(systemName: suggestion.kind.icon)
                    .font(.subheadline)
                    .foregroundStyle(.indigo)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.suggestedTitle)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)

                    if !suggestion.rationale.isEmpty {
                        Text(suggestion.rationale)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: Constants.Spacing.xxs) {
                        Image(systemName: "calendar")
                            .font(.caption2)
                        Text(sourceText)
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                if let dueText {
                    Text(dueText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: Constants.Spacing.xs) {
                Button {
                    HapticManager.impact(.light)
                    withAnimation(Constants.Animation.quick) { coordinator.accept(suggestion) }
                } label: {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    withAnimation(Constants.Animation.quick) { coordinator.dismiss(suggestion) }
                } label: {
                    Text("Not now")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Menu {
                    Button {
                        coordinator.setRule(kind: suggestion.kind, autoApprove: true, suppressed: false)
                        coordinator.accept(suggestion)
                    } label: {
                        Label("Always add \(suggestion.kind.label.lowercased())", systemImage: "checkmark.circle")
                    }
                    Button(role: .destructive) {
                        coordinator.setRule(kind: suggestion.kind, autoApprove: false, suppressed: true)
                        coordinator.dismiss(suggestion)
                    } label: {
                        Label("Never suggest \(suggestion.kind.label.lowercased())", systemImage: "bell.slash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More options for this suggestion")
            }
        }
        .padding(Constants.Spacing.sm)
        .todayRowCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = ["Calendar suggestion", suggestion.suggestedTitle]
        if !suggestion.rationale.isEmpty { parts.append(suggestion.rationale) }
        parts.append("From \(sourceText)")
        if let dueText { parts.append("Due \(dueText)") }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Auto-added row

/// Something the app added without asking, shown for the rest of the day so the
/// add is visible and undoable at the moment it matters.
struct CalendarAutoAddedRow: View {
    @Environment(CalendarScanCoordinator.self) private var coordinator
    let suggestion: CalendarSuggestion

    var body: some View {
        HStack(alignment: .top, spacing: Constants.Spacing.xs) {
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(AppColors.success)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.suggestedTitle)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Added automatically from \(suggestion.eventTitle)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button {
                withAnimation(Constants.Animation.quick) { coordinator.undoAutoAdd(suggestion) }
            } label: {
                Text("Undo")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(Constants.Spacing.sm)
        .todayRowCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Added automatically: \(suggestion.suggestedTitle), from \(suggestion.eventTitle)")
    }
}

// MARK: - Query helpers

extension CalendarSuggestion {
    /// The pending queue, soonest event first — what the review section shows.
    static func pending(from all: [CalendarSuggestion]) -> [CalendarSuggestion] {
        all.filter { $0.state == .pending }
            .sorted { $0.eventStart < $1.eventStart }
    }

    /// Automatic adds from today, so they can be surfaced (and undone) once.
    static func autoAddedToday(
        from all: [CalendarSuggestion],
        calendar: Calendar = .current,
        referenceDate: Date = Date()
    ) -> [CalendarSuggestion] {
        all.filter { suggestion in
            guard suggestion.state == .accepted, suggestion.wasAutoApproved else { return false }
            guard let decidedAt = suggestion.decidedAt else { return false }
            return calendar.isDate(decidedAt, inSameDayAs: referenceDate)
        }
        .sorted { $0.eventStart < $1.eventStart }
    }
}
