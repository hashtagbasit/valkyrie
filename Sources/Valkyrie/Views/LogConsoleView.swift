import SwiftUI

struct LogConsoleView: View {
    var lines: [LogLine]
    var onClear: () -> Void
    var onExport: (() -> Void)?

    var body: some View {
        Card(
            title: "Log",
            accessory: AnyView(
                HStack(spacing: 6) {
                    if let onExport {
                        Button("Save…", action: onExport)
                            .controlSize(.small)
                            .disabled(lines.isEmpty)
                    }
                    Button("Clear", action: onClear)
                        .controlSize(.small)
                        .disabled(lines.isEmpty)
                }
            )
        ) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(lines) { line in
                            Text(line.text)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(color(for: line.kind))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                        if lines.isEmpty {
                            Text("Output appears here.")
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(Theme.consoleMuted)
                        }
                    }
                    .padding(9)
                }
                .frame(minHeight: lines.isEmpty ? 60 : 150, maxHeight: lines.isEmpty ? 60 : .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.consoleBackground)
                )
                .onChange(of: lines.count) { _ in
                    guard let last = lines.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func color(for kind: LogLine.Kind) -> Color {
        switch kind {
        case .info: return Theme.consoleText
        case .success: return Theme.consoleSuccess
        case .error: return Theme.consoleDanger
        case .command: return Theme.consoleAccent
        }
    }
}
