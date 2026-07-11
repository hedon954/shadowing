import SwiftUI

struct PracticeAlertsModifier: ViewModifier {
    @ObservedObject var viewModel: PracticeViewModel

    func body(content: Content) -> some View {
        content
            .modifier(PracticeFailureAlertsModifier(viewModel: viewModel))
            .modifier(PracticeRecordingLeaveAlertModifier(viewModel: viewModel))
            .modifier(PracticeTakeDeletionAlertModifier(viewModel: viewModel))
            .modifier(PracticeMicrophoneAlertModifier(viewModel: viewModel))
    }
}

private struct PracticeFailureAlertsModifier: ViewModifier {
    @ObservedObject var viewModel: PracticeViewModel

    func body(content: Content) -> some View {
        content.alert(item: $viewModel.failure) { failure in
            Alert(
                title: Text("Practice Error"),
                message: Text(failure.message),
                dismissButton: .default(Text("OK")) {
                    viewModel.dismissFailure()
                }
            )
        }
    }
}

private struct PracticeRecordingLeaveAlertModifier: ViewModifier {
    @ObservedObject var viewModel: PracticeViewModel

    func body(content: Content) -> some View {
        content.alert(
            "Recording In Progress",
            isPresented: Binding(
                get: { viewModel.leaveConfirmation != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.cancelLeave()
                    }
                }
            )
        ) {
            Button("Stop and Close", role: .destructive) {
                viewModel.confirmStopAndLeave()
            }
            Button("Continue Recording", role: .cancel) {
                viewModel.cancelLeave()
            }
        } message: {
            Text("Recording is in progress.\n\nStop recording and close, or continue recording?")
        }
    }
}

private struct PracticeTakeDeletionAlertModifier: ViewModifier {
    @ObservedObject var viewModel: PracticeViewModel

    func body(content: Content) -> some View {
        content.alert(
            "Delete Take?",
            isPresented: Binding(
                get: { viewModel.takePendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.cancelDeleteTake()
                    }
                }
            ),
            presenting: viewModel.takePendingDeletion
        ) { take in
            Button("Delete", role: .destructive) {
                viewModel.confirmDeleteTake()
            }
            Button("Cancel", role: .cancel) {
                viewModel.cancelDeleteTake()
            }
            .accessibilityLabel("Cancel delete take \(take.sequence)")
        } message: { take in
            Text("Delete Take \(take.sequence)? This cannot be undone.")
        }
    }
}

private struct PracticeMicrophoneAlertModifier: ViewModifier {
    @ObservedObject var viewModel: PracticeViewModel

    func body(content: Content) -> some View {
        content.alert(
            "Microphone Access Required",
            isPresented: Binding(
                get: { viewModel.microphonePermissionPrompt != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissMicrophonePermissionPrompt()
                    }
                }
            ),
            presenting: viewModel.microphonePermissionPrompt
        ) { _ in
            Button("Open System Settings") {
                viewModel.openMicrophoneSettings()
            }
            Button("Cancel", role: .cancel) {
                viewModel.dismissMicrophonePermissionPrompt()
            }
        } message: { permission in
            Text(permissionMessage(permission))
        }
    }

    private func permissionMessage(_ permission: MicrophonePermissionState) -> String {
        switch permission {
        case .denied:
            "Microphone access is denied. Enable it for Shadowing in System Settings."
        case .restricted:
            "Microphone access is restricted on this Mac."
        case .notDetermined:
            "Shadowing needs microphone access to record your practice."
        case .authorized:
            "Microphone access is available."
        }
    }
}
