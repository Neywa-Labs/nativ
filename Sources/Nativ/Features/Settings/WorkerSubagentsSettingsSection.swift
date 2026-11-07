import SwiftUI

struct WorkerSubagentsSettingsSection: View {
    let model: NativModel

    @State private var rows: [WorkerSettingsRow] = []
    @State private var needsMemoryHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Worker Sub-agents")
                .legacyTextStyle(.sectionTitle)

            VStack(spacing: 0) {
                row(
                    title: "Worker sub-agents",
                    description: "Run sub-agents on small, fast models in a second server. Best with a large dense manager (32B+). Uses extra memory.",
                    systemImage: "person.2.wave.2"
                ) {
                    Toggle("", isOn: enabledBinding)
                        .labelsHidden()
                }
                if model.settings.workerSubagentsEnabled {
                    Divider().padding(.leading, 52)
                    row(
                        title: "Worker context",
                        description: "Tokens each worker can hold. Raise on Macs with more memory.",
                        systemImage: "text.alignleft"
                    ) {
                        TextField("", value: contextBinding, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                    }
                    Divider().padding(.leading, 52)
                    picksTable
                        .padding(.horizontal, 18)
                        .padding(.vertical, 15)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
        .task(id: refreshKey) { await refresh() }
    }

    private var picksTable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(["Category", "Recommended worker", "Downloaded", "Est. speed", "Est. quality", "Source"], id: \.self) {
                        Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                ForEach(rows, id: \.category) { row in
                    GridRow {
                        Text(row.category.replacingOccurrences(of: "_", with: " "))
                        if let candidate = row.recommended {
                            Text(candidate.repoID.split(separator: "/").last.map(String.init) ?? candidate.repoID)
                                .lineLimit(1)
                                .help(candidate.repoID)
                            Text(candidate.isDownloaded
                                ? "Yes"
                                : "No (\(String(format: "%.1f", Double(candidate.sizeBytes) / 1_000_000_000)) GB)")
                            Text(candidate.speed.rawValue)
                            Text("\(Int(candidate.estimatedQuality.rounded()))")
                            Text(sourceName(candidate)).lineLimit(1)
                        } else {
                            Text("No fast model fits").foregroundStyle(.secondary)
                            Text("")
                            Text("")
                            Text("")
                            Text("")
                        }
                    }
                    .font(.callout)
                }
            }
            if needsMemoryHint {
                Text(WorkerSettingsTable.memoryHint(managerContextIsModelDefault: model.settings.maxKVSize == 0))
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
            if !WorkerModelCatalog.bundled.attribution.isEmpty {
                Text("Scores are estimates from: " + WorkerModelCatalog.bundled.attribution.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var statusText: String {
        switch model.workerServer.state {
        case .running(let port): "Worker server: running · port \(port)"
        case .starting: "Worker server: starting"
        case .failed(let message): "Worker server: failed · \(message)"
        case .stopped: "Worker server: stopped"
        }
    }

    private var refreshKey: String {
        let settings = model.settings
        return "\(settings.workerSubagentsEnabled)-\(settings.workerContextTokens)-\(settings.languageModelID ?? "")-\(settings.maxKVSize)"
    }

    private func refresh() async {
        guard let routing = model.workerRouting(for: model.settings) else {
            rows = []
            needsMemoryHint = false
            return
        }
        let environment = await routing.environment()
        rows = WorkerSettingsTable.rows(environment: environment)
        needsMemoryHint = WorkerSettingsTable.needsMemoryHint(rows: rows)
    }

    private func sourceName(_ candidate: WorkerCandidate) -> String {
        guard let source = candidate.sources.first?.source else { return "n/a" }
        return source.replacingOccurrences(of: " (via Every Eval Ever)", with: "")
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { model.settings.workerSubagentsEnabled },
            set: { isEnabled in
                var settings = model.settings
                settings.workerSubagentsEnabled = isEnabled
                model.settings = settings.normalized()
            }
        )
    }

    private var contextBinding: Binding<Int> {
        Binding(
            get: { model.settings.workerContextTokens },
            set: { tokens in
                var settings = model.settings
                settings.workerContextTokens = tokens
                model.settings = settings.normalized()
            }
        )
    }

    private func row<Accessory: View>(
        title: String,
        description: String,
        systemImage: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            accessory()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
    }
}
