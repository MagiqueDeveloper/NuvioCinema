import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct NuvioSettingsView: View {
    let account: NuvioAccount

    @Environment(CinemaTitleNavigation.self) private var titles
    @State private var path: [Page] = []
    @State private var watchlistRouteID: UUID?
    @FocusState private var focusedWatchlistItem: NuvioLibraryItem.ID?
    @FocusState private var linkFocus: LinkAction?

    private enum Page: Hashable {
        case account, profiles, unlockProfile(Int), addons, watchlist, progress, history
    }

    private enum LinkAction: Hashable {
        case link, cancel
    }

    private var currentProfile: NuvioProfile? {
        account.profiles.first { $0.id == account.profileID }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    Text("Settings")
                        .font(.system(size: 56, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)

                    if account.isSignedIn {
                        connectedAccount
                        accountMessages
                        destinations
                    } else {
                        linkAccount
                        accountMessages
                    }

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
                }
                .padding(.vertical, 36)
                .padding(.horizontal, 34)
                .frame(maxWidth: 1460)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.hidden)
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
                }
            }
        }
        .onChange(of: account.isSignedIn) { _, signedIn in
            if !signedIn {
                path.removeAll()
                linkFocus = .link
            }
        }
        .onChange(of: account.profileID) { _, _ in
            if let watchlistRouteID { titles.dismiss(id: watchlistRouteID) }
            watchlistRouteID = nil
        }
    }

    @ViewBuilder
    private var accountMessages: some View {
        if let message = account.message {
            Text(message)
                .font(.system(size: 23))
                .foregroundStyle(.secondary)
        }
        if let message = account.sessionStorageMessage {
            Text(message)
                .font(.system(size: 23))
                .foregroundStyle(.secondary)
        }
        if !account.failedSyncSections.isEmpty {
            let names = account.failedSyncSections.map(\.name).formatted(.list(type: .and))
            Text("Couldn’t update \(names). Select Sync Now to retry.")
                .font(.system(size: 23))
                .foregroundStyle(.secondary)
        }
        if account.playbackUploadFailed {
            Text("Playback updates couldn’t sync. Select Sync Now to retry.")
                .font(.system(size: 23))
                .foregroundStyle(.secondary)
        } else if account.pendingPlaybackCount > 0 {
            Text("Playback updates pending.")
                .font(.system(size: 23))
                .foregroundStyle(.secondary)
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
        HStack(alignment: .center, spacing: 24) {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 48, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text(currentProfile?.name ?? account.profileAwaitingPIN?.name ?? String(localized: "Nuvio Account"))
                    .font(.system(size: 32, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)

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

            if let profile = account.profileAwaitingPIN {
                NavigationLink(value: Page.unlockProfile(profile.id)) {
                    Label("Unlock Profile", systemImage: "lock")
                }
                .buttonStyle(.borderedProminent)
            }
            Button(action: account.sync) {
                Label("Sync Now", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(account.isSyncing)
        }
        .settingsPanel()
        .focusSection()
    }

    @ViewBuilder
    private var syncStatus: some View {
        if account.isSyncing {
            Text("Updating Nuvio data…")
        } else if account.profileAwaitingPIN != nil {
            Text("Unlock your profile or choose another in Profiles.")
        } else if let date = account.lastSync {
            Text("Last synced \(date, format: .dateTime.month(.abbreviated).day().hour().minute())")
        } else {
            Text("Connected to Nuvio")
        }
    }

    private var destinations: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 22), count: 3)
        return LazyVGrid(columns: columns, spacing: 22) {
            destination("Profiles", symbol: "person.2", page: .profiles)
            destination("Add-ons", symbol: "puzzlepiece.extension", page: .addons, count: account.addons.count)
            destination("Watchlist", symbol: "bookmark", page: .watchlist, count: account.watchlist.count)
            destination("Continue Watching", symbol: "play.rectangle", page: .progress, count: account.inProgress.count)
            destination("Watch History", symbol: "clock.arrow.circlepath", page: .history, count: account.history.count)
            destination("Account", symbol: "person.crop.circle", page: .account)
        }
        .focusSection()
    }

    private func destination(
        _ title: LocalizedStringKey,
        symbol: String,
        page: Page,
        count: Int? = nil
    ) -> some View {
        NavigationLink(value: page) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 29, weight: .medium))
                        .accessibilityHidden(true)
                    Spacer()
                    if let count {
                        Text(count.formatted())
                            .font(.system(size: 20, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(title)
                    .font(.system(size: 25, weight: .semibold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 17)
        }
        .buttonStyle(.card)
    }

    private var profiles: some View {
        List {
            if account.profiles.isEmpty {
                Text("No Nuvio profiles available.")
                    .foregroundStyle(.secondary)
            }

            ForEach(account.profiles, id: \.id) { profile in
                if profile.isLocked && profile.id != account.profileID {
                    NavigationLink(value: Page.unlockProfile(profile.id)) {
                        profileRow(profile)
                    }
                } else {
                    Button {
                        account.selectProfile(profile.id)
                    } label: {
                        profileRow(profile)
                    }
                    .disabled(account.isSyncing && profile.id != account.profileID)
                }
            }
        }
        .navigationTitle("Profiles")
    }

    private func profileRow(_ profile: NuvioProfile) -> some View {
        settingsRow("Profile", symbol: "person.crop.circle", name: profile.name) {
            if profile.id == account.profileID {
                Label("Current", systemImage: "checkmark")
            } else if profile.isLocked {
                Label("Locked", systemImage: "lock")
            }
        }
    }

    private var addons: some View {
        List {
            if account.addons.isEmpty {
                Text("No synced add-ons.")
                    .foregroundStyle(.secondary)
            }

            ForEach(account.addons, id: \.id) { addon in
                settingsRow("Add-on", symbol: "puzzlepiece.extension", name: addon.name) {
                    Text(addon.enabled ? "Enabled" : "Disabled")
                }
                .accessibilityElement(children: .combine)
                .focusable()
            }
        }
        .navigationTitle("Add-ons")
    }

    private var watchlist: some View {
        List {
            if account.watchlist.isEmpty {
                Text("No synced watchlist items.")
                    .foregroundStyle(.secondary)
            }

            ForEach(account.watchlist, id: \.id) { entry in
                if let kind = CinemetaKind(rawValue: entry.contentType) {
                    Button {
                        openWatchlistTitle(entry, kind: kind)
                    } label: {
                        watchlistRow(entry)
                    }
                    .focused($focusedWatchlistItem, equals: entry.id)
                } else {
                    watchlistRow(entry)
                        .focusable()
                }
            }
        }
        .navigationTitle("Watchlist")
    }

    private func openWatchlistTitle(_ entry: NuvioLibraryItem, kind: CinemetaKind) {
        guard titles.screens.isEmpty else { return }
        let profileID = account.profileID
        watchlistRouteID = titles.show(onDismiss: {
            watchlistRouteID = nil
            if account.profileID == profileID { focusedWatchlistItem = entry.id }
        }) { close in
            NuvioWatchlistTitle(entry: entry, kind: kind, onDismiss: close)
        }
    }

    private func watchlistRow(_ entry: NuvioLibraryItem) -> some View {
        settingsRow("Title", symbol: "bookmark", name: entry.title) {
            Text(entry.addedAt, format: .dateTime.month(.abbreviated).day().year())
        }
        .accessibilityElement(children: .combine)
    }

    private var progress: some View {
        List {
            if account.inProgress.isEmpty {
                Text("No synced titles in progress.")
                    .foregroundStyle(.secondary)
            }

            ForEach(account.inProgress, id: \.id) { entry in
                VStack(alignment: .leading, spacing: 10) {
                    settingsRow("Title", symbol: "play.rectangle", name: account.title(for: entry)) {
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
                .accessibilityElement(children: .combine)
                .focusable()
            }
        }
        .navigationTitle("Continue Watching")
    }

    private var history: some View {
        List {
            if account.history.isEmpty {
                Text("No synced watch history.")
                    .foregroundStyle(.secondary)
            }

            ForEach(account.history, id: \.id) { entry in
                VStack(alignment: .leading, spacing: 10) {
                    settingsRow("Title", symbol: "clock.arrow.circlepath", name: entry.title) {
                        Text(entry.watchedAt, format: .dateTime.month(.abbreviated).day().year())
                    }
                    if let season = entry.season, let episode = entry.episode {
                        Text("Season \(season), Episode \(episode)")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .focusable()
            }
        }
        .navigationTitle("Watch History")
    }

    private func settingsRow<Status: View>(
        _ title: LocalizedStringKey,
        symbol: String,
        name: String? = nil,
        @ViewBuilder status: () -> Status
    ) -> some View {
        HStack(spacing: 20) {
            Label {
                if let name, !name.isEmpty {
                    Text(name)
                } else {
                    Text(title)
                }
            } icon: {
                Image(systemName: symbol)
            }
            Spacer(minLength: 20)
            status()
                .foregroundStyle(.secondary)
        }
    }
}

private struct NuvioWatchlistTitle: View {
    let entry: NuvioLibraryItem
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
                Text(entry.title)
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
                let loaded = await CinemetaClient().details(contentID: entry.contentID, kind: kind)
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

            Button("Sign Out", role: .destructive) {
                confirmsSignOut = true
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
