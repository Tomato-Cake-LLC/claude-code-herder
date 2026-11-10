import AppKit
import SwiftUI

struct ContentView: View {
    @State private var store = SessionStore()
    @State private var query = ""
    @State private var searchMatches: Set<String>?
    @State private var isSearching = false
    @State private var period = Period()
    @State private var sortKey = SortKey.lastMessage
    @State private var sortDescending = true
    @State private var pageLimit = ContentView.pageSize
    @State private var errorMessage: String?
    @State private var cowOffer: CowOffer?
    @State private var deletingCow: String?
    @State private var showingPeriod = false
    @State private var showDone = false
    @State private var liveCowsOnly = false
    /// Non-nil while the new-session wizard is up; holds the cows it offers.
    @State private var newSessionCows: CowList?

    private static let pageSize = 40

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.border)
            content
        }
        .overlay(alignment: .bottomTrailing) { newSessionButton.padding(28) }
        .background(Theme.background)
        .preferredColorScheme(.light)
        .task { await store.reload() }
        .task {
            // Tabs open and close while the app is up, so keep checking.
            while !Task.isCancelled {
                await store.refreshOpenSessions()
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await store.reload() }
        }
        .task(id: query) { await runSearch() }
        .onChange(of: filterKey) { pageLimit = Self.pageSize }
        .alert(
            cowOffer.map { "Delete the \($0.status.root.lastPathComponent) cow?" } ?? "",
            isPresented: Binding(get: { cowOffer != nil }, set: { if !$0 { cowOffer = nil } }),
            presenting: cowOffer
        ) { offer in
            Button("Delete cow", role: .destructive) { deleteCow(offer.status.root) }
            Button("Keep", role: .cancel) {}
        } message: { offer in
            Text(offer.message)
        }
        .sheet(item: $newSessionCows) { cows in
            NewSessionWizard(cows: cows.urls, onStart: startSession)
        }
        .alert("Something went wrong", isPresented: .constant(errorMessage != nil)) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Spark(size: 22)
            Text("Claude Code Herder")
                .font(Theme.serif(26))
                .foregroundStyle(Theme.ink)
                .fixedSize()

            Spacer(minLength: 24)

            searchField.frame(maxWidth: 360)
            periodButton
            FilterChip(label: "✓ Show done", isOn: $showDone)
                .help("Also show sessions marked as done")
            FilterChip(label: "🐮 Active", isOn: $liveCowsOnly)
                .help("Sessions whose cow checkout still exists")
            sortMenu

            Button {
                Task { await store.reload() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.secondary)
            .keyboardShortcut("r")
            .help("Reload sessions (⌘R)")
            .disabled(store.isLoading)
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)  // clears the traffic lights over the hidden title bar
        .padding(.bottom, 16)
    }

    private var newSessionButton: some View {
        Button(action: showNewSession) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Theme.ink, in: Circle())
                .shadow(color: Theme.ink.opacity(0.25), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n")
        .help("New session (⌘N)")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.tertiary)
            TextField("Search transcripts…", text: $query)
                .textFieldStyle(.plain)
                .foregroundStyle(Theme.ink)
            if isSearching {
                ProgressView().controlSize(.small)
            } else if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 14))
        .outlinedControl()
    }

    private var periodButton: some View {
        Button {
            showingPeriod.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text(period.label).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.ink)
            .outlinedControl()
        }
        .buttonStyle(.plain)
        .disabled(ignoresPeriod)
        .opacity(ignoresPeriod ? 0.45 : 1)
        .help(ignoresPeriod ? "Active cow sessions show regardless of period" : "")
        .popover(isPresented: $showingPeriod, arrowEdge: .bottom) {
            PeriodPicker(period: $period)
        }
    }

    private var sortMenu: some View {
        HStack(spacing: 0) {
            Menu {
                Picker("Sort by", selection: $sortKey) {
                    ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(sortKey.rawValue).font(.system(size: 13)).fixedSize()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                sortDescending.toggle()
            } label: {
                Image(systemName: sortDescending ? "arrow.down" : "arrow.up")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .help(sortDescending ? "Newest / largest first" : "Oldest / smallest first")
        }
        .foregroundStyle(Theme.ink)
        .outlinedControl()
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let sessions = visibleSessions
        if !store.hasLoaded {
            centered { ProgressView("Reading transcripts…") }
        } else if sessions.isEmpty {
            centered {
                Text(emptyMessage)
                    .font(Theme.serif(18))
                    .foregroundStyle(Theme.secondary)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryLine(count: sessions.count)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 380), spacing: 18)], spacing: 18
                    ) {
                        ForEach(sessions.prefix(pageLimit)) { session in
                            let folder = store.folderStates[session.id] ?? .missing
                            let recreation =
                                folder == .missing ? NewSession.recreation(of: session) : nil
                            SessionCard(
                                session: session,
                                folder: folder,
                                isDone: store.done.isDone(session),
                                isOpen: store.openPIDs[session.id] != nil,
                                onOpen: { open(session) },
                                onFork: { fork(session) },
                                recreation: recreation,
                                onRecreate: { recreation.map(recreate) },
                                onToggleDone: {
                                    withAnimation(.easeInOut(duration: 0.35)) {
                                        store.toggleDone(session)
                                    }
                                    finish(session)
                                }
                            )
                            .transition(.opacity.combined(with: .scale(scale: 0.92)))
                        }
                    }
                    if sessions.count > pageLimit {
                        // Infinite scroll: reaching the end loads the next page. The id makes
                        // onAppear fire again if the sentinel is still on screen afterwards.
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .id(pageLimit)
                            .onAppear { pageLimit += Self.pageSize }
                    }
                }
                .padding(28)
            }
        }
    }

    private func summaryLine(count: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(count) sessions")
            if let cost = totalCost {
                Text("·")
                Text(cost.formatted(.currency(code: "USD")))
            }
            if let deletingCow {
                Text("·")
                Text("Deleting the \(deletingCow) cow…")
            }
            if !store.failures.isEmpty {
                Text("·")
                Button("\(store.failures.count) files failed to load") {
                    errorMessage = store.failures.map { "\($0.path)\n\($0.message)" }
                        .joined(separator: "\n\n")
                }
                .buttonStyle(.link)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Theme.tertiary)
    }

    private func centered(@ViewBuilder _ inner: () -> some View) -> some View {
        inner().frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Logic

    /// Live cows are browsed as a whole, so their age doesn't matter.
    private var ignoresPeriod: Bool {
        liveCowsOnly
    }

    private func isVisible(_ session: Session) -> Bool {
        if !showDone && store.done.isDone(session) {
            return false
        }
        if liveCowsOnly && store.folderStates[session.id] != .liveCow {
            return false
        }
        if !ignoresPeriod && !period.contains(session) {
            return false
        }
        return searchMatches?.contains(session.id) ?? true
    }

    private var emptyMessage: String {
        if !query.isEmpty {
            return "No sessions match “\(query)”."
        }
        let scope = ignoresPeriod ? "here" : "in this period"
        return showDone ? "No sessions \(scope)." : "Nothing left to do \(scope)."
    }

    private var visibleSessions: [Session] {
        store.sessions
            .filter(isVisible)
            .sorted { sortDescending ? sortKey.ascending($1, $0) : sortKey.ascending($0, $1) }
    }

    private var totalCost: Double? {
        let costs = visibleSessions.compactMap(\.costUSD)
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }

    /// Anything that changes which sessions show resets the scroll page.
    private var filterKey: [AnyHashable] {
        [query, period.label, sortKey, sortDescending, showDone, liveCowsOnly]
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            searchMatches = nil
            return
        }
        // Debounce typing; a newer query cancels this task.
        do {
            try await Task.sleep(for: .milliseconds(250))
        } catch {
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let ids = try await TranscriptSearch.sessionIDs(
                matching: trimmed, in: SessionIndexer.projectsRoot)
            guard !Task.isCancelled else {
                return
            }
            searchMatches = ids
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A session just marked done: close its tab, then maybe offer to delete its cow.
    private func finish(_ session: Session) {
        guard store.done.isDone(session) else {
            return
        }
        Task {
            do {
                if let pid = store.openPIDs[session.id] {
                    try await Ghostty.close(pid: pid)
                    await store.refreshOpenSessions()
                }
                try await offerCowCleanup(after: session)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Once every session in a cow is done, offer to free its disk space.
    private func offerCowCleanup(after session: Session) async throws {
        guard let cwd = session.cwd, let root = Cows.root(containing: cwd) else {
            return
        }
        let inCow = Cows.sessions(in: root, among: store.sessions)
        guard inCow.allSatisfy(store.done.isDone) else {
            return
        }
        let running = inCow.filter { store.openPIDs[$0.id] != nil }.count
        cowOffer = CowOffer(status: try await Cows.status(of: root), runningSessions: running)
    }

    private func deleteCow(_ root: URL) {
        deletingCow = root.lastPathComponent
        Task {
            do {
                try await Cows.delete(root)
                await store.reload()
            } catch {
                errorMessage = error.localizedDescription
            }
            deletingCow = nil
        }
    }

    private func showNewSession() {
        do {
            newSessionCows = CowList(urls: try NewSession.cows(of: NewSession.repo))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startSession(_ workspace: Workspace, name: String, prompt: String) {
        Task {
            do {
                try await NewSession.start(workspace, name: name, prompt: prompt)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func recreate(_ recreation: Recreation) {
        Task {
            do {
                try await NewSession.recreate(recreation)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func fork(_ session: Session) {
        guard let cwd = session.cwd else {
            return
        }
        Task {
            do {
                try await ForkApp.open(cwd)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Jumps to the session's tab if it's already running, else resumes it in a new one.
    private func open(_ session: Session) {
        let pid = store.openPIDs[session.id]
        let cwd = session.cwd
        Task {
            do {
                if let pid {
                    try await Ghostty.focus(pid: pid)
                } else if let cwd {
                    try await Ghostty.resume(sessionID: session.id, in: cwd)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct PeriodPicker: View {
    @Binding var period: Period

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(PeriodPreset.allCases.filter { $0 != .custom }) { preset in
                    Button {
                        period.preset = preset
                    } label: {
                        HStack {
                            Text(preset.rawValue)
                            Spacer()
                            if period.preset == preset {
                                Image(systemName: "checkmark").foregroundStyle(Theme.clay)
                            }
                        }
                        .frame(width: 130)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
            .font(.system(size: 13))
            Divider()
            // Picking any date switches to a custom range.
            calendar("From", selection: $period.customStart)
            calendar("To", selection: $period.customEnd)
        }
        .padding(16)
    }

    private func calendar(_ title: String, selection: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.secondary)
            DatePicker(
                title,
                selection: Binding(
                    get: { selection.wrappedValue },
                    set: {
                        selection.wrappedValue = $0
                        period.preset = .custom
                    }),
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
        }
    }
}

private struct FilterChip: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(isOn ? .white : Theme.ink)
                .fixedSize()
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isOn ? Theme.ink : Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(isOn ? Theme.ink : Theme.border))
        }
        .buttonStyle(.plain)
    }
}

/// The prompt shown once the last session in a cow is marked done.
private struct CowOffer {
    let status: Cows.Status
    let runningSessions: Int

    var message: String {
        var lines = [
            "All its sessions are done.",
            "\(status.root.path) (branch \(status.branch))",
        ]
        var warnings: [String] = []
        if status.uncommittedFiles > 0 {
            warnings.append("⚠️ \(status.uncommittedFiles) uncommitted file(s) will be lost")
        }
        if status.unpushedCommits > 0 {
            warnings.append("⚠️ \(status.unpushedCommits) commit(s) not pushed anywhere will be lost")
        }
        if runningSessions > 0 {
            warnings.append("⚠️ \(runningSessions) session(s) still running there; close the tab first")
        }
        lines.append(warnings.isEmpty ? "Everything is committed and pushed." : warnings.joined(separator: "\n"))
        return lines.joined(separator: "\n\n")
    }
}

/// The cows the new-session wizard offers, taken when it opens.
private struct CowList: Identifiable {
    let id = UUID()
    let urls: [URL]
}
