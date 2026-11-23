import SwiftUI
import CrestaCore

enum Tool: String, Hashable, CaseIterable, Identifiable {
    case lastLight, goNoGo, backpack, garage, importHub, stats, wrapped, heatmap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastLight: return "Ultima Luce"
        case .goNoGo: return "Go/No-Go"
        case .backpack: return "Zaino"
        case .garage: return "Garage"
        case .importHub: return "Importa"
        case .stats: return "Statistiche"
        case .wrapped: return "Riepilogo dell'anno"
        case .heatmap: return "Mappa di calore"
        }
    }

    var subtitle: String {
        switch self {
        case .lastLight: return "Tramonto, buio e ora limite per rientrare"
        case .goNoGo: return "Valanghe, meteo, vento: si parte?"
        case .backpack: return "Checklist per ogni tipo di uscita"
        case .garage: return "Sci, scarpe e bici: manutenzione e km"
        case .importHub: return "Archivio Strava, file GPX/FIT/TCX, sincronizzazione"
        case .stats: return "Numeri di stagione"
        case .wrapped: return "Il tuo anno in montagna"
        case .heatmap: return "Tutte le tue tracce su una mappa"
        }
    }

    var icon: String {
        switch self {
        case .lastLight: return "sunset.fill"
        case .goNoGo: return "gauge.with.dots.needle.67percent"
        case .backpack: return "backpack.fill"
        case .garage: return "wrench.and.screwdriver.fill"
        case .importHub: return "square.and.arrow.down.fill"
        case .stats: return "chart.bar.fill"
        case .wrapped: return "sparkles"
        case .heatmap: return "flame.fill"
        }
    }

    var colorHex: String {
        switch self {
        case .lastLight: return "#e65100"
        case .goNoGo: return "#2e7d32"
        case .backpack: return "#6d4c41"
        case .garage: return "#1565c0"
        case .importHub: return "#fc4c02"
        case .stats: return "#00838f"
        case .wrapped: return "#6a1b9a"
        case .heatmap: return "#d84315"
        }
    }

    @MainActor @ViewBuilder var destination: some View {
        switch self {
        case .lastLight: LastLightView()
        case .goNoGo: GoNoGoView()
        case .backpack: BackpackListView()
        case .garage: GarageView()
        case .importHub: ImportHubView()
        case .stats: StatsView()
        case .wrapped: WrappedView()
        case .heatmap: HeatmapView()
        }
    }
}

struct ToolsView: View {
    @Environment(AppModel.self) private var model

    private var tools: [Tool] {
        model.seasonKind == .winter
            ? [.goNoGo, .garage, .backpack, .lastLight, .stats, .heatmap, .importHub, .wrapped]
            : [.lastLight, .backpack, .goNoGo, .stats, .heatmap, .garage, .importHub, .wrapped]
    }

    var body: some View {
        ScreenScroll {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(Array(tools.enumerated()), id: \.element) { i, t in
                    NavigationLink(value: t) { ToolTile(tool: t, big: i == 0) }
                        .buttonStyle(PressableStyle())
                }
            }
            .animation(.m3Spatial, value: tools)
        }
        .navigationTitle("Strumenti")
        .navigationDestination(for: Tool.self) { $0.destination }
        .navigationDestination(for: UUID.self) { OutingDetailView(outingID: $0) }
    }
}

struct ToolTile: View {
    @Environment(\.m3) private var m3
    let tool: Tool
    var big = false

    var body: some View {
        let t = m3.tones(tool.colorHex)
        VStack(alignment: .leading, spacing: 10) {
            IconBadge(icon: tool.icon, tones: t, size: big ? 60 : 50, cookie: big, filled: big)
            Spacer(minLength: 0)
            Text(tool.title).font(.m3TitleMedium).foregroundStyle(t.onContainer)
            Text(tool.subtitle).font(.m3BodySmall).foregroundStyle(t.onContainer.opacity(0.8)).lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .leading)
        .background(t.container, in: RoundedRectangle(cornerRadius: big ? 36 : 26, style: .continuous))
    }
}

/// Shortcut card used on the home screen.
struct ToolLinkCard: View {
    @Environment(\.m3) private var m3
    let tool: Tool

    var body: some View {
        let t = m3.tones(tool.colorHex)
        NavigationLink(value: tool) {
            HStack(spacing: 14) {
                IconBadge(icon: tool.icon, tones: t, size: 52, filled: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tool.title).font(.m3TitleMedium).foregroundStyle(t.onContainer)
                    Text(tool.subtitle).font(.m3BodySmall).foregroundStyle(t.onContainer.opacity(0.8))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(t.onContainer)
            }
            .padding(16)
            .background(t.container, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}
