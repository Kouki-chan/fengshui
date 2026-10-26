import Foundation

/// Runs the report tools for the assistant. When the Report tab started the request,
/// `forced` holds the user's filter (period and labels), which wins over the model's arguments.
struct ReportActions: AssistantActions {
    let store: ReportStore
    var forced: ReportRequest?

    func run(name: String, inputJSON: Data) async throws -> AssistantActionResult? {
        let input = (try JSONSerialization.jsonObject(with: inputJSON)) as? [String: Any] ?? [:]
        switch name {
        case "propose_report_labels":
            let labels = (input["labels"] as? [String] ?? []).filter { !$0.isEmpty }
            return AssistantActionResult(output: "Proposed \(labels.count) labels; the user will review them.",
                                         proposedLabels: labels)
        case "create_report":
            var req = ReportRequest(title: (input["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Health report",
                                    startDate: String((input["start"] as? String ?? "").prefix(10)),
                                    endDate: String((input["end"] as? String ?? "").prefix(10)),
                                    labels: input["labels"] as? [String] ?? [],
                                    summary: input["summary"] as? String)
            if let f = forced {
                req.startDate = f.startDate
                req.endDate = f.endDate
                req.labels = f.labels
                req.purpose = f.purpose
                if !f.title.isEmpty { req.title = f.title }
            }
            guard !req.labels.isEmpty else { throw ClaudeTools.ToolError(description: "choose at least one label") }
            let r = try await store.create(req)
            return AssistantActionResult(output: "Created report \(r.id): \(r.pages) pages, \(r.labels.count) labels, "
                                             + "\(r.startDate) to \(r.endDate).", reportID: r.id)
        default:
            return nil
        }
    }
}

/// The Report tab's two AI steps (DECISIONS D-20).
enum ReportPrompts {
    static func suggest(start: String, end: String, purpose: String) -> String {
        """
        The user is preparing a PDF report for a health professional covering \(start) to \(end).
        Purpose: \(purpose.isEmpty ? "a general overview of their health data" : purpose).
        Call list_report_labels for this period. Then choose every label that is appropriate for this purpose and \
        has enough data to be useful, and call propose_report_labels with them and a short reason for each. Prefer \
        clinically meaningful data (vitals, sleep, activity, Apple's heart events). Leave out labels that don't bear on \
        the purpose. Reply with one sentence when done.
        """
    }

    static func create(_ r: ReportRequest) -> String {
        """
        Create the PDF report now. Period: \(r.startDate) to \(r.endDate). Purpose: \(r.purpose ?? "general overview"). \
        Use exactly these labels: \(r.labels.joined(separator: ", ")).
        First look at the data you need with the tools (get_series with a daily bucket, get_sleep_nights, \
        get_inferences). Then write the summary for a clinician in plain text with short paragraphs or "- " bullets: \
        what data is included and how complete it is, averages and ranges with units, trends over the period, notable \
        values or events, and gaps. Be factual and neutral and don't diagnose. Then call create_report with these \
        labels and dates.
        """
    }
}
