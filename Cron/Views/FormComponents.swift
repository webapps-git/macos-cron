import AppKit
import SwiftData
import SwiftUI

struct LabeledTextEditor: View {
    var title: String
    @Binding var text: String
    var monospaced: Bool
    var minHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L(title))
                .font(.headline)

            TextEditor(text: $text)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .frame(minHeight: minHeight)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.secondary.opacity(0.28))
                }
        }
    }
}

extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct LabeledTextField: View {
    var title: String
    var placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L(title))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)

            TextField(L(placeholder), text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

struct LabeledPathField: View {
    var title: String
    var placeholder: String
    @Binding var text: String
    var canChooseFiles: Bool
    var canChooseDirectories: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L(title))
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .leading)

            TextField(L(placeholder), text: $text)
                .textFieldStyle(.roundedBorder)

            Button {
                choosePath()
            } label: {
                Image(systemName: canChooseDirectories && !canChooseFiles ? "folder" : "doc")
            }
            .help(L("Choose path"))
        }
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.title = L("Choose path")
        panel.canChooseFiles = canChooseFiles
        panel.canChooseDirectories = canChooseDirectories
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            text = url.path
        }
    }
}
