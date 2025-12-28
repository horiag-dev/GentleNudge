import SwiftUI

struct RecurrencePicker: View {
    @Binding var recurrence: RecurrenceType

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.Spacing.sm) {
            Text("Repeat")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Constants.Spacing.xs) {
                    ForEach(RecurrenceType.allCases, id: \.self) { type in
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

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "repeat")
                .font(.caption2)
            Text(recurrence.label)
                .font(.caption2)
        }
        .foregroundStyle(.purple)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
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
