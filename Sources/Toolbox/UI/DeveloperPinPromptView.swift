import Combine
import SwiftUI

@MainActor
private final class DeveloperPinPromptState: ObservableObject {
    @Published var pinText: String = ""
    @Published var errorMessage: String?
    @Published var lockoutRemainingSeconds: Int = 0

    func refreshLockout(from manager: DeveloperModeManager) {
        let remaining = manager.remainingLockoutSeconds()
        lockoutRemainingSeconds = remaining
        if remaining > 0 {
            errorMessage = "Too many incorrect attempts. Try again in \(remaining)s."
        } else if errorMessage?.hasPrefix("Too many incorrect attempts") == true {
            errorMessage = nil
        }
    }
}

struct DeveloperPinPromptView: View {
    @ObservedObject private var developerMode = DeveloperModeManager.shared
    @StateObject private var state = DeveloperPinPromptState()
    @FocusState private var isPinFieldFocused: Bool

    let onUnlocked: () -> Void
    let onCancel: () -> Void

    private let lockoutTicker = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.purple.opacity(0.16))
                        .frame(width: 40, height: 40)
                    Image(systemName: "lock.shield.fill")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.purple)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Unlock Developer Tools")
                        .font(.headline)
                    Text("Enter the developer PIN to access simulations and diagnostics.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SecureField("Developer PIN", text: $state.pinText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.title3, design: .monospaced))
                    .focused($isPinFieldFocused)
                    .disabled(state.lockoutRemainingSeconds > 0)
                    .onSubmit {
                        submit()
                    }
                    .onChange(of: state.pinText) { _, newValue in
                        let digitsOnly = newValue.filter(\.isNumber)
                        if digitsOnly != newValue {
                            state.pinText = digitsOnly
                        }
                        if state.lockoutRemainingSeconds == 0,
                           state.errorMessage?.hasPrefix("Incorrect PIN") == true {
                            state.errorMessage = nil
                        }
                    }

                if let error = state.errorMessage {
                    HStack(spacing: 6) {
                        Image(systemName: state.lockoutRemainingSeconds > 0 ? "clock.badge.exclamationmark" : "exclamationmark.triangle.fill")
                            .font(.caption)
                        Text(error)
                            .font(.caption)
                    }
                    .foregroundStyle(state.lockoutRemainingSeconds > 0 ? .orange : .red)
                }
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .pointerCursor()

                Button("Unlock") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.toolboxProminent(.purple))
                .disabled(state.pinText.isEmpty || state.lockoutRemainingSeconds > 0)
                .pointerCursor(!state.pinText.isEmpty && state.lockoutRemainingSeconds == 0)
            }
        }
        .padding(22)
        .frame(width: 360)
        .toolboxDarkAppearance()
        .onAppear {
            state.refreshLockout(from: developerMode)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isPinFieldFocused = true
            }
        }
        .onReceive(lockoutTicker) { _ in
            if state.lockoutRemainingSeconds > 0 || developerMode.pinLockoutUntil != nil {
                state.refreshLockout(from: developerMode)
                if state.lockoutRemainingSeconds == 0 {
                    isPinFieldFocused = true
                }
            }
        }
    }

    private func submit() {
        let candidate = state.pinText
        guard !candidate.isEmpty else { return }

        switch developerMode.submitPIN(candidate) {
        case .unlocked:
            state.pinText = ""
            state.errorMessage = nil
            onUnlocked()
        case .wrongPin(let remaining):
            state.pinText = ""
            state.errorMessage = remaining == 1
                ? "Incorrect PIN. 1 attempt remaining before cooldown."
                : "Incorrect PIN. \(remaining) attempts remaining."
            isPinFieldFocused = true
        case .lockedOut(let seconds):
            state.pinText = ""
            state.lockoutRemainingSeconds = seconds
            state.errorMessage = "Too many incorrect attempts. Try again in \(seconds)s."
        }
    }
}
