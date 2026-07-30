import SwiftUI

struct CodexResponseAnnotationAttachmentView: View {
    @Environment(\.codexAgentTheme) private var theme
    @Binding var annotations: [CodexResponseTextAnnotation]
    @State private var showsDetails = false
    @State private var editingID: String?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                showsDetails.toggle()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "text.bubble")
                    Text(summary)
                        .font(theme.fonts.caption.weight(.medium))
                }
                .foregroundStyle(theme.colors.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(
                    theme.colors.surfaceElevated.opacity(0.72),
                    in: RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: theme.radii.small, style: .continuous)
                        .stroke(theme.colors.border.opacity(0.8), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
                details
                    .codexAgentTheme(theme)
            }

            Button {
                annotations.removeAll()
            } label: {
                Image(systemName: "xmark")
                    .font(theme.fonts.micro.weight(.semibold))
                    .foregroundStyle(theme.colors.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove annotations attachment")
            .accessibilityLabel("Remove annotations attachment")
        }
    }

    private var details: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(annotations.enumerated()), id: \.element.id) { index, annotation in
                    annotationRow(annotation, number: index + 1)
                    if index < annotations.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .frame(width: 360, height: min(320, CGFloat(annotations.count) * 132 + 16))
    }

    private func annotationRow(
        _ annotation: CodexResponseTextAnnotation,
        number: Int
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(number).")
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textTertiary)
                .frame(width: 20, alignment: .trailing)

            VStack(alignment: .leading, spacing: 8) {
                labeledValue("Selected text:", annotation.text)
                if editingID == annotation.id {
                    TextField(
                        "Add an optional comment…",
                        text: noteBinding(for: annotation.id),
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit { editingID = nil }
                } else if let comment = annotation.annotation {
                    labeledValue("User comment:", comment)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 2) {
                Button {
                    editingID = editingID == annotation.id ? nil : annotation.id
                } label: {
                    Image(systemName: "pencil")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Edit annotation \(number)")
                .accessibilityLabel("Edit annotation \(number)")

                Button {
                    annotations.removeAll { $0.id == annotation.id }
                    if annotations.isEmpty { showsDetails = false }
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Remove annotation \(number)")
                .accessibilityLabel("Remove annotation \(number)")
            }
            .foregroundStyle(theme.colors.textTertiary)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(theme.fonts.micro.weight(.medium))
                .foregroundStyle(theme.colors.textTertiary)
            Text(value)
                .font(theme.fonts.caption)
                .foregroundStyle(theme.colors.textPrimary)
                .textSelection(.enabled)
        }
    }

    private func noteBinding(for id: String) -> Binding<String> {
        Binding(
            get: {
                annotations.first(where: { $0.id == id })?.annotation ?? ""
            },
            set: { value in
                guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
                annotations[index].annotation = value
            }
        )
    }

    private var summary: String {
        annotations.count == 1 ? "1 annotation" : "\(annotations.count) annotations"
    }
}
