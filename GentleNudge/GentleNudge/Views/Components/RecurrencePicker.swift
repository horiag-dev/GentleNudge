import SwiftUI

struct RecurrencePicker: View {
    @Binding var recurrence: RecurrenceType

    // Group recurrence types for better organization
    private let frequentOptions: [RecurrenceType] = [.none, .daily, .weekly, .monthly]
    private let weekOptions: [RecurrenceType] = [.weekdays, .weekends, .biweekly]
    private let longTermOptions: [RecurrenceType] = [.quarterly, .semiannually, .yearly]

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.md) {
            Text("Repeat")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Common frequencies
            VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                Text("Common")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                FlowLayout(spacing: Constants.Spacing.xs) {
                    ForEach(frequentOptions, id: \.self) { type in
                        RecurrenceButton(
                            type: type,
                            isSelected: recurrence == type
                        ) {
                            HapticManager.selection()
                            recurrence = type
                        }
                    }
                }
            }

            // Week-based options
            VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                Text("Week-based")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                FlowLayout(spacing: Constants.Spacing.xs) {
                    ForEach(weekOptions, id: \.self) { type in
                        RecurrenceButton(
                            type: type,
                            isSelected: recurrence == type
                        ) {
                            HapticManager.selection()
                            recurrence = type
                        }
                    }
                }
            }

            // Long-term options
            VStack(alignment: .leading, spacing: Constants.Spacing.xs) {
                Text("Long-term")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                FlowLayout(spacing: Constants.Spacing.xs) {
                    ForEach(longTermOptions, id: \.self) { type in
                        RecurrenceButton(
                            type: type,
                            isSelected: recurrence == type
                        ) {
                            HapticManager.selection()
                            recurrence = type
                        }
                    }
                }
            }
        }
        .padding()
        .background(AppColors.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
    }
}

struct RecurrenceButton: View {
    let type: RecurrenceType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: type.icon)
                    .font(.caption)
                Text(type.label)
                    .font(.subheadline)
            }
            .fontWeight(.medium)
            .foregroundStyle(isSelected ? .white : .primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.purple : AppColors.secondaryBackground)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct RecurrenceBadge: View {
    let recurrence: RecurrenceType
    var detailedText: String? = nil
    var compact: Bool = true

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "repeat")
                .font(compact ? .caption2 : .caption)
            Text(detailedText ?? recurrence.label)
                .font(compact ? .caption2 : .caption)
                .fontWeight(compact ? .regular : .medium)
        }
        .foregroundStyle(.purple)
        .padding(.horizontal, compact ? 6 : 10)
        .padding(.vertical, compact ? 2 : 4)
        .background(.purple.opacity(0.15))
        .clipShape(Capsule())
    }
}

#Preview {
    VStack(spacing: 20) {
        RecurrencePicker(recurrence: .constant(.none))
        RecurrencePicker(recurrence: .constant(.weekly))

        HStack {
            RecurrenceBadge(recurrence: .daily)
            RecurrenceBadge(recurrence: .weekly)
            RecurrenceBadge(recurrence: .monthly)
        }
    }
    .padding()
}
