import SwiftUI

@main
struct NuvioCinemaApp: App {
    #if NUVIO_UPSTREAM_PLAYER
    init() {
        SubtitleFontLibrary.prepareAtLaunch()
    }
    #endif

    var body: some Scene {
        WindowGroup {
            CinemaTabs()
                .preferredColorScheme(.dark)
        }
    }
}

struct CinemaTabs: View {
    private enum Page: Hashable {
        case home, search, settings
    }

    @State private var selection: Page = .home
    @State private var heroCarousel = HeroCarousel()
    @State private var heroScroll = HomeHeroScroll()
    @State private var account = NuvioAccount()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selection) {
            Tab("Home", systemImage: "house", value: .home) {
                TabPage(isSelected: selection == .home) {
                    HomeView(
                        isActive: selection == .home,
                        carousel: $heroCarousel,
                        heroScroll: heroScroll
                    )
                }
            }
            Tab("Search", systemImage: "magnifyingglass", value: .search) {
                TabPage(isSelected: selection == .search) {
                    CinemetaSearchView(isActive: selection == .search, account: account)
                }
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                TabPage(isSelected: selection == .settings) {
                    NuvioSettingsView(account: account)
                }
            }
        }
        .tabViewStyle(.tabBarOnly)
        #if NUVIO_UPSTREAM_PLAYER
        .modifier(CinemaTopShelf(account: account))
        #endif
        .environment(account)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                account.syncIfNeeded()
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
            }
        }
        .onChange(of: selection) { _, page in
            if page == .home || page == .settings { account.syncIfNeeded() }
            if page != .settings { account.cancelLink() }
        }
        .background {
            ZStack {
                CinemaStyle.background.ignoresSafeArea()
                if selection == .home {
                    HomeHeroBackdrop(carousel: heroCarousel, heroScroll: heroScroll)
                }
            }
        }
    }
}

private struct TabPage<Content: View>: View {
    private static var revealAnimation: Animation {
        .timingCurve(0.16, 0.84, 0.32, 1, duration: 0.28)
    }

    let isSelected: Bool
    @ViewBuilder let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isRevealed = false

    var body: some View {
        content
            .opacity(isRevealed || reduceMotion ? 1 : 0.52)
            .onAppear { updateReveal(isSelected) }
            .onChange(of: isSelected) { _, selected in updateReveal(selected) }
            .onDisappear { updateReveal(false) }
    }

    private func updateReveal(_ selected: Bool) {
        // The outgoing tab can leave immediately, so only animate the incoming page.
        withAnimation(selected && !reduceMotion ? Self.revealAnimation : nil) {
            isRevealed = selected
        }
    }
}
