import SwiftUI

/// Picks one of the local daily snapshots to restore.
///
/// Each row confirms first and spells out what restoring does, because "restore"
/// usually means "replace everything" in other apps — here it only adds back what
/// is missing, and saying so is what makes it safe to actually use.
struct BackupRestoreListView: View {
    let backups: [(date: Date, url: URL, size: Int64)]
    let onRestore: (URL) -> Void

    @State private var pendingRestore: URL?

    var body: some View {
        List {
            Section {
                if backups.isEmpty {
                    Text("No backups yet. One is saved automatically each day you open Gentle Nudge.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(backups, id: \.url) { backup in
                        Button {
                            pendingRestore = backup.url
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(backup.date.formatted(date: .complete, time: .omitted))
                                        .foregroundStyle(.primary)
                                    Text(Self.fileSize(backup.size))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.counterclockwise.circle")
                                    .foregroundStyle(AppColors.accent)
                            }
                        }
                        .accessibilityLabel("Restore backup from \(backup.date.formatted(date: .complete, time: .omitted))")
                    }
                }
            } footer: {
                Text("Restoring adds back any reminders, categories, or memories that are missing. Nothing you have now is changed or deleted.")
            }
        }
        .navigationTitle("Restore a Backup")
        .confirmationDialog(
            "Restore this backup?",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Restore Missing Items") {
                if let url = pendingRestore { onRestore(url) }
                pendingRestore = nil
            }
            Button("Cancel", role: .cancel) { pendingRestore = nil }
        } message: {
            Text("Anything from this backup that's no longer in your list will be added back. Existing reminders are left exactly as they are.")
        }
    }

    private static func fileSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}
