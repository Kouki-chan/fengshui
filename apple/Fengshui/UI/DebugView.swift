import GRDB
import SwiftUI

/// Settings → Debug → Data & sync (spec §6.1, §15): row counts per label, last sync per type.
struct DebugView: View {
    let env: AppEnvironment
    @State private var labels: [(label: String, count: Int)] = []
    @State private var tables: [(String, Int)] = []
    @State private var syncs: [(type: String, last: Double?, done: Bool)] = []

    var body: some View {
        List {
            Section("Samples per label") {
                ForEach(labels, id: \.label) { row in
                    LabeledContent(row.label, value: "\(row.count)")
                        .accessibilityIdentifier("debug.label.\(row.label)")
                }
                if labels.isEmpty { Text("No samples yet").foregroundStyle(.secondary) }
            }
            Section("Tables") {
                ForEach(tables, id: \.0) { LabeledContent($0.0, value: "\($0.1)") }
            }
            Section("Last HealthKit sync") {
                ForEach(syncs, id: \.type) { s in
                    LabeledContent(LabelMapper.label(for: s.type)) {
                        Text(s.last.map { Date(timeIntervalSince1970: $0).formatted(date: .abbreviated, time: .shortened) } ?? "never")
                            + Text(s.done ? "" : " · backfilling")
                    }
                }
            }
            Section("Engine runs") {
                ForEach(Array(env.engine.history().prefix(20).enumerated()), id: \.offset) { _, r in
                    VStack(alignment: .leading) {
                        Text("\(r.trigger) · \(r.ok ? "OK" : "FAILED") · +\(r.rowsWritten) · \(String(format: "%.2f", r.seconds)) s")
                            .font(.caption.bold())
                        Text(Date(timeIntervalSince1970: r.ts).formatted(date: .abbreviated, time: .standard)
                             + " " + r.tasks.joined(separator: ",") + (r.error.map { " " + $0 } ?? ""))
                            .font(.caption2)
                    }
                }
                Button("Run engine now") { Task { await env.engine.run(trigger: "manual"); reload() } }
                    .accessibilityIdentifier("debug.runEngine")
            }
            Section("Events") {
                ForEach(env.log.events.suffix(50).reversed()) { e in
                    VStack(alignment: .leading) {
                        Text(e.kind).font(.caption.bold())
                        Text("\(e.ts.formatted(date: .omitted, time: .standard)) \(e.detail)").font(.caption2)
                    }
                }
            }
        }
        .navigationTitle("Data & sync")
        .task { reload() }
        .refreshable { reload() }
    }

    private func reload() {
        labels = (try? env.db.labelCounts()) ?? []
        tables = ((try? env.db.rowCounts()) ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        syncs = (try? env.db.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT hk_type, last_sync_ts, backfill_done FROM sync_state ORDER BY hk_type")
                .map { (type: $0["hk_type"] as String, last: $0["last_sync_ts"] as Double?, done: ($0["backfill_done"] as Int) == 1) }
        }) ?? []
    }
}
