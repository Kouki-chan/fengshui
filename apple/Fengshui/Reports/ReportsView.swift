import GRDB
import PDFKit
import SwiftUI

/// Reports tab (DECISIONS D-20): build a PDF for a health professional (AI suggests the labels,
/// the user adjusts, AI writes the summary), and browse every saved report, including the one
/// each Ask question creates, filtered by labels and a date or date range.
struct ReportsView: View {
    enum Period: String, CaseIterable { case day = "Day", range = "Range" }

    let env: AppEnvironment
    @State private var period: Period = .range
    @State private var day = Date()
    @State private var start = Date().addingTimeInterval(-29 * 86_400)
    @State private var end = Date()
    @State private var title = ""
    @State private var purpose = ""
    @State private var available: [ReportData.Available] = []
    @State private var selected = Set<String>()
    @State private var reasons: [String: String] = [:]
    @State private var aiSummary = true
    @State private var busy: String?
    @State private var status: String?
    @State private var reports: [ReportRecord] = []
    @State private var filter = ReportFilter()
    @State private var filterStart = Date().addingTimeInterval(-6 * 86_400)
    @State private var filterEnd = Date()
    @State private var opened: ReportRecord?

    private var hasKey: Bool { env.secrets.get(SecretKey.anthropicKey).map { !$0.isEmpty } ?? false }
    private var startDate: String { ReportData.dayString(period == .day ? day : start, env.timeZone) }
    private var endDate: String { ReportData.dayString(period == .day ? day : max(start, end), env.timeZone) }

    var body: some View {
        List {
            newReport
            savedFilters
            Section {
                let shown = reports.filter(filter.matches)
                if shown.isEmpty {
                    Text(reports.isEmpty ? "No reports yet. Each question you ask also saves a report here."
                                         : "No reports match the filters.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(shown) { r in
                    NavigationLink { ReportDetailView(env: env, report: r) } label: { ReportRow(report: r, tz: env.timeZone) }
                        .accessibilityIdentifier("report.row.\(r.id)")
                }
                .onDelete { idx in
                    let ids = idx.map { shown[$0].id }
                    Task { await env.reports.delete(ids) }
                }
            } header: { Text("Saved reports (\(reports.filter(filter.matches).count))") }
        }
        .navigationTitle("Reports")
        .navigationDestination(item: $opened) { ReportDetailView(env: env, report: $0) }
        .task(id: "\(startDate)|\(endDate)") { loadAvailable() }
        .task {
            let now = env.clock.now
            day = now; end = now; start = now.addingTimeInterval(-29 * 86_400)
            filterEnd = now; filterStart = now.addingTimeInterval(-6 * 86_400)
            let obs = ValueObservation.tracking { try ReportStore.fetchAll($0) }.removeDuplicates()
            do { for try await r in obs.values(in: env.db.writer) { reports = r } } catch {}
        }
        .onChange(of: filterStart) { syncFilterDates() }
        .onChange(of: filterEnd) { syncFilterDates() }
    }

    // MARK: New report

    private var newReport: some View {
        Section {
            Picker("Period", selection: $period) { ForEach(Period.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented).accessibilityIdentifier("report.period")
            if period == .day {
                DatePicker("Date", selection: $day, in: ...env.clock.now, displayedComponents: .date)
            } else {
                DatePicker("From", selection: $start, in: ...env.clock.now, displayedComponents: .date)
                DatePicker("To", selection: $end, in: start...max(start, env.clock.now), displayedComponents: .date)
                HStack {
                    ForEach([7, 30, 90], id: \.self) { n in
                        Button("\(n) d") {
                            end = env.clock.now
                            start = env.clock.now.addingTimeInterval(-Double(n - 1) * 86_400)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            TextField("Title (optional)", text: $title)
            TextField("Purpose, e.g. sleep review for my GP", text: $purpose, axis: .vertical)
                .accessibilityIdentifier("report.purpose")
            NavigationLink {
                ReportLabelPicker(available: available, selected: $selected, reasons: reasons)
            } label: {
                LabeledContent("Data to include", value: "\(selected.intersection(available.map(\.label)).count) of \(available.count)")
            }
            .accessibilityIdentifier("report.labels")
            Button {
                Task { await suggest() }
            } label: {
                Label("Let AI choose the data", systemImage: "sparkles")
            }
            .disabled(!hasKey || busy != nil || available.isEmpty)
            .accessibilityIdentifier("report.suggest")
            Toggle("AI-written summary", isOn: $aiSummary).disabled(!hasKey)
            Button {
                Task { await create() }
            } label: {
                HStack {
                    Label("Create PDF report", systemImage: "doc.badge.plus")
                    if busy != nil { Spacer(); ProgressView() }
                }
            }
            .disabled(busy != nil || selected.intersection(available.map(\.label)).isEmpty)
            .accessibilityIdentifier("report.create")
            if let busy { Text(busy).font(.caption).foregroundStyle(.secondary) }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("report.status") }
        } header: {
            Text("New report")
        } footer: {
            Text(hasKey ? "The AI sees processed data through tools only, never raw watch data. Review its summary before sharing."
                        : "Add an Anthropic API key in Settings → Claude for AI label choice and summaries; without it the report has data only.")
        }
    }

    // MARK: Saved-report filters

    private var savedFilters: some View {
        Section {
            Picker("Show", selection: $filter.kind) { ForEach(ReportFilter.Kind.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented)
            Picker("Date", selection: $filter.dateMode) {
                ForEach(ReportFilter.DateMode.allCases, id: \.self) { Text($0.rawValue) }
            }
            .accessibilityIdentifier("report.filter.date")
            .onChange(of: filter.dateMode) { syncFilterDates() }
            if filter.dateMode == .day {
                DatePicker("On", selection: $filterStart, displayedComponents: .date)
            } else if filter.dateMode == .range {
                DatePicker("From", selection: $filterStart, displayedComponents: .date)
                DatePicker("To", selection: $filterEnd, in: filterStart..., displayedComponents: .date)
            }
            NavigationLink {
                ReportLabelFilter(labels: Array(Set(reports.flatMap(\.labels))).sorted { DataSnapshot.title($0) < DataSnapshot.title($1) },
                                  selected: $filter.labels)
            } label: {
                LabeledContent("Data", value: filter.labels.isEmpty ? "Any" : "\(filter.labels.count) selected")
            }
            .accessibilityIdentifier("report.filter.labels")
            TextField("Search title or question", text: $filter.text)
            if filter.isActive {
                Button("Clear filters", role: .destructive) { filter = ReportFilter() }
            }
        } header: { Text("Filter saved reports") }
    }

    private func syncFilterDates() {
        filter.start = ReportData.dayString(filterStart, env.timeZone)
        filter.end = ReportData.dayString(max(filterStart, filterEnd), env.timeZone)
    }

    // MARK: Actions

    private func loadAvailable() {
        available = env.reports.available(start: startDate, end: endDate)
        let present = Set(available.map(\.label))
        if selected.isEmpty || selected.isDisjoint(with: present) {
            // Sensible default before the AI or the user chooses: the core vitals, sleep and activity present.
            selected = present.intersection(["heart_rate", "resting_heart_rate", "heart_rate_variability_sdnn",
                                             "oxygen_saturation", "respiratory_rate", "sleep_analysis", "step_count",
                                             "workout"])
        }
    }

    private func suggest() async {
        guard let a = env.assistant(actions: ReportActions(store: env.reports)) else { return }
        busy = "The AI is checking which data is available…"
        status = nil
        let ans = await a.ask(ReportPrompts.suggest(start: startDate, end: endDate, purpose: purpose))
        busy = nil
        if let labels = ans.proposedLabels {
            let present = Set(available.map(\.label))
            selected = Set(labels).intersection(present)
            // Reasons come back in the tool input, in label order.
            if let call = ans.calls.last(where: { $0.name == "propose_report_labels" }) {
                let ls = (call.input["labels"] ?? "").components(separatedBy: "\n")
                let rs = (call.input["reasons"] ?? "").components(separatedBy: "\n")
                reasons = Dictionary(zip(ls, rs), uniquingKeysWith: { a, _ in a })
            }
            status = "AI chose \(selected.count) data types. Review them under “Data to include”."
        } else {
            status = ans.error.map { "Couldn't get a suggestion: \($0)" } ?? "The AI didn't propose labels: \(ans.text)"
        }
    }

    private func create() async {
        let labels = Array(selected.intersection(available.map(\.label))).sorted()
        let defaultTitle = purpose.isEmpty ? "Health report" : String(purpose.prefix(60))
        let req = ReportRequest(title: title.isEmpty ? defaultTitle : title, purpose: purpose.isEmpty ? nil : purpose,
                                startDate: startDate, endDate: endDate, labels: labels)
        status = nil
        if aiSummary, hasKey, let a = env.assistant(actions: ReportActions(store: env.reports, forced: req)) {
            busy = "The AI is reading your data and writing the summary…"
            let ans = await a.ask(ReportPrompts.create(req))
            if let id = ans.reportIDs.last, let r = env.reports.record(id) {
                busy = nil
                status = "Report created (\(r.pages) pages)."
                opened = r
                return
            }
            status = "The AI didn't finish (\(ans.error ?? "no report")); created the report without a summary."
        }
        busy = "Creating the PDF…"
        do {
            let r = try await env.reports.create(req)
            status = (status.map { $0 + " " } ?? "") + "Report created (\(r.pages) pages)."
            opened = r
        } catch {
            status = "Couldn't create the report: \(error)"
        }
        busy = nil
    }
}

struct ReportRow: View {
    let report: ReportRecord
    let tz: TimeZone

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: report.kind == "question" ? "bubble.left.and.text.bubble.right" : "doc.richtext")
                    .foregroundStyle(.secondary)
                Text(report.title).font(.subheadline).lineLimit(2)
            }
            Text("\(Fmt.period(report.startDate, report.endDate, tz)) · \(report.labels.count) data types · \(report.pages) p")
                .font(.caption2).foregroundStyle(.secondary)
            Text(Date(timeIntervalSince1970: report.createdAt).formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }
}

/// Choose the labels for a new report, grouped, with the AI's reasons when it suggested them.
struct ReportLabelPicker: View {
    let available: [ReportData.Available]
    @Binding var selected: Set<String>
    let reasons: [String: String]
    @State private var query = ""

    var body: some View {
        let shown = available.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        List {
            Section {
                HStack {
                    Button("Select all") { selected.formUnion(shown.map(\.label)) }
                    Spacer()
                    Button("Select none") { selected.subtract(shown.map(\.label)) }
                }
                .buttonStyle(.borderless)
            }
            ForEach(ReportData.groupOrder, id: \.self) { g in
                let items = shown.filter { $0.group == g }
                if !items.isEmpty {
                    Section(g) {
                        ForEach(items) { a in
                            Toggle(isOn: Binding(get: { selected.contains(a.label) },
                                                 set: { on in if on { selected.insert(a.label) } else { selected.remove(a.label) } })) {
                                VStack(alignment: .leading) {
                                    Text(a.title)
                                    Text("\(a.rows.formatted()) samples").font(.caption2).foregroundStyle(.secondary)
                                    if let r = reasons[a.label] { Text(r).font(.caption2).foregroundStyle(.blue) }
                                }
                            }
                            .accessibilityIdentifier("report.label.\(a.label)")
                        }
                    }
                }
            }
            if available.isEmpty { Text("No data in this period.").foregroundStyle(.secondary) }
        }
        .searchable(text: $query)
        .navigationTitle("Data to include")
    }
}

struct ReportLabelFilter: View {
    let labels: [String]
    @Binding var selected: Set<String>

    var body: some View {
        List {
            if !selected.isEmpty { Button("Any data") { selected = [] } }
            ForEach(labels, id: \.self) { l in
                Toggle(DataSnapshot.title(l), isOn: Binding(get: { selected.contains(l) },
                                                            set: { on in if on { selected.insert(l) } else { selected.remove(l) } }))
            }
            if labels.isEmpty { Text("No saved reports yet.").foregroundStyle(.secondary) }
        }
        .navigationTitle("Filter by data")
    }
}

struct ReportDetailView: View {
    let env: AppEnvironment
    let report: ReportRecord
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        let url = env.reports.url(report)
        PDFKitView(url: url)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(report.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url, preview: SharePreview(report.title, image: Image(systemName: "doc.richtext"))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("report.share")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                }
            }
            .confirmationDialog("Delete this report?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    Task { await env.reports.delete([report.id]); dismiss() }
                }
            }
            .accessibilityIdentifier("report.pdf")
    }
}

struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.document = PDFDocument(url: url)
        return v
    }

    func updateUIView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url { v.document = PDFDocument(url: url) }
    }
}

extension ReportRecord: Hashable {
    func hash(into h: inout Hasher) { h.combine(id) }
}
