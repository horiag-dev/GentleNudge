import SwiftUI

struct AIEnhanceButton: View {
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "sparkles")
                }
                Text(isLoading ? "Enhancing..." : "Enhance with AI")
            }
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                LinearGradient(
                    colors: [.purple, .blue],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
            .shadow(color: .purple.opacity(0.3), radius: 8, y: 4)
        }
        .disabled(isLoading)
        .opacity(isLoading ? 0.7 : 1)
    }
}

struct AISuggestButton: View {
    let title: String
    let icon: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: icon)
                        .font(.caption)
                }
                Text(title)
                    .font(.caption)
            }
            .foregroundStyle(.purple)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.purple.opacity(0.1))
            .clipShape(Capsule())
        }
        .disabled(isLoading)
    }
}

#Preview {
    VStack(spacing: 20) {
        AIEnhanceButton(isLoading: false) {}
        AIEnhanceButton(isLoading: true) {}

        HStack {
            AISuggestButton(title: "Suggest Category", icon: "sparkles", isLoading: false) {}
            AISuggestButton(title: "Suggesting...", icon: "sparkles", isLoading: true) {}
        }
    }
    .padding()
}
