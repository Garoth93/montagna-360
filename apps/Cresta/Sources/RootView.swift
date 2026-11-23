import SwiftUI
import CrestaCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(CloudBackupService.self) private var cloud
    @Environment(\.m3) private var m3

    var body: some View {
        @Bindable var model = model
        @Bindable var cloud = cloud
        TabView(selection: $model.tab) {
            Tab("Oggi", systemImage: model.seasonKind == .winter ? "snowflake" : "sun.max.fill", value: AppTab.home) {
                NavigationStack { HomeView() }
            }
            Tab("Diario", systemImage: "book.pages.fill", value: AppTab.diary) {
                NavigationStack { DiaryView() }
            }
            Tab("Cime", systemImage: "mountain.2.fill", value: AppTab.peaks) {
                NavigationStack { PeaksView() }
            }
            Tab("Strumenti", systemImage: "square.grid.2x2.fill", value: AppTab.tools) {
                NavigationStack(path: $model.toolsPath) { ToolsView() }
            }
            Tab("Impostazioni", systemImage: "gearshape.fill", value: AppTab.settings) {
                NavigationStack { SettingsView() }
            }
        }
        .sheet(item: $model.exportSession, onDismiss: { model.closeExport() }) { _ in
            ExportImportSheet()
                .presentationDetents([.large])
                .presentationCornerRadius(32)
                .interactiveDismissDisabled(model.importJob?.phase == .running)
        }
        .sheet(isPresented: Binding(
            get: { model.importJob != nil && model.exportSession == nil },
            set: { if !$0 && model.importJob?.phase != .running { model.importJob = nil } }
        )) {
            ImportProgressSheet()
                .presentationDetents([.medium])
                .presentationCornerRadius(32)
                .interactiveDismissDisabled(model.importJob?.phase == .running)
        }
        .sheet(isPresented: Binding(
            get: { cloud.offerRestore && model.data.onboardingDone && model.exportSession == nil && model.importJob == nil },
            set: { if !$0 { cloud.offerRestore = false } }
        )) {
            CloudRestoreView(firstLaunch: true).presentationCornerRadius(32)
        }
        .fullScreenCover(isPresented: Binding(
            get: { model.isLoaded && !model.data.onboardingDone },
            set: { _ in }
        )) {
            OnboardingView()
        }
        .alert("Attenzione", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { model.toast = nil }
            }
        }
        .animation(.m3Spatial, value: model.toast)
    }
}

/// First launch: three short pages.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.m3) private var m3
    @State private var page = 0

    private let pages: [(String, String, String)] = [
        ("mountain.2.fill", "Benvenuto in Cresta", "Il diario delle tue giornate in montagna, d'estate e d'inverno: uscite, cime, statistiche."),
        ("square.and.arrow.down.fill", "Porta il tuo storico", "Importa l'archivio di Strava o singoli file GPX, FIT e TCX. Le vette raggiunte vengono timbrate da sole."),
        ("checkmark.shield.fill", "Pronto a partire", "Ultima Luce, Go/No-Go, zaino e garage degli sci. Tutto funziona anche offline e resta sul telefono.")
    ]

    var body: some View {
        VStack(spacing: 24) {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                    VStack(spacing: 22) {
                        Spacer()
                        IconBadge(icon: p.0, tones: m3.primaryTones, size: 140, cookie: true, filled: i == 0)
                            .symbolEffect(.bounce, value: page)
                        Text(p.1).font(.m3HeadlineLarge).multilineTextAlignment(.center).foregroundStyle(m3.onSurface)
                        Text(p.2).font(.m3BodyLarge).multilineTextAlignment(.center).foregroundStyle(m3.onSurfaceVariant)
                            .padding(.horizontal, 32)
                        Spacer()
                    }
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            PillButton(title: page < pages.count - 1 ? "Avanti" : "Inizia", icon: page < pages.count - 1 ? "arrow.right" : "checkmark",
                       tones: m3.primaryTones) {
                if page < pages.count - 1 {
                    withAnimation(.m3Spatial) { page += 1 }
                } else {
                    model.mutate { $0.onboardingDone = true }
                    Task { _ = await Notifier.requestAuthorization() }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(m3.surface)
    }
}
