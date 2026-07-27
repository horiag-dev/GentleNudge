import SwiftUI
#if os(iOS)
import UIKit
#endif

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

    /// Stable per-row identity for the one-open-row rule.
    @State private var rowID = UUID()
    /// Settled offset: 0 (closed) or `-revealWidth` (open).
    @State private var settledOffset: CGFloat = 0
    /// Live, already-clamped drag delta on top of `settledOffset`.
    @State private var dragDelta: CGFloat = 0

    /// Width of one fully-revealed button.
    private let actionWidth: CGFloat = 72
    /// Snappy settle with no bounce past the target.
    private let snapAnimation = Animation.spring(response: 0.28, dampingFraction: 0.9)
    /// How far a release's momentum is projected when deciding open vs. closed,
    /// so a quick flick opens the row without dragging the whole way.
    private let flickProjection: CGFloat = 0.2

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
            .gesture(
                RowRevealPan(
                    onChange: { translationX in drag(to: translationX) },
                    onEnd: { translationX, velocityX in
                        endDrag(translationX: translationX, velocityX: velocityX)
                    }
                )
            )
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

    /// Live drag update. Only ever called for a drag the recognizer has already
    /// judged horizontal, with `translationX` measured from that moment.
    private func drag(to translationX: CGFloat) {
        // Starting a swipe closes any other open row.
        if SwipeRowCoordinator.shared.openRowID != rowID {
            SwipeRowCoordinator.shared.openRowID = rowID
        }
        dragDelta = clampedTotal(settledOffset + translationX) - settledOffset
    }

    private func endDrag(translationX: CGFloat, velocityX: CGFloat) {
        // Flick-friendly: project the momentum, then snap open past half the
        // reveal width, closed otherwise.
        let released = clampedTotal(settledOffset + translationX)
        let shouldOpen = released + velocityX * flickProjection < -revealWidth / 2
        withAnimation(snapAnimation) {
            settledOffset = shouldOpen ? -revealWidth : 0
            dragDelta = 0
        }
        if !shouldOpen {
            releaseCoordinator()
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

// MARK: - Direction-locked pan

/// The row's swipe gesture, as a real UIKit pan recognizer.
///
/// A SwiftUI `DragGesture` here competes with the enclosing `ScrollView`'s pan:
/// whichever recognizes first cancels the other, so a vertical scroll started on
/// a card would sometimes be swallowed by the row and the list wouldn't move —
/// intermittently, depending on where and how the finger landed. A UIKit
/// recognizer can express what SwiftUI's cannot: it refuses to begin at all
/// unless the movement is clearly horizontal, and it never prevents (nor is
/// prevented by) the scroll view's pan.
private struct RowRevealPan: UIGestureRecognizerRepresentable {
    /// Live horizontal translation, measured from the point the drag was judged
    /// horizontal (so the card doesn't jump by the decision distance).
    let onChange: (CGFloat) -> Void
    /// Final translation plus horizontal velocity, for the open/close snap.
    let onEnd: (CGFloat, CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> RowRevealPanRecognizer {
        let recognizer = RowRevealPanRecognizer()
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: RowRevealPanRecognizer, context: Context) {
        // Until the drag is judged horizontal it belongs to the scroll view;
        // the card must not move, and there is nothing to settle at the end.
        guard recognizer.isHorizontalDrag else { return }
        let translation = recognizer.translation(in: recognizer.view)
        switch recognizer.state {
        case .began, .changed:
            onChange(translation.x)
        case .ended, .cancelled, .failed:
            onEnd(translation.x, recognizer.velocity(in: recognizer.view).x)
        default:
            break
        }
    }
}

/// Pan recognizer that claims only horizontally-dominant drags and leaves
/// everything else to the enclosing scroll view.
final class RowRevealPanRecognizer: UIPanGestureRecognizer {
    /// Distance travelled before the drag's direction is judged — below this a
    /// touch is too ambiguous to tell a swipe from the start of a scroll.
    private let decisionDistance: CGFloat = 12
    /// How much more horizontal than vertical the movement must be to count as
    /// a swipe. Above 1 so the diagonal arc of a thumb scroll stays a scroll.
    private let dominanceRatio: CGFloat = 1.3

    /// True once this drag has been judged horizontal; the card only moves then.
    private(set) var isHorizontalDrag = false

    private var hasJudgedDirection = false
    /// Scroll view frozen for the duration of a claimed swipe, restored in
    /// `reset()` — which UIKit always calls, however the gesture ends.
    private weak var lockedScrollView: UIScrollView?

    // Stay out of UIKit's winner-takes-all arbitration in both directions: the
    // scroll view's pan can't kill this recognizer, and this recognizer can't
    // kill the scroll (which it hands the drag back to when it turns out
    // vertical). Direction is decided below, on the movement itself.
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard !hasJudgedDirection, state == .began || state == .changed else { return }

        let travel = translation(in: view)
        guard max(abs(travel.x), abs(travel.y)) >= decisionDistance else { return }
        hasJudgedDirection = true

        guard abs(travel.x) >= abs(travel.y) * dominanceRatio else {
            // Vertical or ambiguous: this is a scroll. Bow out for the rest of
            // the drag — one decision per drag, so a scroll can never morph
            // into a row swipe halfway through.
            state = .cancelled
            return
        }

        isHorizontalDrag = true
        // Measure the card's travel from here, so it doesn't jump forward by
        // the distance it took to judge the direction.
        setTranslation(.zero, in: view)
        lockEnclosingScrollView()
    }

    override func reset() {
        super.reset()
        hasJudgedDirection = false
        isHorizontalDrag = false
        lockedScrollView?.isScrollEnabled = true
        lockedScrollView = nil
    }

    /// Freezes the nearest enclosing scroll view while the card is being
    /// swiped, so vertical drift during a horizontal swipe doesn't also scroll
    /// the list (the pair recognize simultaneously by design).
    private func lockEnclosingScrollView() {
        var candidate: UIView? = view
        while let current = candidate {
            if let scrollView = current as? UIScrollView, scrollView.isScrollEnabled {
                scrollView.isScrollEnabled = false
                lockedScrollView = scrollView
                return
            }
            candidate = current.superview
        }
    }
}

#endif
