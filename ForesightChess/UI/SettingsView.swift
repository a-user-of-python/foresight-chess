import SwiftUI

/// Settings: adjustable foresight depth, knowledge reset.
struct SettingsView: View {
    @Binding var foresightMoves: Int
    @Environment(\.dismiss) private var dismiss
    @State private var showResetConfirm = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Foresight")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Moves ahead the AI can see: \(foresightMoves)")
                            .font(.headline)
                        Slider(value: Binding(
                            get: { Double(foresightMoves) },
                            set: { foresightMoves = Int($0.rounded()) }
                        ), in: 1...3, step: 1)
                        Text(foresightDescription)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section(header: Text("Chess Knowledge")) {
                    Text("The neural network learns from every game you play. " +
                         "It starts from scratch and gets smarter over time.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                    if let exportURL = KnowledgeStore.shared.exportURL() {
                        ShareLink(item: exportURL) {
                            Label("Export Network", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Text("No trained network yet — play a game first.")
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    Button("Reset Knowledge", role: .destructive) {
                        showResetConfirm = true
                    }
                }

                Section(header: Text("About")) {
                    Text("Moves are chosen by Apple's on-device AI (Foundation Models), " +
                         "consulting a chess neural network as its reference. " +
                         "Requires iOS 26+ with Apple Intelligence for the AI player; " +
                         "otherwise the neural network plays directly.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Reset Knowledge?", isPresented: $showResetConfirm) {
                Button("Reset", role: .destructive) {
                    KnowledgeStore.shared.reset()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This erases everything the network learned. It starts over from scratch.")
            }
        }
    }

    private var foresightDescription: String {
        switch foresightMoves {
        case 1:
            return "Sees 1 move ahead (your move + AI reply). Fast, more tactical mistakes."
        case 2:
            return "Sees 2 moves ahead. Balanced — good default."
        case 3:
            return "Sees 3 moves ahead. Strongest, but takes longer to think."
        default:
            return ""
        }
    }
}
