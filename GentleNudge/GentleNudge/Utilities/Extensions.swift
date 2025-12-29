import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - View Extensions

extension View {
    func cardStyle() -> some View {
        self
            .background(AppColors.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md))
    }

    func shimmer(isActive: Bool) -> some View {
        self.modifier(ShimmerModifier(isActive: isActive))
    }
}

struct ShimmerModifier: ViewModifier {
    let isActive: Bool
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                if isActive {
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [
                                .clear,
                                .white.opacity(0.4),
                                .clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geometry.size.width * 2)
                        .offset(x: phase * geometry.size.width * 2 - geometry.size.width)
                    }
                    .mask(content)
                }
            }
            .onAppear {
                guard isActive else { return }
                withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// MARK: - Date Extensions

extension Date {
    var startOfDay: Date {
        Calendar.current.startOfDay(for: self)
    }

    var endOfDay: Date {
        var components = DateComponents()
        components.day = 1
        components.second = -1
        return Calendar.current.date(byAdding: components, to: startOfDay)!
    }

    func isSameDay(as other: Date) -> Bool {
        Calendar.current.isDate(self, inSameDayAs: other)
    }

    static var tomorrow: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Date())!
    }

    static var nextWeek: Date {
        Calendar.current.date(byAdding: .weekOfYear, value: 1, to: Date())!
    }
}

// MARK: - String Extensions

extension String {
    var containsURL: Bool {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: self, options: [], range: NSRange(location: 0, length: self.utf16.count))
        return (matches?.count ?? 0) > 0
    }

    var extractedURLs: [URL] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: self, options: [], range: NSRange(location: 0, length: self.utf16.count)) ?? []
        return matches.compactMap { match in
            guard let range = Range(match.range, in: self) else { return nil }
            return URL(string: String(self[range]))
        }
    }
}

// MARK: - Flow Layout (Wrapping)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            frames.append(CGRect(x: currentX, y: currentY, width: size.width, height: size.height))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
            totalHeight = currentY + lineHeight
        }

        return (CGSize(width: totalWidth, height: totalHeight), frames)
    }
}

// MARK: - Linked Text (Clickable URLs)

struct LinkedText: View {
    let text: String
    let font: Font
    let foregroundStyle: Color

    init(_ text: String, font: Font = .body, foregroundStyle: Color = .primary) {
        self.text = text
        self.font = font
        self.foregroundStyle = foregroundStyle
    }

    var body: some View {
        Text(attributedString)
            .font(font)
            .tint(.blue)
    }

    private var attributedString: AttributedString {
        var attributedString = AttributedString(text)
        #if os(iOS)
        attributedString.foregroundColor = UIColor(foregroundStyle)
        #else
        attributedString.foregroundColor = NSColor(foregroundStyle)
        #endif

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)) ?? []

        for match in matches {
            guard let range = Range(match.range, in: text),
                  let url = match.url,
                  let attributedRange = Range(range, in: attributedString) else { continue }

            attributedString[attributedRange].link = url
            attributedString[attributedRange].foregroundColor = .blue
            attributedString[attributedRange].underlineStyle = .single
        }

        return attributedString
    }
}

// MARK: - Haptics

#if os(iOS)
import UIKit

enum HapticManager {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }

    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type)
    }

    static func selection() {
        let generator = UISelectionFeedbackGenerator()
        generator.selectionChanged()
    }
}
#else
// macOS stub - no haptics
enum HapticManager {
    enum FeedbackStyle { case light, medium, heavy, rigid, soft }
    enum FeedbackType { case success, warning, error }

    static func impact(_ style: FeedbackStyle) {}
    static func notification(_ type: FeedbackType) {}
    static func selection() {}
}
#endif
