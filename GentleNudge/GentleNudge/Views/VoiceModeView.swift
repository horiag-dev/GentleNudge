import SwiftUI
import SwiftData

/// A dedicated, hands-free "use it in the car" voice conversation over the SAME
/// shared `ChatCoordinator` the typed chat uses — so reminders are still created /
/// edited and the conversation keeps its context. It is presented full-screen on
/// iOS (`.fullScreenCover`) and as a large sheet on macOS.
///
/// The experience is audio-first and glanceable: a big animated orb + large status
/// text ("Listening…" / "Thinking…" / "Speaking…"), with the live partial
/// transcript and the latest spoken reply shown large but never required for use.
///
/// ## The continuous loop
/// 1. Appear → start listening; show the live partial.
/// 2. End-of-speech (the recognizer's trailing-silence auto-stop, or a tap on the
///    orb) → the final transcript is sent through `coordinator.run(userText:)`.
///    Empty transcripts are ignored (we just keep listening).
/// 3. While the coordinator runs → "Thinking…".
/// 4. When the reply is ready → speak it via the shared `SpeechSynthesizer`
///    (OpenAI neural voice, Apple fallback) and show "Speaking…". The mic is OFF
///    the entire time TTS plays, so the speaker never feeds back into the mic.
/// 5. When speech finishes → automatically start listening again. Loop until the
///    user ends the session.
///
/// ## Audio session (iOS)
/// The whole loop runs on ONE `.playAndRecord` configuration owned by
/// `VoiceAudioSession`: the first listen activates it, listen ↔ speak handoffs
/// never touch it (reconfiguring between phases used to break the next turn's
/// capture), and `end()` releases it exactly once on dismiss.
///
/// ## Who owns TTS / re-listen (no double-speak)
/// While presented, this view TAKES OVER `coordinator.onAssistantReply` (saving
/// whatever handler was wired) so the reply is spoken exactly once, here, and
/// its completion drives the next listen. On dismiss it restores the previous
/// handler and fully tears the mic down. The `SpeechSynthesizer` is the SAME
/// app-level instance `ContentView` owns, so the global mute + OpenAI-vs-Apple
/// routing are shared and only one engine ever talks.
struct VoiceModeView: View {
    @Environment(ChatCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    /// The app-level engine (owned by `ContentView`, which hosts the Voice entry
    /// in the bottom bar) so mute state and the neural/Apple routing are one and
    /// the same, and only a single TTS engine is ever active.
    let synthesizer: SpeechSynthesizer
    /// Settings deep link (used by the no-key state). Dismisses first, then routes.
    var onOpenSettings: (() -> Void)?

    // This view owns its OWN recognizer for the session, fully torn down on
    // dismiss. `ChatView` no longer keeps a `SpeechService`, so there is never a
    // second capture engine competing for the mic.
    @State private var speech = SpeechService()

    /// Where we are in the loop. Drives the orb, the color, and the status text.
    @State private var phase: Phase = .idle
    /// The most recent spoken assistant reply, shown large for glanceability.
    @State private var latestReply = ""
    /// Guards the loop: false once the user ends the session (or we hit a terminal
    /// blocked state), so no late callback re-opens the mic.
    @State private var sessionActive = false
    /// True once we've wired the callbacks + saved the prior reply handler, so
    /// `onAppear` firing again can't double-wire or clobber the saved handler.
    @State private var started = false
    /// Whatever reply handler was installed before we took over, restored on dismiss.
    @State private var savedReplyHandler: (@MainActor (String) -> Void)?
    /// True once we've swapped in our own reply handler, so `end()` restores the
    /// saved one only when we actually took over (never clobbers on the no-key path).
    @State private var tookOverReply = false
    /// Drives the orb's breathing animation.
    @State private var breathing = false

    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case speaking
        /// A transient per-turn error; shown briefly, then we resume listening.
        case error(String)
        /// A terminal-for-this-session block (no key / permission denied /
        /// recognizer unavailable). We stop looping and show a Settings hint.
        case blocked(String)
    }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            VStack(spacing: Constants.Spacing.lg) {
                topBar
                Spacer(minLength: 0)
                orb
                statusText
                captionArea
                Spacer(minLength: 0)
                controls
            }
            .padding(Constants.Spacing.lg)
            .frame(maxWidth: 640)
        }
        .onAppear(perform: begin)
        .onDisappear(perform: end)
        // Bridge the observable signals we can't get a direct callback for.
        .onChange(of: coordinator.isRunning) { _, running in turnRunningChanged(running) }
        .onChange(of: synthesizer.isSpeaking) { _, speaking in speakingChanged(speaking) }
        .onChange(of: speech.isListening) { _, listening in listeningChanged(listening) }
        .onChange(of: speech.authorizationDenied) { _, denied in if denied { blockPermission() } }
        .onChange(of: speech.isAvailable) { _, available in if !available { blockUnavailable() } }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 620)
        #endif
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            // Voice mode is audio-first; still expose the same mute the header has
            // so the driver can silence replies without leaving the mode.
            Button {
                synthesizer.voiceRepliesEnabled.toggle()
            } label: {
                Image(systemName: synthesizer.voiceRepliesEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(synthesizer.voiceRepliesEnabled ? "Replies are spoken (tap to mute)" : "Replies muted (tap to unmute)")

            Spacer()

            Button {
                endAndDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(AppColors.secondaryBackground, in: Circle())
            }
            .buttonStyle(.plain)
            .help("End voice mode")
        }
    }

    // MARK: Orb

    private var orb: some View {
        Button(action: orbTapped) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.18))
                    .frame(width: 260, height: 260)
                    .scaleEffect(breathing ? 1.06 : 0.94)
                Circle()
                    .fill(tint.opacity(0.28))
                    .frame(width: 200, height: 200)
                    .scaleEffect(breathing ? 1.03 : 0.97)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [tint.opacity(0.95), tint.opacity(0.55)],
                            center: .center, startRadius: 4, endRadius: 90
                        )
                    )
                    .frame(width: 150, height: 150)
                    .shadow(color: tint.opacity(0.5), radius: 24)
                Image(systemName: orbSymbol)
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating, isActive: isAnimatingSymbol)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 260, height: 260)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isOrbTappable)
        .accessibilityLabel(orbAccessibilityLabel)
    }

    // MARK: Status + caption

    private var statusText: some View {
        Text(statusLabel)
            .font(.system(.largeTitle, design: .rounded).weight(.semibold))
            .foregroundStyle(.primary)
            .multilineTextAlignment(.center)
            .animation(Constants.Animation.quick, value: statusLabel)
    }

    @ViewBuilder
    private var captionArea: some View {
        switch phase {
        case .listening:
            // Live partial (what the user is saying). Placeholder invites speech.
            let partial = speech.isListening ? speech.partialTranscript : ""
            Text(partial.isEmpty ? "Say something…" : partial)
                .font(.title3)
                .foregroundStyle(partial.isEmpty ? .secondary : .primary)
                .multilineTextAlignment(.center)
                .lineLimit(4)
                .frame(minHeight: 80)

        case .speaking, .thinking, .idle:
            if latestReply.isEmpty {
                Color.clear.frame(minHeight: 80)
            } else {
                Text(latestReply)
                    .font(.title3)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .frame(minHeight: 80)
            }

        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.center)
                .frame(minHeight: 80)

        case .blocked(let message):
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 80)
        }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        if case .blocked = phase {
            VStack(spacing: Constants.Spacing.sm) {
                if onOpenSettings != nil {
                    Button {
                        endAndDismiss()
                        onOpenSettings?()
                    } label: {
                        Text("Open Settings")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Close") { endAndDismiss() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: 420)
        } else {
            Button {
                endAndDismiss()
            } label: {
                Label("End", systemImage: "phone.down.fill")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .frame(maxWidth: 420)
            .help("Stop and leave voice mode")
        }
    }

    // MARK: Session lifecycle

    /// Starts the session. No-op after the first call. If there's no Claude key we
    /// show the blocked state and never open the mic.
    private func begin() {
        guard !started else { return }
        started = true

        guard Constants.isAPIKeyConfigured else {
            phase = .blocked("Add your Claude API key in Settings to talk to the assistant.")
            return
        }

        // Take over reply orchestration so the reply is spoken exactly once, here,
        // and its end drives the next listen. Saved + restored on dismiss.
        savedReplyHandler = coordinator.onAssistantReply
        coordinator.onAssistantReply = { reply in replyReady(reply) }
        speech.onFinalTranscript = { text in finalTranscript(text) }
        tookOverReply = true

        sessionActive = true
        startBreathing()
        startListening()
    }

    /// Full teardown: stop looping, kill the mic + TTS, release the shared voice
    /// audio session, and restore the reply handler `ChatView` had. Idempotent —
    /// runs from both the End button and `onDisappear`, so any dismissal path
    /// leaves nothing running.
    private func end() {
        guard started else { return }
        sessionActive = false
        speech.cancel()
        synthesizer.stop()
        if tookOverReply {
            coordinator.onAssistantReply = savedReplyHandler
            tookOverReply = false
        }
        // Release the one shared `.playAndRecord` session LAST, after both the
        // recognizer and the synthesizer are quiet. This view is the session's
        // owner: `SpeechService` activates it lazily on the first listen and
        // deliberately never deactivates it between turns (see VoiceAudioSession).
        VoiceAudioSession.shared.endVoiceSession()
        started = false
    }

    private func endAndDismiss() {
        end()
        dismiss()
    }

    // MARK: Loop steps

    /// Opens the mic for the next turn. Guards the recognizer being usable, and
    /// always stops any TTS first so the speaker can't feed back into the mic.
    private func startListening() {
        guard sessionActive else { return }
        guard speech.isAvailable else {
            phase = .blocked("Speech recognition isn't available on this device.")
            sessionActive = false
            return
        }
        synthesizer.stop()
        phase = .listening
        speech.start()
    }

    /// The recognizer handed us a final, trimmed, non-empty transcript (manual
    /// stop, final result, or silence auto-stop). Send it through the shared brain.
    private func finalTranscript(_ text: String) {
        guard sessionActive else { return }
        phase = .thinking
        coordinator.run(userText: text)
    }

    /// The coordinator finished a turn with a visible reply. Speak it exactly once.
    private func replyReady(_ reply: String) {
        guard sessionActive else { return }
        latestReply = reply
        phase = .speaking
        synthesizer.speak(reply)
        // Muted (or nothing playable) → `isSpeaking` never flips true and the
        // speaking-finished bridge won't fire, so resume listening right away.
        if !synthesizer.isSpeaking {
            startListening()
        }
    }

    // MARK: Observable bridges

    /// `coordinator.isRunning` false → the turn ended. If a reply was produced,
    /// `replyReady` already moved us to `.speaking`; this only handles turns that
    /// end WITHOUT spoken text (a notice, a cards-only action, or a transport
    /// error): surface an error briefly, otherwise just listen again.
    private func turnRunningChanged(_ running: Bool) {
        guard sessionActive, !running, phase == .thinking else { return }
        if let error = coordinator.lastError {
            phase = .error(error.message)
            resumeAfterError()
        } else {
            startListening()
        }
    }

    /// TTS finished. If we're still in `.speaking`, open the mic for the next turn.
    private func speakingChanged(_ speaking: Bool) {
        guard sessionActive, !speaking, phase == .speaking else { return }
        startListening()
    }

    /// The recognizer stopped while we were `.listening` and no transcript was
    /// sent (e.g. silence with nothing said). Re-arm after a short beat so we don't
    /// thrash the audio session.
    private func listeningChanged(_ listening: Bool) {
        guard sessionActive, !listening, phase == .listening else { return }
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard sessionActive, phase == .listening, !speech.isListening else { return }
            startListening()
        }
    }

    private func blockPermission() {
        sessionActive = false
        speech.cancel()
        phase = .blocked("Enable Microphone and Speech Recognition for GentleNudge in Settings to use voice.")
    }

    /// The recognizer reported it can't work right now (server recognition needs
    /// network / Siri services, or audio capture repeatedly failed to start).
    /// Without this bridge a failed `speech.start()` would leave the view in a
    /// fake "Listening…" state with the mic dead.
    private func blockUnavailable() {
        guard sessionActive else { return }
        sessionActive = false
        speech.cancel()
        phase = .blocked("Speech recognition isn't available right now. Check your internet connection, then reopen voice mode.")
    }

    private func resumeAfterError() {
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard sessionActive else { return }
            startListening()
        }
    }

    // MARK: Orb interaction

    /// Context-sensitive orb tap: while listening → stop + send now; while the
    /// assistant is speaking → interrupt and start listening (great in the car).
    private func orbTapped() {
        switch phase {
        case .listening:
            if speech.isListening { speech.stop() }
        case .speaking:
            startListening() // stops TTS first
        default:
            break
        }
    }

    private var isOrbTappable: Bool {
        switch phase {
        case .listening, .speaking: return true
        default: return false
        }
    }

    // MARK: Animation

    private func startBreathing() {
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            breathing = true
        }
    }

    private var isAnimatingSymbol: Bool {
        switch phase {
        case .listening, .thinking, .speaking: return true
        default: return false
        }
    }

    // MARK: Presentation tokens

    private var tint: Color {
        switch phase {
        case .idle: return .secondary
        case .listening: return .accentColor
        case .thinking: return .orange
        case .speaking: return .green
        case .error: return .orange
        case .blocked: return .secondary
        }
    }

    private var orbSymbol: String {
        switch phase {
        case .idle: return "mic.fill"
        case .listening: return "waveform"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.3.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .blocked: return "mic.slash.fill"
        }
    }

    private var statusLabel: String {
        switch phase {
        case .idle: return "Getting ready…"
        case .listening: return "Listening…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking…"
        case .error: return "Let's try again"
        case .blocked: return "Voice unavailable"
        }
    }

    private var orbAccessibilityLabel: String {
        switch phase {
        case .listening: return "Listening. Tap to send."
        case .speaking: return "Speaking. Tap to interrupt and talk."
        default: return statusLabel
        }
    }
}

#Preview {
    let container = try! ModelContainer(
        for: Reminder.self, Category.self, UserMemory.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return VoiceModeView(synthesizer: SpeechSynthesizer())
        .environment(ChatCoordinator(modelContainer: container))
        .modelContainer(container)
}
