import SwiftUI

struct QuickOpenView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var workspace: Workspace
    @ObservedObject var sourceControl: GitSourceControlStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var files: [GitQuickOpenFile] = []
    @State private var error: String?
    @State private var busy = true

    private var filtered: [GitQuickOpenFile] {
        guard !query.isEmpty else { return Array(files.prefix(200)) }
        return files.filter { Self.matches(query.lowercased(), in: $0.path.lowercased()) }.prefix(200).map { $0 }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Quick Open files…", text: $query).textFieldStyle(.plain).font(.system(size: 15))
                if busy { ProgressView().controlSize(.small) }
            }.padding(12).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            if let error {
                ContentUnavailableView(
                    "Unable to Read Files", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if filtered.isEmpty {
                ContentUnavailableView(
                    query.isEmpty ? "No Files" : "No Matches", systemImage: "doc",
                    description: Text("Search files in this Git repository."))
            } else {
                List(filtered) { file in
                    quickOpenRow(file)
                }.listStyle(.plain)
            }
            HStack {
                Text("\(URL(fileURLWithPath: session.repository?.root ?? "").lastPathComponent) · \(files.count) files")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16).frame(width: 620, height: 540).preferredColorScheme(.dark)
        .task { await load() }
    }

    private func load() async {
        guard let root = session.repository?.root else {
            busy = false; error = "This terminal is not inside a Git repository."; return
        }
        let result = await Task.detached { Result { try GitRepository.quickOpenFiles(at: root) } }.value
        busy = false
        switch result {
        case .success(let value): files = value
        case .failure(let failure): error = failure.localizedDescription
        }
    }

    private func open(_ file: GitQuickOpenFile) {
        guard let root = session.repository?.root else { return }
        if file.status != nil {
            sourceControl.selectRepository(root)
            sourceControl.selectedReviewPath = file.path
            dismiss()
            workspace.showReview(for: session)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: root).appendingPathComponent(file.path))
            dismiss()
        }
    }

    private func quickOpenRow(_ file: GitQuickOpenFile) -> some View {
        let iconName = file.status == nil ? "doc" : "doc.badge.ellipsis"
        let iconColor: Color = file.status == nil ? .secondary : .orange
        return Button {
            open(file)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: iconName).foregroundStyle(iconColor)
                Text(file.path).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let status = file.status { GitStatusBadge(status: status) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain).contextMenu {
            Button("Open in Default App", systemImage: "arrow.up.forward.square") { openInDefaultApp(file) }
            Button("Reveal in Finder", systemImage: "folder") { reveal(file) }
            if file.status != nil {
                Button("Review Changes", systemImage: "doc.text.magnifyingglass") { review(file) }
            }
        }
    }

    private func openInDefaultApp(_ file: GitQuickOpenFile) {
        guard let root = session.repository?.root else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: root).appendingPathComponent(file.path)); dismiss()
    }
    private func reveal(_ file: GitQuickOpenFile) {
        guard let root = session.repository?.root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: root).appendingPathComponent(file.path)])
    }
    private func review(_ file: GitQuickOpenFile) {
        guard file.status != nil, let root = session.repository?.root else { return }
        sourceControl.selectRepository(root); sourceControl.selectedReviewPath = file.path
        dismiss(); workspace.showReview(for: session)
    }

    private static func matches(_ query: String, in value: String) -> Bool {
        if value.contains(query) { return true }
        var next = query.startIndex
        for character in value where character == query[next] {
            next = query.index(after: next)
            if next == query.endIndex { return true }
        }
        return false
    }
}
