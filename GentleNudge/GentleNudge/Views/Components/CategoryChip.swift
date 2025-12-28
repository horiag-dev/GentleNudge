import SwiftUI

struct CategoryChip: View {
    let category: Category
    var size: ChipSize = .medium
    var showIcon: Bool = true

    enum ChipSize {
        case small
        case medium
        case large

        var font: Font {
            switch self {
            case .small: return .caption2
            case .medium: return .caption
            case .large: return .subheadline
            }
        }

        var iconFont: Font {
            switch self {
            case .small: return .caption2
            case .medium: return .caption
            case .large: return .subheadline
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .small: return 6
            case .medium: return 8
            case .large: return 12
            }
        }

        var verticalPadding: CGFloat {
            switch self {
            case .small: return 2
            case .medium: return 4
            case .large: return 6
            }
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if showIcon {
                Image(systemName: category.icon)
                    .font(size.iconFont)
            }
            Text(category.name)
                .font(size.font)
                .fontWeight(.medium)
        }
        .foregroundStyle(category.color)
        .padding(.horizontal, size.horizontalPadding)
        .padding(.vertical, size.verticalPadding)
        .background(category.color.opacity(0.15))
        .clipShape(Capsule())
    }
}

struct CategoryChipSelectable: View {
    let category: Category
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: category.icon)
                Text(category.name)
            }
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(isSelected ? .white : category.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? category.color : category.color.opacity(0.15))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack {
            CategoryChip(category: Category(name: "Work", icon: "briefcase.fill", colorName: "green"), size: .small)
            CategoryChip(category: Category(name: "Personal", icon: "person.fill", colorName: "pink"), size: .medium)
            CategoryChip(category: Category(name: "Urgent", icon: "exclamationmark.circle.fill", colorName: "red"), size: .large)
        }

        HStack {
            CategoryChipSelectable(
                category: Category(name: "Work", icon: "briefcase.fill", colorName: "green"),
                isSelected: false,
                action: {}
            )
            CategoryChipSelectable(
                category: Category(name: "Personal", icon: "person.fill", colorName: "pink"),
                isSelected: true,
                action: {}
            )
        }
    }
    .padding()
}
