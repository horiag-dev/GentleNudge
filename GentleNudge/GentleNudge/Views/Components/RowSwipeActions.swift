import SwiftUI

// MARK: - Row Swipe Actions (custom swipe-to-reveal for card rows)

/// One action revealed behind a reminder card when the user swipes it left.
///
/// Cross-platform type so call sites compile everywhere, but the reveal gesture
/// itself is iOS-only — `reminderSwipeActions` is a no-op on macOS, where the
/// Mac rows keep their existing right-click menu and List-based delete.
struct RowSwipeAction: Identifiable {
    let title: String
    let systemImage: String
    let tint: Color
    let handler: () -> Void

    var id: String { title }
}

extension View {
    /// Reveal-then-tap swipe actions for the custom card rows, which live in
    /// `ScrollView` + `LazyVStack` — where the List-only `.swipeActions`
    /// modifier silently does nothing. Swiping the card LEFT slides it aside to
    /// reveal tappable buttons behind it; tapping a button performs its action
    /// and snaps the card closed. Deliberately reveal-then-tap: a full swipe
    /// never auto-triggers an action, so a destructive Delete can't fire by
    /// accident.
    ///
    /// Attach AFTER the row's own tap/long-press gestures so that (a) the whole
    /// card — its gestures and inner buttons included — slides as one unit, and
    /// (b) when the row is open, the modifier's tap-catcher overlay sits on top
    /// and a tap closes the row instead of opening the detail.
    @ViewBuilder
    func reminderSwipeActions(_ actions: [RowSwipeAction]) -> some View {
        #if os(iOS)
        modifier(RowSwipeActionsModifier(actions: actions))
        #else
        self
        #endif
    }
}

#if os(iOS)

/// App-wide "at most one row open" bookkeeping: opening (or starting to swipe)
/// any row closes whichever other row was open, matching List behavior.
@MainActor
@Observable
final class SwipeRowCoordinator {
    static let shared = SwipeRowCoordinator()

    /// The row currently open (or actively swiping); nil when none.
    var openRowID: UUID?
}

private struct RowSwipeActionsModifier: ViewModifier {
    let actions: [RowSwipeAction]

    /// Whether the active drag was claimed as a horizontal swipe or permanently
    /// handed to the enclosing scroll view. Decided ONCE per drag, at the first
    /// update past the activation distance, so a vertical scroll can never
    /// morph into a row swipe halfway through.
    private enum DragClaim { case undecided, horizontal, rejected }

    /// Stable per-row identity for the one-open-row rule.
    @State private var rowID = UUID()
    /// Settled offset: 0 (closed) or `-revealWidth` (open).
    @State private var settledOffset: CGFloat = 0
    /// Live, already-clamped drag delta on top of `settledOffset`.
    @State private var dragDelta: CGFloat = 0
    @State private var dragClaim: DragClaim = .undecided

    /// Width of one fully-revealed button.
    private let actionWidth: CGFloat = 72
    /// Snappy settle with no bounce past the target.
    private let snapAnimation = Animation.spring(response: 0.28, dampingFraction: 0.9)

    private var revealWidth: CGFloat { CGFloat(actions.count) * actionWidth }
    private var totalOffset: CGFloat { settledOffset + dragDelta }
    private var isOpen: Bool { settledOffset != 0 }

    func body(content: Content) -> some View {
        content
            // When open, one tap ANYWHERE on the card closes it — and, sitting
            // on top of the card, the catcher swallows that tap so the row's
            // own tap-to-open / NavigationLink / inner buttons don't also fire.
            // Attached before `.offset` so it slides with the card and never
            // covers the revealed buttons.
            .overlay {
                if isOpen {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                        .accessibilityHidden(true)
                }
            }
            .offset(x: totalOffset)
            // Clip the slid card at the row's own bounds so it never draws over
            // the section chrome to its left while revealing the buttons.
            .clipped()
            .background(alignment: .trailing) {
                // Always in the tree so the reveal/close width animates in sync
                // with the card; hit-testable only while actually revealed
                // (zero-width buttons must never swallow edge taps when closed).
                revealedButtons
                    .allowsHitTesting(totalOffset < 0)
            }
            .gesture(dragGesture)
            // One-open-row rule: any other row claiming the coordinator closes
            // this one. (Reading `openRowID` here also registers the
            // @Observable dependency that makes this onChange fire.)
            .onChange(of: SwipeRowCoordinator.shared.openRowID) { _, newValue in
                if newValue != rowID && (isOpen || dragDelta != 0) {
                    close()
                }
            }
            // A row scrolled offscreen (LazyVStack) must not come back
            // half-open, and an interrupted drag must not wedge the card.
            .onDisappear {
                settledOffset = 0
                dragDelta = 0
                dragClaim = .undecided
                releaseCoordinator()
            }
    }

    // MARK: Revealed buttons

    private var revealedButtons: some View {
        HStack(spacing: 0) {
            ForEach(actions) { action in
                Button {
                    action.handler()
                    close()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: action.systemImage)
                            .font(.body.weight(.semibold))
                        Text(action.title)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(action.tint)
            }
        }
        // The container is exactly the revealed gap, so the buttons stretch
        // with the drag (List-style) and share the width equally.
        .frame(width: max(0, -totalOffset))
        // ≥44pt-tall tap targets even on compact single-line rows.
        .frame(minHeight: 44)
        .clipShape(RoundedRectangle(cornerRadius: Constants.CornerRadius.md, style: .continuous))
        // The rows combine into one VoiceOver element and already re-expose
        // Complete/Delete as accessibilityActions; keep the visual buttons out.
        .accessibilityHidden(true)
    }

    // MARK: Drag

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                switch dragClaim {
                case .undecided:
                    // Claim only horizontally-dominant movement; anything else
                    // belongs to the vertical ScrollView — permanently, for
                    // this drag.
                    guard abs(value.translation.width) > abs(value.translation.height) else {
                        dragClaim = .rejected
                        return
                    }
                    dragClaim = .horizontal
                    // Starting a swipe closes any other open row.
                    SwipeRowCoordinator.shared.openRowID = rowID
                case .rejected:
                    return
                case .horizontal:
                    break
                }
                dragDelta = clampedTotal(settledOffset + value.translation.width) - settledOffset
            }
            .onEnded { value in
                let claim = dragClaim
                dragClaim = .undecided
                guard claim == .horizontal else { return }
                // Flick-friendly: project the momentum, then snap open past
                // half the reveal width, closed otherwise.
                let projected = settledOffset + value.predictedEndTranslation.width
                let shouldOpen = projected < -revealWidth / 2
                withAnimation(snapAnimation) {
                    settledOffset = shouldOpen ? -revealWidth : 0
                    dragDelta = 0
                }
                if !shouldOpen {
                    releaseCoordinator()
                }
            }
    }

    /// Piecewise clamp for the card's total offset: never right of closed, and
    /// rubber-banding (1/3 resistance) past the fully-revealed position.
    private func clampedTotal(_ proposed: CGFloat) -> CGFloat {
        if proposed >= 0 { return 0 }
        if proposed < -revealWidth {
            let excess = -proposed - revealWidth
            return -(revealWidth + excess / 3)
        }
        return proposed
    }

    private func close() {
        withAnimation(snapAnimation) {
            settledOffset = 0
            dragDelta = 0
        }
        releaseCoordinator()
    }

    private func releaseCoordinator() {
        if SwipeRowCoordinator.shared.openRowID == rowID {
            SwipeRowCoordinator.shared.openRowID = nil
        }
    }
}

#endif
