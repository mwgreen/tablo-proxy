import SwiftUI

/// Small capsule tag: REC, SAVED, SAVING 42%…
struct Badge: View {
    let text: String
    let color: Color

    init(_ text: String, _ color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.9), in: Capsule())
            .foregroundStyle(.white)
    }
}

struct RecBadge: View {
    var body: some View { Badge("REC", .red) }
}

/// A red/amber dot for the guide grid's schedule state.
struct RecordDot: View {
    let mark: AppStore.RecordMark

    var body: some View {
        switch mark {
        case .notScheduled:
            EmptyView()
        case .scheduled:
            Image(systemName: "circle.fill").foregroundStyle(.red)
        case .recordingNow:
            Image(systemName: "record.circle.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "circle").foregroundStyle(.orange)
        }
    }
}

/// Flat, size-preserving button style for dense grids (the system card
/// style enlarges and pads, which breaks the guide's time alignment).
struct GuideCellStyle: ButtonStyle {
    enum Kind { case program, onNow, channel }
    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        CellBody(configuration: configuration, kind: kind)
    }

    private struct CellBody: View {
        let configuration: ButtonStyle.Configuration
        let kind: Kind
        @Environment(\.isFocused) private var focused

        private var fill: Color {
            switch kind {
            case .program: return Color.white.opacity(0.10)
            case .onNow: return Color.blue.opacity(0.35)
            case .channel: return Color.white.opacity(0.06)
            }
        }

        var body: some View {
            configuration.label
                .foregroundStyle(focused ? Color.black : Color.white)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(focused ? Color.white : fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(focused ? 0 : 0.10), lineWidth: 1)
                )
                .padding(2)
                .animation(.easeOut(duration: 0.12), value: focused)
        }
    }
}

/// The toast that AppStore.showToast raises.
struct ToastView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if let t = store.toast {
            Text(t)
                .font(.callout)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 40)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Top banner when the proxy can't be reached, with a retry.
struct ErrorBanner: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if let e = store.lastError {
            HStack(spacing: 20) {
                Image(systemName: "wifi.exclamationmark")
                Text(e).lineLimit(2)
                Button("Retry") { Task { await store.loadAll() } }
            }
            .font(.callout)
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
            .padding(.top, 20)
        }
    }
}
