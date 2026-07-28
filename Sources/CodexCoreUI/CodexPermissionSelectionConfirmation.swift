import SwiftUI

package enum CodexPermissionSelectionDecision: Equatable {
    case apply(CodexApprovalSelection)
    case confirmFullAccess

    package static func resolve(
        current: CodexApprovalSelection,
        requested: CodexApprovalSelection
    ) -> CodexPermissionSelectionDecision {
        if requested == .fullAccess, current != .fullAccess {
            return .confirmFullAccess
        }
        return .apply(requested)
    }
}

extension View {
    func codexFullAccessConfirmation(
        isPresented: Binding<Bool>,
        onConfirm: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            "Enable Full access?",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Enable Full access", role: .destructive, action: onConfirm)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Codex will have unrestricted access to files, commands, and the internet. "
                    + "Only continue for workspaces you trust."
            )
        }
    }
}
