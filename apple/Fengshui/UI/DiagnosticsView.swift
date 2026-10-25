import GRDB
import SwiftUI

struct DiagnosticsView: View {
    let env: AppEnvironment
    @State private var report: Diagnostics.Report?
    @State private var status = ""
    @State private var running = false

    var body: some View {
        List {
            Section {
                Button(running ? "Running…" : "Run diagnostics") { Task { await run() } }
                    .disabled(running)
                    .accessibilityIdentifier("diag.run")
                if !status.isEmpty { Text(status).font(.caption).accessibilityIdentifier("diag.status") }
            } footer: { Text("Uploads the result to your Mac server if it's reachable. Contains counts and pass/fail only.") }
            if let r = report {
                Section("Checks") {
                    ForEach(r.checks) { c in
                        HStack(alignment: .top) {
                            Image(systemName: c.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(c.ok ? .green : .orange)
                            VStack(alignment: .leading) {
                                Text(c.name.replacingOccurrences(of: "_", with: " ")).font(.subheadline)
                                Text(c.detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("diag.check.\(c.name)")
                    }
                }
                Section("Measurements") {
                    ForEach(r.metrics.sorted { $0.key < $1.key }, id: \.key) { k, v in
                        LabeledContent(k, value: String(format: "%.2f", v))
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
    }

    private func run() async {
        running = true
        status = ""
        let d = Diagnostics(env: env)
        let r = await d.run()
        report = r
        do {
            try await d.upload(r)
            status = "Uploaded to the Mac ✓ (\(r.checks.filter(\.ok).count)/\(r.checks.count) OK)"
        } catch {
            status = "Not uploaded: \(error)"
        }
        running = false
    }
}

/// Data export (spec §15): a consistent copy of the database to share / save to Files.
struct ExportDatabaseView: View {
    let env: AppEnvironment
    @State private var url: URL?
    @State private var error: String?

    var body: some View {
        Form {
            if let url {
                ShareLink(item: url) { Label("Save or share fengshui.sqlite", systemImage: "square.and.arrow.up") }
                    .accessibilityIdentifier("export.share")
                Text(ByteCountFormatter.string(fromByteCount: Int64((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0), countStyle: .file))
                    .font(.caption)
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView("Preparing a copy…")
            }
        }
        .navigationTitle("Export database")
        .task {
            do { url = try await DatabaseExport.makeCopy(env.db) } catch { self.error = "\(error)" }
        }
    }
}

enum DatabaseExport {
    /// SQLite online backup: consistent even while the engine or a sync is writing.
    static func makeCopy(_ db: AppDatabase) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("fengshui-\(stamp).sqlite")
        let dest = try DatabaseQueue(path: url.path)
        try db.writer.backup(to: dest)
        try dest.close()
        return url
    }
}
