import GRDB
import SwiftUI

/// The bell at the top right of every tab, with the unread count.
struct InboxButton: View {
    let env: AppEnvironment
    @State private var unread = 0
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Image(systemName: unread > 0 ? "bell.badge" : "bell")
                .overlay(alignment: .topTrailing) {
                    if unread > 0 {
                        Text(unread > 99 ? "99+" : "\(unread)")
                            .font(.caption2.bold()).monospacedDigit().foregroundStyle(.white)
                            .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                            .background(.red, in: .capsule)
                            .offset(x: 10, y: -8)
                            .accessibilityIdentifier("inbox.badge")
                    }
                }
        }
        .accessibilityLabel(unread > 0 ? "Notifications, \(unread) unread" : "Notifications")
        .accessibilityIdentifier("inbox.button")
        .sheet(isPresented: $open) { NavigationStack { InboxView(env: env) } }
        .task {
            let obs = ValueObservation.tracking { try InboxStore.unread($0) }.removeDuplicates()
            do { for try await n in obs.values(in: env.db.writer) { unread = n } } catch {}
        }
    }
}

extension View {
    /// Adds the inbox bell to a tab's navigation bar.
    func inboxToolbar(_ env: AppEnvironment) -> some View {
        toolbar { ToolbarItem(placement: .topBarTrailing) { InboxButton(env: env) } }
    }
}

struct InboxView: View {
    let env: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [InboxMessage] = []
    @State private var selection = Set<Int64>()
    @State private var editMode: EditMode = .inactive
    @State private var deleteAfterRead = false

    private var editing: Bool { editMode.isEditing }

    var body: some View {
        List(selection: $selection) {
            if messages.isEmpty {
                ContentUnavailableView("No notifications", systemImage: "bell.slash",
                                       description: Text("Wind-down reminders, answers, monitor alerts and reports appear here."))
                    .listRowBackground(Color.clear)
            }
            ForEach(messages) { m in
                NavigationLink { InboxDetailView(env: env, message: m) } label: { row(m) }
                    .tag(m.id)
                    .accessibilityIdentifier("inbox.row.\(m.identifier)")
                    .swipeActions(edge: .leading) {
                        Button(m.isRead ? "Unread" : "Read") {
                            Task { m.isRead ? await env.inbox.markUnread([m.id]) : await env.inbox.markRead([m.id]) }
                        }
                        .tint(.blue)
                    }
            }
            .onDelete { idx in
                let ids = idx.map { messages[$0].id }
                Task { await env.inbox.delete(ids) }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(editing ? "Cancel" : "Select") {
                    withAnimation { editMode = editing ? .inactive : .active }
                    selection = []
                }
                .disabled(messages.isEmpty && !editing)
                .accessibilityIdentifier("inbox.select")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !editing {
                    Menu {
                        Button("Mark all as read", systemImage: "envelope.open") { Task { await env.inbox.markAllRead() } }
                        Button("Delete read messages", systemImage: "trash", role: .destructive) {
                            Task { await env.inbox.deleteRead() }
                        }
                        Toggle("Delete after reading", isOn: $deleteAfterRead)
                    } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityIdentifier("inbox.menu")
                }
            }
            if editing {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(selection.count == messages.count ? "Deselect all" : "Select all") {
                        selection = selection.count == messages.count ? [] : Set(messages.map(\.id))
                    }
                    .accessibilityIdentifier("inbox.selectAll")
                    Spacer()
                    Button("Mark read") { let ids = Array(selection); selection = []; Task { await env.inbox.markRead(ids) } }
                        .disabled(selection.isEmpty)
                    Button("Delete (\(selection.count))", role: .destructive) {
                        let ids = Array(selection)
                        selection = []
                        Task {
                            await env.inbox.delete(ids)
                            editMode = .inactive
                        }
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("inbox.deleteSelected")
                }
            }
        }
        .onChange(of: deleteAfterRead) { _, on in env.inbox.setDeleteAfterRead(on) }
        .task {
            deleteAfterRead = env.inbox.deleteAfterRead
            await env.inbox.ingestDelivered()
            let obs = ValueObservation.tracking { try InboxStore.fetchAll($0) }.removeDuplicates()
            do { for try await m in obs.values(in: env.db.writer) { messages = m } } catch {}
        }
    }

    private func row(_ m: InboxMessage) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(m.isRead ? .clear : .blue).frame(width: 8, height: 8).padding(.top, 6)
            Image(systemName: Self.icon(m.kind)).foregroundStyle(m.kind == "monitor" ? .red : .secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(m.title).font(.subheadline.weight(m.isRead ? .regular : .semibold)).lineLimit(1)
                    Spacer()
                    Text(ago(m.ts, now: env.clock.now)).font(.caption2).foregroundStyle(.secondary)
                }
                Text(m.body).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "wind_down": "moon.zzz"
        case "monitor": "waveform.path.ecg"
        case "answer": "bubble.left"
        case "report": "doc.richtext"
        case "system": "gear"
        default: "bell"
        }
    }
}

struct InboxDetailView: View {
    let env: AppEnvironment
    let message: InboxMessage

    var body: some View {
        List {
            Section {
                Text(message.title).font(.headline)
                Text(Date(timeIntervalSince1970: message.ts).formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
                Text(message.body).textSelection(.enabled)
            }
            if let link = message.link, link.hasPrefix("report:"), let id = Int64(link.dropFirst(7)),
               let report = env.reports.record(id) {
                Section { NavigationLink("Open report") { ReportDetailView(env: env, report: report) } }
            }
            if env.inbox.deleteAfterRead {
                Section { Text("This message is deleted when you close it.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(InboxView.title(message.kind))
        .navigationBarTitleDisplayMode(.inline)
        // Read when the user leaves the message, so "delete after reading" doesn't pull it away mid-read.
        .onDisappear { Task { await env.inbox.markRead([message.id]) } }
    }
}

extension InboxView {
    static func title(_ kind: String) -> String {
        ["wind_down": "Wind-down", "monitor": "Health monitor", "answer": "Answer", "report": "Report",
         "system": "System"][kind] ?? "Notification"
    }
}
