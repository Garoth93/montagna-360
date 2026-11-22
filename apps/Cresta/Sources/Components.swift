import SwiftUI
import UniformTypeIdentifiers
import CrestaCore

// MARK: - Surfaces

/// Material 3 card: tonal surface, large continuous corners.
struct M3Card<Content: View>: View {
    @Environment(\.m3) private var m3
    var color: Color?
    var padding: CGFloat
    var corner: CGFloat
    let content: Content

    init(color: Color? = nil, padding: CGFloat = 18, corner: CGFloat = 28, @ViewBuilder content: () -> Content) {
        self.color = color
        self.padding = padding
        self.corner = corner
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color ?? m3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}

struct SectionTitle: View {
    @Environment(\.m3) private var m3
    let title: String
    var trailing: String?

    init(_ title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.m3TitleLarge).foregroundStyle(m3.onSurface)
            Spacer()
            if let trailing {
                Text(trailing).font(.m3LabelMedium).foregroundStyle(m3.onSurfaceVariant)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
    }
}

/// Screen background + scrolling column used by most screens.
struct ScreenScroll<Content: View>: View {
    @Environment(\.m3) private var m3
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
        }
        .background(m3.surface)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Buttons

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct PillButton: View {
    let title: String
    let icon: String
    let tones: Tones
    var filled = true
    var height: CGFloat = 56
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                Text(title).font(.m3TitleMedium)
            }
            .foregroundStyle(filled ? tones.onAccent : tones.onContainer)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(filled ? tones.accent : tones.container, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
    }
}

struct Chip: View {
    @Environment(\.m3) private var m3
    let title: String
    var icon: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                }
                Text(title).font(.m3LabelLarge)
            }
            .padding(.horizontal, 14)
            .frame(height: 36)
            .foregroundStyle(selected ? m3.onSecondaryContainer : m3.onSurfaceVariant)
            .background(selected ? m3.secondaryContainer : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(selected ? Color.clear : m3.outlineVariant, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(.m3Effects, value: selected)
    }
}

/// Two-option segmented "connected button group" (M3 Expressive).
struct SegmentedPills<T: Hashable>: View {
    @Environment(\.m3) private var m3
    let options: [(T, String, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                let on = o.0 == selection
                Button {
                    withAnimation(.m3Spatial) { selection = o.0 }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: o.2).font(.system(size: 14, weight: .semibold))
                        Text(o.1).font(.m3LabelLarge)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(on ? m3.onPrimary : m3.onSurfaceVariant)
                    .background(on ? m3.primary : m3.surfaceContainerHigh,
                                in: RoundedRectangle(cornerRadius: on ? 22 : 10, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
        }
    }
}

// MARK: - Toast

struct Toast: Identifiable, Equatable {
    enum Style { case success, info, error }
    let id = UUID()
    let message: String
    let icon: String
    let style: Style
}

struct ToastView: View {
    @Environment(\.m3) private var m3
    let toast: Toast

    var body: some View {
        let tones: Tones = {
            switch toast.style {
            case .success: return m3.successTones
            case .info: return m3.neutral
            case .error: return m3.errorTones
            }
        }()
        HStack(spacing: 10) {
            Image(systemName: toast.icon).font(.system(size: 15, weight: .bold))
            Text(toast.message).font(.m3LabelLarge)
        }
        .foregroundStyle(tones.onContainer)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(tones.container, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @Environment(\.m3) private var m3
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            IconBadge(icon: icon, tones: m3.primaryTones, size: 88, cookie: true)
            Text(title).font(.m3TitleLarge).foregroundStyle(m3.onSurface)
            Text(message).font(.m3BodyMedium).foregroundStyle(m3.onSurfaceVariant).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

// MARK: - Data pieces

struct StatTile: View {
    @Environment(\.m3) private var m3
    let value: String
    let label: String
    var icon: String?
    var tones: Tones?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tones?.accent ?? m3.primary)
            }
            Text(value)
                .font(.m3TitleLarge)
                .foregroundStyle(tones?.onContainer ?? m3.onSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            Text(label).font(.m3LabelMedium).foregroundStyle(m3.onSurfaceVariant).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tones?.container ?? m3.surfaceContainer, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct TagLabel: View {
    let text: String
    let icon: String?
    let tones: Tones

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.m3LabelSmall)
        }
        .foregroundStyle(tones.onContainer)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tones.container, in: Capsule())
    }
}

/// Linear progress in M3 style (thick, rounded, with a gap).
struct M3Progress: View {
    @Environment(\.m3) private var m3
    let value: Double
    var tones: Tones?
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { g in
            let w = max(0, min(1, value)) * g.size.width
            HStack(spacing: 4) {
                Capsule().fill(tones?.accent ?? m3.primary).frame(width: max(height, w))
                Capsule().fill(tones?.container ?? m3.secondaryContainer)
            }
            .animation(.m3Spatial, value: value)
        }
        .frame(height: height)
    }
}

/// Circular score gauge 0…10 (Go/No-Go).
struct ScoreGauge: View {
    @Environment(\.m3) private var m3
    let score: Double
    let tones: Tones
    var size: CGFloat = 180

    var body: some View {
        ZStack {
            CookieShape(lobes: 12, depth: 0.04).fill(tones.container)
            Circle()
                .trim(from: 0, to: score / 10)
                .stroke(tones.accent, style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(size * 0.12)
                .animation(.m3Spatial, value: score)
            VStack(spacing: 0) {
                Text(Format.number(score, decimals: 1))
                    .font(.system(size: size * 0.3, weight: .heavy, design: .rounded))
                    .contentTransition(.numericText(value: score))
                Text("su 10").font(.m3LabelMedium)
            }
            .foregroundStyle(tones.onContainer)
        }
        .frame(width: size, height: size)
    }
}

/// Outing row in lists.
struct OutingRow: View {
    @Environment(\.m3) private var m3
    let outing: Outing

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(icon: outing.kind.icon, tones: m3.tones(for: outing.kind), size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(outing.name).font(.m3TitleSmall).foregroundStyle(m3.onSurface).lineLimit(1)
                Text(detail).font(.m3BodySmall).foregroundStyle(m3.onSurfaceVariant).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 0) {
                Text(outing.stats.ascent > 0 ? "+\(Int(outing.stats.ascent))" : Format.km(outing.stats.distance))
                    .font(.m3TitleMedium).foregroundStyle(m3.onSurface)
                Text(outing.stats.ascent > 0 ? "m D+" : "").font(.m3LabelSmall).foregroundStyle(m3.onSurfaceVariant)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(m3.surfaceContainerLow, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var detail: String {
        var parts = [Format.dayMonthYear(outing.start)]
        if outing.stats.distance > 0 { parts.append(Format.km(outing.stats.distance)) }
        if outing.stats.moving > 0 { parts.append(Format.duration(outing.stats.moving)) }
        return parts.joined(separator: " · ")
    }
}

/// Weather line with icon.
struct WeatherLabel: View {
    @Environment(\.m3) private var m3
    let weather: WeatherSnapshot

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: weather.icon).symbolRenderingMode(.multicolor).font(.system(size: 18))
            Text(weather.summary).font(.m3BodyMedium).foregroundStyle(m3.onSurface)
        }
    }
}

/// Plain file wrapper for `fileExporter` (backup JSON, GPX).
struct DataFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip, .json, .xml, .plainText] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension Date {
    var timeLabel: String { Format.time(self) }
}
