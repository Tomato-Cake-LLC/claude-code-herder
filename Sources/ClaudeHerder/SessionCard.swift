import AppKit
import SwiftUI

struct SessionCard: View {
    let session: Session
    let folder: FolderState
    let isDone: Bool
    /// Running in a terminal tab right now, so opening it again would make a duplicate.
    let isOpen: Bool
    let onOpen: () -> Void
    let onFork: () -> Void
    /// Set when the deleted folder was a cow that `cow` can clone again.
    let recreation: Recreation?
    let onRecreate: () -> Void
    let onToggleDone: () -> Void

    @State private var isHovered = false
    @State private var justCopied = false
    /// The pause between ticking ✓ and the card going away; clicking ✓ again cancels it.
    @State private var finishing: Task<Void, Never>?

    static let height: CGFloat = 244

    private static let exactDateStyle = Date.FormatStyle()
        .weekday(.abbreviated).month(.abbreviated).day().hour().minute()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if folder == .liveCow {
                    Text("🐮").help("Its cow checkout still exists")
                }
                Text(session.projectName.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(folder == .missing ? Theme.deletedRed : Theme.secondary)
                    .lineLimit(1)
                    .help(folder == .missing ? "Folder deleted; copy the ID to continue it elsewhere" : "")
            }
            .frame(height: 16)
            .padding(.trailing, 24)  // room for the star overlay

            Text(InlineMarkdown.render(session.title))
                .font(Theme.serif(20, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Fills what the title leaves (about 4 lines); overflow fades out instead of "…".
            // An overlay on flexible space, so long text can't grow the card.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    summary.fixedSize(horizontal: false, vertical: true)
                }
                .clipped()
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 22)
                    }
                }

            VStack(alignment: .leading, spacing: 3) {
                // Re-render each minute so "a few min ago" doesn't go stale.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(HumanTime.span(from: session.firstAt, to: session.lastAt, now: context.date))
                }
                .help(exactSpan)
                Text(stats)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.tertiary)
            .opacity(isHovered ? 0 : 1)  // the session ID takes this spot on hover
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.height)  // every row lines up
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay { if isHovered { hoverActions } }
        // Above the dimming, so marking done still works while hovered.
        .overlay(alignment: .topTrailing) {
            doneButton.frame(height: 16).padding(20)
        }
        // Clicking anywhere opens; the buttons above handle their own clicks.
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            if canOpen {
                onOpen()
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(borderColor, lineWidth: isOpen ? 2 : 1)
        )
        .shadow(color: Theme.ink.opacity(isHovered ? 0.08 : 0), radius: 12, y: 4)
        .opacity(isLeaving ? 0.4 : 1)
        .scaleEffect(isLeaving ? 0.97 : 1)
        .animation(.easeInOut(duration: 0.8), value: isLeaving)
        .offset(y: isHovered ? -2 : 0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
    }

    /// A running session can always be jumped to; resuming one needs its folder.
    private var canOpen: Bool {
        isOpen || (folder != .missing && session.cwd != nil)
    }

    /// Dims the card, shows Open in the middle and the session ID bottom-left.
    private var hoverActions: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 14).fill(Theme.dim)
            HStack(spacing: 8) {
                if folder != .missing && session.cwd != nil {
                    Button(action: onFork) {
                        HStack(spacing: 4) {
                            Text("Fork")
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .help("Review the changes in Fork")
                }
                if canOpen {
                    Button(action: onOpen) {
                        HStack(spacing: 4) {
                            Text(isOpen ? "Go to tab" : "Open")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    .help(isOpen ? "Already running; jump to its tab" : "claude --resume in \(session.cwd ?? "")")
                } else if let recreation {
                    Button(action: onRecreate) {
                        HStack(spacing: 4) {
                            Text("Recreate and Open")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .buttonStyle(PillButtonStyle())
                    .help("cow \(recreation.branch), then claude --resume")
                } else {
                    Text("Folder deleted")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.deletedRed)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button(action: copyID) {
                HStack(spacing: 6) {
                    Text(session.id)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11))
                        .frame(width: 14)
                }
                .foregroundStyle(justCopied ? Theme.clay : Theme.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Copy session ID")
            .padding(20)
        }
        .transition(.opacity)
    }

    /// Always shown on done cards; otherwise only on hover, like Open.
    private var doneButton: some View {
        Button(action: toggleDone) {
            Image(systemName: looksDone ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 17))
                .foregroundStyle(Theme.doneGreen)
                .symbolEffect(.bounce, value: finishing != nil)
        }
        .buttonStyle(.plain)
        .help(looksDone ? "Mark as not done" : "Mark as done")
        .opacity(looksDone || isHovered ? 1 : 0)
    }

    private var borderColor: Color {
        if isOpen {
            return Theme.doneGreen
        }
        return isHovered ? Theme.borderStrong : Theme.border
    }

    /// Just ticked, waiting out the pause before the card goes away.
    private var isLeaving: Bool {
        finishing != nil && !isDone
    }


    private var looksDone: Bool {
        isDone || finishing != nil
    }

    /// Marking done waits a second so the tick registers before the card leaves.
    private func toggleDone() {
        if let pending = finishing {
            pending.cancel()
            finishing = nil
            return
        }
        guard !isDone else {
            onToggleDone()
            return
        }
        finishing = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return  // cancelled by a second click
            }
            onToggleDone()
            finishing = nil
        }
    }

    private func copyID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.id, forType: .string)
        justCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            justCopied = false
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let recap = session.recap {
            Text(InlineMarkdown.render(recap))
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondary)
                .lineSpacing(3)
                .lineLimit(8)  // more than fits; just bounds the layout
        } else if let prompt = session.firstPrompt {
            // No recap yet: the opening prompt is the next best description.
            Text(InlineMarkdown.render("“\(prompt)”"))
                .font(.system(size: 14).italic())
                .foregroundStyle(Theme.tertiary)
                .lineSpacing(3)
                .lineLimit(8)
        }
    }

    private var exactSpan: String {
        "\(session.firstAt.formatted(Self.exactDateStyle)) → \(session.lastAt.formatted(Self.exactDateStyle))"
    }

    private var stats: String {
        let messages = "\(session.messageCount) messages"
        guard let cost = session.costUSD else {
            return messages + " · cost unknown"
        }
        return messages + " · " + cost.formatted(.currency(code: "USD"))
    }
}
