import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct NuvioSettingsView: View {
    let account: NuvioAccount

    @Environment(CinemaTitleNavigation.self) private var titles
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var path: [Page] = []
    @State private var libraryRouteID: UUID?
    @State private var switchingProfileID: Int?
    @FocusState private var focusedLibraryItem: String?
    @FocusState private var linkFocus: LinkAction?
    @FocusState private var sidebarFocus: Category?
    @State private var category: Category = .account

    private enum Page: Hashable {
        case account, profiles, unlockProfile(Int), addons, watchlist, progress, history, acknowledgements
    }

    private enum Category: Hashable, CaseIterable {
        case account, playback, storage, diagnostics, about

        static var visible: [Category] {
            #if NUVIO_UPSTREAM_PLAYER
            allCases
            #else
            allCases.filter { $0 != .playback }
            #endif
        }

        var title: LocalizedStringKey {
            switch self {
            case .account: "Account"
            case .playback: "Playback"
            case .storage: "Storage & Cache"
            case .diagnostics: "Diagnostics"
            case .about: "About"
            }
        }

        var symbol: String {
            switch self {
            case .account: "person.crop.circle"
            case .playback: "play.rectangle"
            case .storage: "internaldrive"
            case .diagnostics: "stethoscope"
            case .about: "info.circle"
            }
        }
    }

    private enum LinkAction: Hashable {
        case link, cancel
    }

    private var currentProfile: NuvioProfile? {
        account.profiles.first { $0.id == account.profileID }
    }

    var body: some View {
        NavigationStack(path: $path) {
            HStack(alignment: .top, spacing: 56) {
                sidebar
                ScrollView {
                    detail
                        // The extra top inset lines the section title up with the sidebar's larger title.
                        .padding(.top, 50)
                        .padding(.bottom, 36)
                        .padding(.trailing, 34)
                        .frame(maxWidth: 1180, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .focusSection()
                // A fresh scroll view per category starts each page at the top.
                .id(category)
                .transition(.opacity)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: category)
            .padding(.leading, 34)
            .navigationDestination(for: Page.self) { page in
                switch page {
                case .account: NuvioAccountSettings(account: account)
                case .profiles: profiles
                case .unlockProfile(let id):
                    if let profile = account.profiles.first(where: { $0.id == id }) {
                        NuvioProfileUnlock(account: account, profile: profile)
                    } else {
                        Text("This profile is unavailable.")
                            .foregroundStyle(.secondary)
                            .navigationTitle("Unlock Profile")
                    }
                case .addons: addons
                case .watchlist: watchlist
                case .progress: progress
                case .history: history
                case .acknowledgements: CinemaAcknowledgements()
                }
            }
        }
        .onChange(of: sidebarFocus) { previous, focused in
            guard let focused else { return }
            if previous == nil, focused != category {
                // Entering from the page lands on the current category, not the nearest row.
                sidebarFocus = category
            } else {
                // Like tvOS Settings, moving through the sidebar shows each category.
                category = focused
            }
        }
        .onChange(of: account.isSignedIn) { _, signedIn in
            if !signedIn {
                path.removeAll()
                category = .account
                linkFocus = .link
            }
        }
        .onChange(of: account.profileID) { _, _ in
            if let libraryRouteID { titles.dismiss(id: libraryRouteID) }
            libraryRouteID = nil
        }
        .onChange(of: account.isSyncing) { _, syncing in
            // A profile switch finishes with its sync. On success, return to the Settings page.
            guard !syncing, let switched = switchingProfileID else { return }
            switchingProfileID = nil
            if account.profileID == switched, account.message == nil, path.last == .profiles {
                path.removeAll()
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .font(.system(size: 56, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 22)

            ForEach(Category.visible, id: \.self) { item in
                let isFocused = sidebarFocus == item
                Button {
                    category = item
                } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(isFocused ? Color.black : Color.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 26)
                        .frame(height: 70)
                        .background(isFocused ? Color.white : (category == item ? Color.white.opacity(0.12) : .clear),
                                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(SettingsSidebarButtonStyle())
                .focusEffectDisabled()
                .focused($sidebarFocus, equals: item)
                .scaleEffect(isFocused ? 1.03 : 1)
                .animation(.easeOut(duration: 0.14), value: isFocused)
                .accessibilityAddTraits(category == item ? .isSelected : [])
            }

            Spacer(minLength: 24)

            Text("Nuvio Cinema \(AppVersion.display)")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 26)
                .padding(.bottom, 44)
        }
        .frame(width: 420, alignment: .leading)
        .padding(.top, 36)
        // Span the full height so Left from any row on the page reaches the sidebar,
        // not only from rows level with the categories.
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .focusSection()
        // Coming back from the page, land on the current category rather than the nearest row.
        .defaultFocus($sidebarFocus, category, priority: .userInitiated)
    }

    @ViewBuilder
    private var detail: some View {
        switch category {
        case .account: accountSection
        case .playback:
            #if NUVIO_UPSTREAM_PLAYER
            // Each profile keeps its own player settings, so rebuild against the current profile's store.
            CinemaPlaybackSettings()
                .id(account.profileID)
            #else
            EmptyView()
            #endif
        case .storage: CinemaStorageSettings()
        case .diagnostics: diagnostics
        case .about: about
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            sectionTitle("Account")
            if account.isSignedIn {
                connectedAccount
                accountNoticeBanner
                destinations
            } else {
                linkAccount
                accountNoticeBanner
            }
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 40, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Diagnostics

    @State private var homeRefreshRequested = false

    private var hasSyncFailure: Bool {
        !account.failedSyncSections.isEmpty || account.playbackUploadFailed
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 32) {
            sectionTitle("Diagnostics")

            VStack(alignment: .leading, spacing: 18) {
                Label("Nuvio Sync", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 28, weight: .semibold))
                if account.isSignedIn {
                    infoRow("Status") { syncStatus }
                    infoRow("Profiles") { Text(account.profiles.count.formatted()) }
                    infoRow("Add-ons") { Text(account.addons.count.formatted()) }
                    infoRow("Pending Playback Updates") {
                        if account.playbackUploadFailed {
                            Text("\(account.pendingPlaybackCount.formatted()) · Couldn’t sync")
                        } else {
                            Text(account.pendingPlaybackCount.formatted())
                        }
                    }
                    if !account.failedSyncSections.isEmpty {
                        infoRow("Couldn’t Update") {
                            Text(account.failedSyncSections.map(\.name).formatted(.list(type: .and)))
                        }
                    }
                    if hasSyncFailure {
                        syncButton(idleTitle: "Retry Sync", symbol: "exclamationmark.arrow.circlepath")
                            .padding(.top, 6)
                    }
                } else {
                    infoRow("Status") { Text("Not linked") }
                }
            }
            .settingsPanel()
            .focusSection()

            VStack(alignment: .leading, spacing: 18) {
                Label("Catalogs", systemImage: "square.grid.2x2")
                    .font(.system(size: 28, weight: .semibold))
                Text("Reload Home’s rows now instead of waiting for the hourly refresh. Saved title details are cleared so everything is fetched fresh.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    Button {
                        Task {
                            await CinemaMetadataCache.shared.removeAll()
                            NotificationCenter.default.post(name: .cinemaRefreshHome, object: nil)
                            homeRefreshRequested = true
                        }
                    } label: {
                        Label("Refresh Home", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    if homeRefreshRequested {
                        Label {
                            Text("Home will refresh when you open it.")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .font(.system(size: 21))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: homeRefreshRequested)
            }
            .settingsPanel()
            .focusSection()
        }
        .onAppear { homeRefreshRequested = false }
    }

    // MARK: About

    private var about: some View {
        VStack(alignment: .leading, spacing: 32) {
            sectionTitle("About")

            VStack(alignment: .leading, spacing: 18) {
                Text("Nuvio Cinema")
                    .font(.system(size: 30, weight: .semibold))
                infoRow("Version") { Text(AppVersion.display) }
                #if NUVIO_UPSTREAM_PLAYER
                infoRow("Player") { Text("Nuvio Player") }
                #else
                infoRow("Player") { Text("Built-in Player (Legacy)") }
                #endif
                infoRow("tvOS") { Text(UIDevice.current.systemVersion) }
                infoRow("Device") { Text(UIDevice.current.model) }
                #if NUVIO_UPSTREAM_PLAYER
                infoRow("Top Shelf") {
                    Text(TopShelfSigningCheck.installedIssue == nil ? "Available" : "Unavailable")
                }
                #endif
            }
            .settingsPanel()

            #if NUVIO_UPSTREAM_PLAYER
            if let issue = TopShelfSigningCheck.installedIssue {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Top Shelf Unavailable", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 26, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(issue.message)
                        .font(.system(size: 23))
                        .foregroundStyle(.secondary)
                }
                .settingsPanel()
            }
            #endif

            if !CinemaAcknowledgements.notices.isEmpty {
                NavigationLink(value: Page.acknowledgements) {
                    Label("Acknowledgements", systemImage: "doc.text")
                }
                .buttonStyle(.bordered)
            }
        }
        .focusSection()
    }

    private func infoRow<Value: View>(_ title: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(title)
            Spacer(minLength: 24)
            value()
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 23))
        .accessibilityElement(children: .combine)
    }

    // MARK: Account

    /// Problems and pending work to surface under the account header, most important first.
    private var accountNotices: [String] {
        var notices: [String] = []
        if let message = account.message { notices.append(message) }
        if let message = account.sessionStorageMessage { notices.append(message) }
        if account.isSignedIn, !account.failedSyncSections.isEmpty {
            let names = account.failedSyncSections.map(\.name).formatted(.list(type: .and))
            notices.append(String(localized: "Couldn’t update \(names). Select Sync Now to retry."))
        }
        if account.playbackUploadFailed {
            notices.append(String(localized: "Playback updates couldn’t sync. Select Sync Now to retry."))
        } else if account.pendingPlaybackCount > 0 {
            notices.append(String(localized: "Playback updates pending."))
        }
        return notices
    }

    @ViewBuilder
    private var accountNoticeBanner: some View {
        let notices = accountNotices
        if !notices.isEmpty {
            // Only pending playback is informational; everything else needs attention.
            let isWarning = account.message != nil || account.sessionStorageMessage != nil || hasSyncFailure
            let tint: Color = isWarning ? .yellow : .white
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(notices, id: \.self) { Text($0) }
                }
            }
            .font(.system(size: 23, weight: .medium))
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(isWarning ? 0.13 : 0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(tint.opacity(isWarning ? 0.3 : 0.12))
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var linkAccount: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let pairing = account.pairing {
                NuvioPairingInstructions(pairing: pairing)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Nuvio Account", systemImage: "person.crop.circle")
                        .font(.system(size: 34, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Sync your profiles, add-ons, watchlist, and watch history from Nuvio.")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                }
            }

            if account.isLinking {
                HStack(spacing: 24) {
                    Button("Cancel") {
                        account.cancelLink()
                        linkFocus = .link
                    }
                    .buttonStyle(.bordered)
                    .focused($linkFocus, equals: .cancel)
                    ProgressView(account.pairing == nil ? "Getting a code…" : "Waiting for you to link your account…")
                        .font(.system(size: 22))
                }
            } else {
                Button {
                    account.beginLink()
                    linkFocus = account.isLinking ? .cancel : .link
                } label: {
                    Label(account.message == nil ? "Link Nuvio Account" : "Try Again", systemImage: "link")
                }
                .buttonStyle(.borderedProminent)
                .focused($linkFocus, equals: .link)
            }
        }
        .settingsPanel()
        .focusSection()
        .onChange(of: account.isLinking) { _, linking in
            if !linking, linkFocus == .cancel { linkFocus = .link }
        }
    }

    private var connectedAccount: some View {
        let profileName = currentProfile?.name ?? account.profileAwaitingPIN?.name ?? String(localized: "Nuvio Account")
        return HStack(alignment: .center, spacing: 24) {
            // The whole profile card opens the account page, where you can also sign out.
            NavigationLink(value: Page.account) {
                HStack(alignment: .center, spacing: 26) {
                    ProfileMonogram(name: profileName, id: currentProfile?.id ?? account.profileAwaitingPIN?.id, size: 88)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(profileName)
                            .font(.system(size: 32, weight: .semibold))
                            .lineLimit(1)
                        if let email = account.email {
                            Text(email)
                                .font(.system(size: 22))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        syncStatus
                            .font(.system(size: 21))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 24)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
            .buttonStyle(.card)
            .accessibilityHint("Shows account details and Sign Out.")

            VStack(alignment: .leading, spacing: 18) {
                if let profile = account.profileAwaitingPIN {
                    NavigationLink(value: Page.unlockProfile(profile.id)) {
                        Label("Unlock Profile", systemImage: "lock")
                    }
                    .buttonStyle(.borderedProminent)
                }
                syncButton(idleTitle: "Sync Now", symbol: "arrow.clockwise")
            }
        }
        .focusSection()
    }

    /// Stays focusable while syncing so focus doesn't jump away; `sync()` ignores repeat presses.
    private func syncButton(idleTitle: LocalizedStringKey, symbol: String) -> some View {
        Button(action: account.sync) {
            if account.isSyncing {
                HStack(spacing: 14) {
                    ProgressView()
                    Text("Syncing…")
                }
            } else {
                Label(idleTitle, systemImage: symbol)
            }
        }
        .buttonStyle(.bordered)
        .accessibilityValue(account.isSyncing ? Text("Syncing") : Text(""))
    }

    private var syncStatus: some View {
        // Refresh periodically so "just now" ages into minutes without another sync.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if account.isSyncing {
                Text("Updating Nuvio data…")
            } else if account.profileAwaitingPIN != nil {
                Text("Unlock your profile or choose another in Profiles.")
            } else if let date = account.lastSync {
                let age = context.date.timeIntervalSince(date)
                if age < 60 {
                    Text("Synced just now")
                } else if age < 3_600 {
                    Text("Synced \(date, format: .relative(presentation: .named))")
                } else {
                    Text("Last synced \(date, format: .dateTime.month(.abbreviated).day().hour().minute())")
                }
            } else {
                Text("Connected to Nuvio")
            }
        }
    }

    private var destinations: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 22), count: 3)
        let enabledAddons = account.addons.filter(\.enabled).count
        let latestWatch = account.history.map(\.watchedAt).max()
        return LazyVGrid(columns: columns, spacing: 22) {
            destination("Profiles", symbol: "person.2", page: .profiles) {
                if let currentProfile {
                    Text(currentProfile.name)
                } else if account.profileAwaitingPIN != nil {
                    Text("Locked")
                } else {
                    Text("^[\(account.profiles.count) profile](inflect: true)")
                }
            }
            destination("Add-ons", symbol: "puzzlepiece.extension", page: .addons) {
                Text("\(enabledAddons) of \(account.addons.count) enabled")
            }
            destination("Watchlist", symbol: "bookmark", page: .watchlist) {
                Text("^[\(account.watchlist.count) title](inflect: true)")
            }
            destination("Continue Watching", symbol: "play.rectangle", page: .progress) {
                Text("\(account.inProgress.count) in progress")
            }
            destination("Watch History", symbol: "clock.arrow.circlepath", page: .history) {
                if let latestWatch {
                    Text("\(account.history.count) watched · \(latestWatch, format: .dateTime.month(.abbreviated).day())")
                } else {
                    Text("Nothing watched yet")
                }
            }
        }
        .focusSection()
    }

    private func destination<Detail: View>(
        _ title: LocalizedStringKey,
        symbol: String,
        page: Page,
        @ViewBuilder detail: () -> Detail
    ) -> some View {
        NavigationLink(value: page) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 29, weight: .medium))
                    .accessibilityHidden(true)
                    .padding(.bottom, 4)
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                    .lineLimit(1)
                detail()
                    .font(.system(size: 20, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .buttonStyle(.card)
    }

    // MARK: Library pages

    private var profiles: some View {
        SettingsListPage(
            title: "Profiles",
            isEmpty: account.profiles.isEmpty,
            empty: SettingsEmptyState(symbol: "person.2", title: "No Profiles",
                                      message: "Profiles you create in Nuvio appear here.")
        ) {
            ForEach(account.profiles, id: \.id) { profile in
                if profile.isLocked && profile.id != account.profileID {
                    NavigationLink(value: Page.unlockProfile(profile.id)) {
                        profileRow(profile)
                    }
                } else {
                    Button {
                        guard profile.id != account.profileID else { return }
                        switchingProfileID = profile.id
                        account.selectProfile(profile.id)
                        if account.profileID != profile.id { switchingProfileID = nil }
                    } label: {
                        profileRow(profile)
                    }
                    .disabled(account.isSyncing && profile.id != account.profileID)
                }
            }
        }
    }

    private func profileRow(_ profile: NuvioProfile) -> some View {
        HStack(spacing: 22) {
            ProfileMonogram(name: profile.name, id: profile.id, size: 52)
            Text(profile.name)
            Spacer(minLength: 20)
            Group {
                if profile.id == switchingProfileID, account.isSyncing {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Switching…")
                    }
                } else if profile.id == account.profileID {
                    Label("Current", systemImage: "checkmark")
                } else if profile.isLocked {
                    Label("Locked", systemImage: "lock")
                }
            }
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var addons: some View {
        SettingsListPage(
            title: "Add-ons",
            isEmpty: account.addons.isEmpty,
            empty: SettingsEmptyState(symbol: "puzzlepiece.extension", title: "No Add-ons",
                                      message: "Add-ons you install in Nuvio appear here.")
        ) {
            ForEach(account.addons.sorted { $0.sortOrder < $1.sortOrder }, id: \.id) { addon in
                HStack(spacing: 20) {
                    Image(systemName: "puzzlepiece.extension")
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(addon.name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Add-on"))
                        if let host = URL(string: addon.url)?.host {
                            Text(host)
                                .font(.system(size: 20))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 20)
                    HStack(spacing: 10) {
                        Circle()
                            .fill(addon.enabled ? Color.green : Color.secondary)
                            .frame(width: 12, height: 12)
                            .accessibilityHidden(true)
                        Text(addon.enabled ? "Enabled" : "Disabled")
                    }
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .focusable()
            }
        }
    }

    private var watchlist: some View {
        SettingsListPage(
            title: "Watchlist",
            isEmpty: account.watchlist.isEmpty,
            empty: SettingsEmptyState(symbol: "bookmark", title: "Your Watchlist Is Empty",
                                      message: "Titles you save in Nuvio appear here.")
        ) {
            ForEach(account.watchlist, id: \.id) { entry in
                libraryButton(id: entry.id, contentID: entry.contentID, name: entry.title, contentType: entry.contentType) {
                    libraryRow(symbol: "bookmark", name: entry.title) {
                        Text(entry.addedAt, format: .dateTime.month(.abbreviated).day().year())
                    }
                }
            }
        }
    }

    private var progress: some View {
        SettingsListPage(
            title: "Continue Watching",
            isEmpty: account.inProgress.isEmpty,
            empty: SettingsEmptyState(symbol: "play.rectangle", title: "Nothing in Progress",
                                      message: "Movies and episodes you start appear here.")
        ) {
            ForEach(account.inProgress, id: \.id) { entry in
                let name = account.title(for: entry)
                libraryButton(id: entry.id, contentID: entry.contentID, name: name, contentType: entry.contentType) {
                    VStack(alignment: .leading, spacing: 10) {
                        libraryRow(symbol: "play.rectangle", name: name) {
                            if entry.duration > 0 {
                                Text(entry.fraction.formatted(.percent.precision(.fractionLength(0))))
                            } else {
                                Text("In Progress")
                            }
                            Text(entry.updatedAt, format: .dateTime.month(.abbreviated).day().year())
                        }
                        if let season = entry.season, let episode = entry.episode {
                            Text("Season \(season), Episode \(episode)")
                                .foregroundStyle(.secondary)
                        }
                        if entry.duration > 0 {
                            ProgressView(value: entry.fraction)
                                .accessibilityHidden(true)
                        }
                    }
                }
            }
        }
    }

    /// History grouped by calendar month, newest first.
    private var historyByMonth: [(month: Date, entries: [NuvioHistory])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: account.history) { entry in
            calendar.dateInterval(of: .month, for: entry.watchedAt)?.start ?? entry.watchedAt
        }
        return groups
            .map { (month: $0.key, entries: $0.value.sorted { $0.watchedAt > $1.watchedAt }) }
            .sorted { $0.month > $1.month }
    }

    private var history: some View {
        SettingsListPage(
            title: "Watch History",
            isEmpty: account.history.isEmpty,
            empty: SettingsEmptyState(symbol: "clock.arrow.circlepath", title: "No Watch History",
                                      message: "Movies and episodes you finish appear here.")
        ) {
            ForEach(historyByMonth, id: \.month) { group in
                Section {
                    ForEach(group.entries, id: \.id) { entry in
                        libraryButton(id: entry.id, contentID: entry.contentID, name: entry.title, contentType: entry.contentType) {
                            VStack(alignment: .leading, spacing: 10) {
                                libraryRow(symbol: "clock.arrow.circlepath", name: entry.title) {
                                    Text(entry.watchedAt, format: .dateTime.month(.abbreviated).day().year())
                                }
                                if let season = entry.season, let episode = entry.episode {
                                    Text("Season \(season), Episode \(episode)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text(group.month, format: .dateTime.month(.wide).year())
                }
            }
        }
    }

    /// A library row that opens its title, or a plain focusable row when the content type isn't browsable.
    @ViewBuilder
    private func libraryButton<Label: View>(
        id: String,
        contentID: String,
        name: String,
        contentType: String,
        @ViewBuilder label: () -> Label
    ) -> some View {
        if let kind = CinemetaKind(rawValue: contentType) {
            Button {
                openTitle(contentID: contentID, name: name, kind: kind, focusID: id)
            } label: {
                label()
            }
            .focused($focusedLibraryItem, equals: id)
            .accessibilityElement(children: .combine)
        } else {
            label()
                .accessibilityElement(children: .combine)
                .focusable()
        }
    }

    private func openTitle(contentID: String, name: String, kind: CinemetaKind, focusID: String) {
        guard titles.screens.isEmpty else { return }
        let profileID = account.profileID
        libraryRouteID = titles.show(onDismiss: {
            libraryRouteID = nil
            if account.profileID == profileID { focusedLibraryItem = focusID }
        }) { close in
            NuvioLibraryTitle(contentID: contentID, name: name, kind: kind, onDismiss: close)
        }
    }

    private func libraryRow<Status: View>(
        symbol: String,
        name: String,
        @ViewBuilder status: () -> Status
    ) -> some View {
        HStack(spacing: 20) {
            Label {
                Text(name.isEmpty ? String(localized: "Title") : name)
            } icon: {
                Image(systemName: symbol)
            }
            Spacer(minLength: 20)
            status()
                .foregroundStyle(.secondary)
        }
    }
}

private enum AppVersion {
    static var display: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "–"
        let build = info["CFBundleVersion"] as? String ?? "–"
        return "\(version) (\(build))"
    }
}

/// A circular initial on a color picked from the profile id, so each profile is recognizable at a glance.
private struct ProfileMonogram: View {
    let name: String
    let id: Int?
    var size: CGFloat = 76

    private static let palette: [Color] = [
        Color(red: 0.31, green: 0.47, blue: 0.95), Color(red: 0.62, green: 0.38, blue: 0.92),
        Color(red: 0.91, green: 0.36, blue: 0.55), Color(red: 0.95, green: 0.55, blue: 0.24),
        Color(red: 0.18, green: 0.68, blue: 0.66), Color(red: 0.36, green: 0.69, blue: 0.33),
    ]

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: Circle())
            .accessibilityHidden(true)
    }

    private var initial: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?"
    }

    private var color: Color {
        guard let id else { return .gray }
        return Self.palette[((id % Self.palette.count) + Self.palette.count) % Self.palette.count]
    }
}

/// A pushed Settings list with a consistent empty state.
private struct SettingsListPage<Content: View>: View {
    let title: LocalizedStringKey
    let isEmpty: Bool
    let empty: SettingsEmptyState
    @ViewBuilder let content: Content

    var body: some View {
        Group {
            if isEmpty {
                empty
            } else {
                List { content }
            }
        }
        .navigationTitle(title)
    }
}

private struct SettingsEmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 36, weight: .semibold))
            Text(message)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct NuvioLibraryTitle: View {
    let contentID: String
    let name: String
    let kind: CinemetaKind
    let onDismiss: () -> Void

    @State private var title: CinemetaTitle?
    @State private var loadFailed = false
    @State private var loadAttempt = 0

    var body: some View {
        if let title {
            TitleDetailsView(title: title, kind: kind, onDismiss: onDismiss)
        } else {
            VStack(spacing: 24) {
                Text(name)
                    .font(.title)
                    .accessibilityAddTraits(.isHeader)
                if loadFailed {
                    Text("Couldn’t load this title.")
                        .foregroundStyle(.secondary)
                    Button("Try Again", systemImage: "arrow.clockwise") {
                        loadFailed = false
                        loadAttempt += 1
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    TitleLoadingSkeleton()
                }
                Button("Back", action: onDismiss)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { CinemaStyle.background.ignoresSafeArea() }
            .onExitCommand(perform: onDismiss)
            .task(id: loadAttempt) {
                let loaded = await CinemetaClient().details(contentID: contentID, kind: kind)
                guard !Task.isCancelled else { return }
                title = loaded
                loadFailed = loaded == nil
            }
        }
    }
}

private struct NuvioProfileUnlock: View {
    let account: NuvioAccount
    let profile: NuvioProfile

    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var submitted = false

    private var canUnlock: Bool {
        pin.utf8.count == 4 && pin.utf8.allSatisfy { (48...57).contains($0) }
            && !account.isSyncing && !account.isUnlocking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label("Enter the PIN for \(profile.name).", systemImage: "lock")
                .font(.system(size: 27, weight: .semibold))
                .foregroundStyle(.secondary)
            SecureField("Profile PIN", text: $pin)
                .keyboardType(.numberPad)
                .onSubmit(unlock)
                .disabled(account.isUnlocking)

            Button(account.isUnlocking ? "Unlocking…" : "Unlock Profile", action: unlock)
                .buttonStyle(.borderedProminent)
                .disabled(!canUnlock)

            if submitted, let message = account.message {
                Text(message)
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPanel()
        .frame(maxWidth: 740, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Unlock Profile")
        .onChange(of: account.profileID) { _, id in
            if id == profile.id { dismiss() }
        }
        .onDisappear { pin = "" }
    }

    private func unlock() {
        guard canUnlock else { return }
        submitted = true
        account.verifyProfile(profile.id, pin: pin)
        pin = ""
    }
}

private struct NuvioAccountSettings: View {
    let account: NuvioAccount

    @State private var confirmsSignOut = false

    var body: some View {
        List {
            Section("Account") {
                Label(account.email ?? "Connected", systemImage: "person.crop.circle")

                if let profile = account.profiles.first(where: { $0.id == account.profileID }) {
                    LabeledContent("Profile", value: profile.name)
                }
                if let date = account.lastSync {
                    LabeledContent("Last Sync") {
                        Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    }
                }
                if let message = account.message {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
                if let message = account.sessionStorageMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Sign Out", role: .destructive) {
                    confirmsSignOut = true
                }
            } footer: {
                Text("Signing out removes your Nuvio data from this Apple TV. You can link it again at any time.")
            }
        }
        .navigationTitle("Nuvio Account")
        .alert("Sign out of Nuvio?", isPresented: $confirmsSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive, action: account.signOut)
        }
    }
}

private extension View {
    func settingsPanel() -> some View {
        let shape = RoundedRectangle(cornerRadius: 24)
        return padding(30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.07), in: shape)
            .overlay { shape.strokeBorder(.white.opacity(0.12)) }
    }
}

private struct NuvioPairingInstructions: View {
    let pairing: NuvioPairing

    private static let context = CIContext()

    var body: some View {
        let code = qrCode
        HStack(alignment: .center, spacing: 44) {
            if let code {
                Image(decorative: code, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 232, height: 232)
                    .padding(32)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Link on your phone")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(code == nil ? "Open this address and enter the code." : "Scan the QR code or open this address and enter the code.")
                    .foregroundStyle(.secondary)
                Text(manualAddress)
                    .fontWeight(.medium)
                Text(pairing.code)
                    .font(.system(size: 62, weight: .semibold, design: .monospaced))
                    .accessibilityLabel("Link code \(pairing.code)")
                Text("Code expires at \(pairing.expiresAt, format: .dateTime.hour().minute())")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var manualAddress: String {
        let url = pairing.verificationURL
        return (url.host ?? "") + url.path
    }

    private var qrCode: CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(pairing.verificationURL.absoluteString.utf8)
        guard let output = filter.outputImage else { return nil }
        return Self.context.createCGImage(output, from: output.extent)
    }
}

/// Draws only the label, so the sidebar rows show their own white-fill focus instead of the system platter.
private struct SettingsSidebarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

private struct CinemaStorageSettings: View {
    @State private var artworkBytes: Int64?
    @State private var metadataBytes: Int64?
    @State private var confirmsClear = false
    @State private var isClearing = false
    @State private var measurement = 0
    @State private var didClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            Text("Storage & Cache")
                .font(.system(size: 40, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 18) {
                row("Artwork", bytes: artworkBytes)
                row("Titles & Details", bytes: metadataBytes)
                Divider()
                row("Total", bytes: total)
                    .fontWeight(.semibold)
            }
            .settingsPanel()

            VStack(alignment: .leading, spacing: 18) {
                Text("Clearing the cache frees space and fixes stale artwork or details. Everything downloads again as you browse. Your account, watch history, and settings aren’t affected.")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    Button(role: .destructive) {
                        confirmsClear = true
                    } label: {
                        if isClearing {
                            Label("Clearing…", systemImage: "trash")
                        } else {
                            Label("Clear Cache", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.bordered)
                    // Nothing to clear once the cache is empty.
                    .disabled(isClearing || total == 0)
                    if didClear {
                        Label {
                            Text("Cache cleared")
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        .font(.system(size: 21))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: didClear)
            }
            .settingsPanel()
        }
        .focusSection()
        .task(id: measurement) { await measure() }
        .alert("Clear the cache?", isPresented: $confirmsClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Cache", role: .destructive) { clear() }
        } message: {
            Text("Saved artwork and title details are removed and download again as you browse.")
        }
    }

    private var total: Int64? {
        guard let artworkBytes, let metadataBytes else { return nil }
        return artworkBytes + metadataBytes
    }

    private func row(_ title: LocalizedStringKey, bytes: Int64?) -> some View {
        HStack(spacing: 24) {
            Text(title)
            Spacer(minLength: 24)
            if let bytes {
                Text(bytes.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .font(.system(size: 23))
        .accessibilityElement(children: .combine)
    }

    private func measure() async {
        let sizes = await Task.detached(priority: .utility) {
            (CinemaCacheStorage.artworkDirectory.map(CinemaCacheStorage.size(of:)) ?? 0,
             CinemaCacheStorage.metadataDirectory.map(CinemaCacheStorage.size(of:)) ?? 0)
        }.value
        guard !Task.isCancelled else { return }
        artworkBytes = sizes.0
        metadataBytes = sizes.1
    }

    private func clear() {
        guard !isClearing else { return }
        isClearing = true
        Task {
            await CinemaImageCache.shared.removeAll()
            await CinemaMetadataCache.shared.removeAll()
            await CastPortraits.shared.removeAll()
            URLCache.shared.removeAllCachedResponses()
            artworkBytes = nil
            metadataBytes = nil
            isClearing = false
            didClear = true
            measurement += 1
        }
    }
}

private struct CinemaAcknowledgements: View {
    struct Notice: Identifiable, Hashable {
        let url: URL
        var id: URL { url }
        var name: String {
            url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " ")
        }
    }

    /// Third-party license and notice files bundled with the app, sorted by name.
    static let notices: [Notice] = {
        guard let resources = Bundle.main.resourceURL else { return [] }
        var files: [URL] = []
        if let folder = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: nil),
           let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) {
            for case let file as URL in enumerator where file.pathExtension == "txt" { files.append(file) }
        }
        let topLevel = (try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? []
        files += topLevel.filter { file in
            let name = file.lastPathComponent.uppercased()
            return file.pathExtension == "txt" && (name.contains("LICENSE") || name.contains("NOTICE"))
        }
        return files.map(Notice.init).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    var body: some View {
        List(Self.notices) { notice in
            NavigationLink {
                NoticeText(notice: notice)
            } label: {
                Label(notice.name, systemImage: "doc.text")
            }
        }
        .navigationTitle("Acknowledgements")
    }

    private struct NoticeText: View {
        let notice: Notice
        @State private var paragraphs: [String] = []

        var body: some View {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        // Each paragraph is focusable so the remote can scroll long licenses.
                        Text(paragraph)
                            .font(.system(size: 22, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .focusable()
                    }
                }
                .padding(48)
            }
            .navigationTitle(notice.name)
            .task {
                let url = notice.url
                let text = await Task.detached(priority: .utility) {
                    (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                }.value
                paragraphs = text.components(separatedBy: "\n\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        }
    }
}

#if NUVIO_UPSTREAM_PLAYER
/// Player preferences, stored in the player's own per-profile settings so it picks them up directly.
private struct CinemaPlaybackSettings: View {
    @AppStorage(SettingsKey.autoPlayNext, store: ProfileSettings.current) private var autoPlayNext = true
    @AppStorage(SettingsKey.autoPlayNextCountdown, store: ProfileSettings.current) private var countdown = 10
    @AppStorage(SettingsKey.autoSkipIntro, store: ProfileSettings.current) private var skipIntro = false
    @AppStorage(SettingsKey.autoSkipRecap, store: ProfileSettings.current) private var skipRecap = false
    @AppStorage(SettingsKey.autoSkipOutro, store: ProfileSettings.current) private var skipCredits = false
    @AppStorage(SettingsKey.audioLanguage, store: ProfileSettings.current) private var audioLanguage = "System"
    @AppStorage(SettingsKey.forcedSubtitles, store: ProfileSettings.current) private var forcedSubtitles = true
    @State private var subtitleLanguage = SubtitleLanguagePreferences.orderedFromDefaults().first ?? "System"

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            Text("Playback")
                .font(.system(size: 40, weight: .semibold))
                .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 14) {
                Text("Episodes")
                    .font(.system(size: 28, weight: .semibold))
                Toggle("Auto-Play Next Episode", isOn: $autoPlayNext)
                if autoPlayNext {
                    Picker("Countdown", selection: $countdown) {
                        ForEach([5, 10, 15, 30], id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .settingsPanel()

            VStack(alignment: .leading, spacing: 14) {
                Text("Skip Automatically")
                    .font(.system(size: 28, weight: .semibold))
                Toggle("Intro", isOn: $skipIntro)
                Toggle("Recap", isOn: $skipRecap)
                Toggle("Credits", isOn: $skipCredits)
            }
            .settingsPanel()

            VStack(alignment: .leading, spacing: 14) {
                Text("Languages")
                    .font(.system(size: 28, weight: .semibold))
                Picker("Audio", selection: $audioLanguage) {
                    ForEach(SubtitleLanguagePreferences.audioSettingsOptions, id: \.self) { language in
                        Text(language).tag(language)
                    }
                }
                .pickerStyle(.menu)
                Picker("Subtitles", selection: subtitleSelection) {
                    ForEach(SubtitleLanguagePreferences.settingsOptions, id: \.self) { language in
                        Text(language).tag(language)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Forced Subtitles", isOn: $forcedSubtitles)
            }
            .settingsPanel()
        }
        .focusSection()
    }

    /// Writes a single subtitle language the same way the player's own settings do.
    private var subtitleSelection: Binding<String> {
        Binding(
            get: { subtitleLanguage },
            set: { language in
                subtitleLanguage = language
                let defaults = ProfileSettings.current
                let ordered = language == "System" ? [] : [language]
                defaults.set(SubtitleLanguagePreferences.encode(ordered), forKey: SettingsKey.subtitleLanguages)
                defaults.set(ordered.first ?? "System", forKey: SettingsKey.subtitleLanguage)
                defaults.set("None", forKey: SettingsKey.subtitleLanguageSecondary)
                defaults.set("None", forKey: SettingsKey.subtitleLanguageTertiary)
            }
        )
    }
}
#endif
