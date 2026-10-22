import SwiftUI

/// Adds a runner from the ./config.sh line on GitHub's "New self-hosted runner" page: paste it, click Add Runner.
struct AddRunnerSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var command = ""
    @State private var name = ""
    @State private var step: String?
    @State private var error: String?

    var body: some View {
        let parsed = parseConfigCommand(command)
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Runner").font(.title2.bold())
            Text("On GitHub, open your organization's or repository's **Settings › Actions › Runners**, click **New self-hosted runner**, choose **macOS**, and copy the line that starts with `./config.sh`.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("./config.sh --url https://github.com/… --token …", text: $command, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
            if let parsed {
                Label("Registers with \(parsed.url.replacingOccurrences(of: "https://", with: ""))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.okText)
            } else if !command.isEmpty {
                Label("Paste the whole line: it needs both --url and --token.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.warnText)
            }
            LabeledContent("Runner name") {
                TextField("Runner name", text: $name).labelsHidden().frame(width: 240)
            }
            if let step {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(step) }
            }
            if let error {
                Text(error).foregroundStyle(Color.dangerText).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Runner") { if let parsed { create(parsed) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(parsed == nil || name.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .disabled(step != nil)
        .onChange(of: parsed?.url) { _, url in
            if let url { name = defaultRunnerName(for: url, existing: store.runners) }
        }
    }

    private func create(_ p: (url: String, token: String)) {
        (error, step) = (nil, "Starting…")
        let name = name
        DispatchQueue.global(qos: .userInitiated).async {
            let failure = createRunner(url: p.url, token: p.token, name: name) { s in DispatchQueue.main.async { step = s } }
            DispatchQueue.main.async {
                step = nil
                store.refresh()
                if let failure { error = failure } else { dismiss() }
            }
        }
    }
}
