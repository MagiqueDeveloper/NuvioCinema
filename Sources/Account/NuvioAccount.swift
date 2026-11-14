import Foundation
import Observation
import Security

struct CinemaContinueWatchingItem: Equatable, Identifiable {
    let entry: CinemetaSearchResult
    let progress: NuvioProgress

    var id: String { "\(entry.kind.rawValue):\(entry.title.imdbID ?? entry.title.id)" }

    var episode: CinemetaEpisode? {
        guard entry.kind == .series, let season = progress.season, let number = progress.episode else { return nil }
        return entry.title.episodes.first { $0.season == season && $0.episode == number }
    }

    func upcomingEpisode(at date: Date = .now) -> CinemetaEpisode? {
        guard let episode, episode.isUpcoming(at: date) else { return nil }
        return episode
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.progress == rhs.progress && lhs.entry.title.name == rhs.entry.title.name
            && lhs.entry.title.background == rhs.entry.title.background
            && lhs.entry.title.logo == rhs.entry.title.logo && lhs.episode?.name == rhs.episode?.name
            && lhs.episode?.releasedAt == rhs.episode?.releasedAt
    }
}

@MainActor
@Observable
final class NuvioAccount {
    private(set) var pairing: NuvioPairing?
    private(set) var isLinking = false
    private(set) var isSyncing = false
    private(set) var isUnlocking = false
    private(set) var message: String?
    private(set) var sessionStorageMessage: String?
    private(set) var lastSync: Date?
    private(set) var profiles: [NuvioProfile] = []
    private(set) var profileID: Int?
    private(set) var addons: [NuvioAddon] = []
    private(set) var progress: [NuvioProgress] = []
    private(set) var history: [NuvioHistory] = []
    private(set) var watchlist: [NuvioLibraryItem] = []
    private(set) var continueWatching: [CinemaContinueWatchingItem] = []

    private var session: NuvioSession?
    private var progressTitles: [String: String] = [:]
    private var contentAliases: [String: Set<String>] = [:]
    private var continueWatchingDismissals: [String: Date] = [:]
    @ObservationIgnored private let cloud: NuvioCloud
    @ObservationIgnored private let catalog: CinemetaClient
    @ObservationIgnored private var linkTask: Task<Void, Never>?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var artworkTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<NuvioSession, Error>?
    @ObservationIgnored private var playbackPushTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPlayback: [Int: [String: PendingPlayback]] = [:]
    @ObservationIgnored private var playbackOwnerID: String?
    @ObservationIgnored private var recentPlayback: [String: RecentPlayback] = [:]
    @ObservationIgnored private var lastPlaybackTimestamp: Int64 = 0
    @ObservationIgnored private var unlockedProfiles = Set<Int>()
    @ObservationIgnored private var preferredProfileID: Int?
    @ObservationIgnored private var needsSessionRestore = false

    var isSignedIn: Bool { session != nil }
    var email: String? { session?.email }
    var playbackAccountID: String? { session?.userId }

    var inProgress: [NuvioProgress] {
        var seen = Set<String>()
        return progress.filter { entry in
            guard (entry.position > 0 || (entry.contentType == "series" && entry.episode != nil)),
                  entry.fraction < 0.95 else { return false }
            return entry.updatedAt > dismissalDate(for: entry.contentID, type: entry.contentType)
                && !isCompleted(entry) && seen.insert(mediaKey(entry.contentID, entry.contentType)).inserted
        }
    }

    static func hasStarted(_ progress: NuvioProgress) -> Bool {
        // Cloud rows can contain a small startup position before anyone watches the title.
        progress.position >= 30_000 || (progress.position >= 5_000 && progress.fraction >= 0.05)
    }

    init(cloud: NuvioCloud = NuvioCloud(), catalog: CinemetaClient = CinemetaClient()) {
        self.cloud = cloud
        self.catalog = catalog
        restoreSession()
    }

    func beginLink() {
        if needsSessionRestore { restoreSession() }
        if isSignedIn { sync(); return }
        guard linkTask == nil else { return }
        message = nil
        isLinking = true
        linkTask = Task {
            do {
                let pairing = try await cloud.startPairing()
                try Task.checkCancellation()
                self.pairing = pairing
                let session = try await waitForApproval(pairing)
                try Task.checkCancellation()
                self.session = session
                saveSession()
                finishLink()
                sync()
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
                finishLink()
            }
        }
    }

    func cancelLink() {
        linkTask?.cancel()
        finishLink()
    }

    private func finishLink() {
        linkTask = nil
        pairing = nil
        isLinking = false
    }

    private func waitForApproval(_ pairing: NuvioPairing) async throws -> NuvioSession {
        var delay = max(1, pairing.pollInterval)
        while pairing.expiresAt > .now {
            try await Task.sleep(for: .seconds(min(delay, max(0, pairing.expiresAt.timeIntervalSinceNow))))
            guard pairing.expiresAt > .now else { break }
            do {
                switch try await cloud.pollPairing(pairing) {
                case .pending: delay = max(1, pairing.pollInterval)
                case .approved: return try await cloud.exchangePairing(pairing)
                case .expired: throw AccountError.expiredCode
                }
            } catch let error as NuvioCloudError where error.status == 429 || (error.status ?? 0) >= 500 {
                delay = min(60, delay * 2)
            } catch is URLError {
                try Task.checkCancellation()
                delay = min(60, delay * 2)
            }
        }
        throw AccountError.expiredCode
    }

    func syncIfNeeded() {
        if needsSessionRestore { restoreSession() }
        guard lastSync.map({ Date.now.timeIntervalSince($0) >= 120 }) ?? true else { return }
        sync()
    }

    func sync() {
        guard isSignedIn, syncTask == nil else { return }
        runSync()
        flushPlaybackUpdates()
    }

    func selectProfile(_ id: Int) {
        guard id != profileID, let profile = profiles.first(where: { $0.id == id }),
              !profile.isLocked || unlockedProfiles.contains(id), !isSyncing else { return }
        setProfile(id)
        runSync()
    }

    func verifyProfile(_ id: Int, pin: String) {
        guard isSignedIn, !isSyncing, profiles.contains(where: { $0.id == id && $0.isLocked }) else { return }
        guard pin.utf8.count == 4, pin.utf8.allSatisfy({ (48...57).contains($0) }) else {
            message = String(localized: "Enter the four-digit profile PIN.")
            return
        }
        isUnlocking = true
        runSync(unlocking: (id, pin))
    }

    private func runSync(unlocking: (id: Int, pin: String)? = nil) {
        isSyncing = true
        message = nil
        if sessionStorageMessage != nil { saveSession() }
        syncTask = Task {
            defer {
                if !Task.isCancelled {
                    isSyncing = false
                    isUnlocking = false
                    syncTask = nil
                }
            }
            do {
                let session = try await validSession()
                do {
                    try await pull(session: session, unlocking: unlocking)
                } catch let error as NuvioCloudError where error.isUnauthorized {
                    let refreshed = try await validSession(rejectedAccessToken: session.accessToken)
                    try await pull(session: refreshed, unlocking: unlocking)
                }
            } catch let error as NuvioCloudError where error.isInvalidSession {
                guard !Task.isCancelled else { return }
                clearSession()
                message = String(localized: "Your Nuvio session expired. Link this Apple TV again.")
            } catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
        }
    }

    private func validSession(rejectedAccessToken: String? = nil) async throws -> NuvioSession {
        guard let session else { throw CancellationError() }
        if let refreshTask { return try await refreshTask.value }
        guard rejectedAccessToken == session.accessToken || session.expiresAt.timeIntervalSinceNow < 60 else { return session }
        let refresh = Task {
            defer { if !Task.isCancelled { refreshTask = nil } }
            let refreshed = try await cloud.refresh(session)
            try Task.checkCancellation()
            self.session = refreshed
            saveSession()
            return refreshed
        }
        refreshTask = refresh
        return try await refresh.value
    }

    private func pull(session: NuvioSession, unlocking: (id: Int, pin: String)?) async throws {
        let profiles = try await cloud.profiles(session: session).sorted { $0.id < $1.id }
        try Task.checkCancellation()
        self.profiles = profiles
        if let unlocking, profiles.contains(where: { $0.id == unlocking.id }) {
            let result = try await cloud.verifyPIN(unlocking.pin, profile: unlocking.id, session: session)
            try Task.checkCancellation()
            guard result.unlocked else {
                if let seconds = result.retryAfterSeconds, seconds > 0 { throw AccountError.pinLocked(seconds) }
                throw AccountError.invalidPIN
            }
            unlockedProfiles.insert(unlocking.id)
            setProfile(unlocking.id)
        }

        let eligible = profiles.filter { !$0.isLocked || unlockedProfiles.contains($0.id) }
        let profile = eligible.first { $0.id == (profileID ?? preferredProfileID) } ?? eligible.first
        guard let profile else {
            if profileID != nil { clearProfile() }
            message = String(localized: "Choose and unlock a profile to sync.")
            return
        }
        if profileID != profile.id { setProfile(profile.id) }

        let snapshotStartedAt = ContinuousClock.now
        async let addons = cloud.addons(profile: profile.id, usesPrimaryAddons: profile.usesPrimaryAddons, session: session)
        async let progress = cloud.progress(profile: profile.id, session: session)
        async let history = cloud.history(profile: profile.id, session: session)
        async let watchlist = cloud.library(profile: profile.id, session: session)
        let snapshot = try await (addons, progress, history, watchlist)
        try Task.checkCancellation()
        guard profileID == profile.id else { return }
        advancePlaybackClock(past: snapshot.1.lazy.map(\.updatedAt).max())
        advancePlaybackClock(past: snapshot.2.lazy.map(\.watchedAt).max())
        self.addons = snapshot.0
        self.progress = snapshot.1
        self.history = snapshot.2
        applyPendingPlayback(profile.id)
        // Keep local edits made during the pull and those the server may still be coalescing.
        let coalescingCutoff = ContinuousClock.now - .seconds(35)
        recentPlayback = recentPlayback.filter { $0.value.recordedAt >= min(snapshotStartedAt, coalescingCutoff) }
        for local in recentPlayback.values { apply(local.update) }
        self.progress.sort { $0.updatedAt > $1.updatedAt }
        self.history.sort { $0.watchedAt > $1.watchedAt }
        self.watchlist = snapshot.3
        lastSync = .now
        loadContinueWatching()
        flushPlaybackUpdates()
    }

    private func setProfile(_ id: Int) {
        clearProfile()
        unlockedProfiles = unlockedProfiles.intersection([id])
        profileID = id
        preferredProfileID = id
        saveSession()
        if let key = continueWatchingDismissalsKey,
           let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([String: Date].self, from: data) {
            continueWatchingDismissals = saved
            advancePlaybackClock(past: saved.values.max())
        }
        applyPendingPlayback(id)
        loadContinueWatching()
    }

    private func clearProfile() {
        artworkTask?.cancel()
        profileID = nil
        addons = []
        progress = []
        history = []
        watchlist = []
        progressTitles = [:]
        contentAliases = [:]
        continueWatchingDismissals = [:]
        continueWatching = []
        recentPlayback = [:]
        lastSync = nil
    }

    func recordPlayback(contentID: String, kind: CinemetaKind, title: String, season: Int?, episode: Int?,
                        position: Int64, duration: Int64, completed: Bool, profileID: Int) {
        guard session != nil, self.profileID == profileID, !contentID.isEmpty,
              completed || position > 0 else { return }
        if kind == .series {
            guard let season, season >= 0, let episode, episode >= 0 else { return }
        }
        let season = kind == .series ? season : nil
        let episode = kind == .series ? episode : nil
        let previousProgress = progress(for: contentID, kind: kind, season: season, episode: episode)
        let aliases = contentAliases[mediaKey(contentID, kind.rawValue)] ?? []
        let knownHistory = history.first {
            ($0.contentID == contentID || aliases.contains($0.contentID)) && $0.contentType == kind.rawValue
                && $0.season == season && $0.episode == episode
        }
        let resolvedID = previousProgress?.contentID ?? knownHistory?.contentID ?? contentID
        let duration = max(0, duration)
        let position = completed && duration > 0 ? duration : max(0, duration > 0 ? min(position, duration) : position)
        let timestamp = nextPlaybackTimestamp()
        let update = NuvioProgressUpdate(contentID: resolvedID, contentType: kind.rawValue, season: season,
                                         episode: episode, position: position, duration: duration, timestamp: timestamp)
        let existing = pendingPlayback[profileID]?[update.key]
        let local = recentPlayback[update.key]?.update
        let watched = completed ? NuvioWatchedUpdate(contentID: resolvedID, contentType: kind.rawValue, title: title,
                                                      season: season, episode: episode, timestamp: timestamp) : existing?.watched
        let pending = PendingPlayback(progress: update, title: title, watched: watched,
                                      deletesWatched: completed ? nil : existing?.deletesWatched)
        pendingPlayback[profileID, default: [:]][update.key] = pending
        let visible = PendingPlayback(progress: update, title: title,
                                      watched: watched ?? local?.watched,
                                      deletesWatched: completed ? nil : (existing?.deletesWatched ?? local?.deletesWatched))
        recentPlayback[update.key] = RecentPlayback(update: visible, recordedAt: .now)
        persistPlaybackUpdates()
        apply(update.row(id: previousProgress?.id, title: title))
        if let watched { apply(watched.row(key: update.key, id: knownHistory?.id)) }
        refreshContinueWatching(for: update)
        flushPlaybackUpdates()
    }

    func setContinueWatchingItemWatched(_ item: CinemaContinueWatchingItem) {
        guard let profileID, let current = continueWatching.first(where: {
            $0.id == item.id && $0.progress == item.progress
        }), current.upcomingEpisode() == nil else { return }
        let row = item.progress
        setWatched(true, contentID: row.contentID, kind: item.entry.kind, title: item.entry.title.name,
                   season: row.season, episode: row.episode, profile: profileID)
        finishWatchStateEdit(for: item.entry)
    }

    func setEpisodesWatched(_ episodes: [CinemetaEpisode], title: CinemetaTitle, contentID: String, watched: Bool) {
        guard session != nil, let profileID, !contentID.isEmpty else { return }
        for episode in episodes.sorted(by: { ($0.season, $0.episode) < ($1.season, $1.episode) }) {
            guard !episode.isUpcoming(),
                  hasWatched(contentID, kind: .series, season: episode.season, episode: episode.episode) != watched else { continue }
            let type = CinemetaKind.series.rawValue
            let aliases = (contentAliases[mediaKey(contentID, type)] ?? []).union([contentID])
            let progressIDs = progress.filter {
                $0.contentType == type && aliases.contains($0.contentID)
                    && $0.season == episode.season && $0.episode == episode.episode
            }.map(\.contentID)
            let historyIDs = history.filter {
                $0.contentType == type && aliases.contains($0.contentID)
                    && $0.season == episode.season && $0.episode == episode.episode
            }.map(\.contentID)
            let primaryID = progressIDs.first ?? historyIDs.first ?? contentID
            let targets = watched ? [primaryID] : Set(progressIDs + historyIDs + [primaryID]).sorted()
            for id in targets {
                setWatched(watched, contentID: id, kind: .series, title: title.name, season: episode.season,
                           episode: episode.episode, profile: profileID)
            }
        }
        finishWatchStateEdit(for: CinemetaSearchResult(title: title, kind: .series))
    }

    func removeContinueWatchingItem(_ item: CinemaContinueWatchingItem) {
        guard let profileID, continueWatching.contains(where: { $0.id == item.id && $0.progress == item.progress }) else { return }
        let type = item.entry.kind.rawValue
        let canonical = item.entry.title.imdbID ?? item.entry.title.id
        let aliases = (contentAliases[mediaKey(canonical, type)] ?? []).union([canonical, item.progress.contentID])
        let timestamp = nextPlaybackTimestamp()
        let dismissedAt = Date(timeIntervalSince1970: Double(timestamp) / 1_000)
        for id in aliases {
            continueWatchingDismissals[mediaKey(id, type)] = dismissedAt
        }
        if let key = continueWatchingDismissalsKey,
           let data = try? JSONEncoder().encode(continueWatchingDismissals) {
            UserDefaults.standard.set(data, forKey: key)
        }
        let unfinished = progress.filter {
            aliases.contains($0.contentID) && $0.contentType == type && $0.fraction < 0.95
                && !isCompleted($0, aliases: aliases)
        }
        for row in unfinished {
            let update = NuvioProgressUpdate(contentID: row.contentID, contentType: type, season: row.season,
                                             episode: row.episode, position: 0, duration: 0, timestamp: timestamp)
            var edit = pendingPlayback[profileID]?[update.key] ?? PendingPlayback(progress: update, title: item.entry.title.name)
            edit.progress = update
            edit.needsProgressUpload = false
            edit.progressDeletionKey = row.progressKey ?? update.progressKey
            queueWatchState(edit, profile: profileID)
        }
        continueWatching.removeAll { $0.id == item.id }
        finishWatchStateEdit(for: item.entry)
    }

    private func setWatched(_ watched: Bool, contentID: String, kind: CinemetaKind, title: String,
                            season: Int?, episode: Int?, profile: Int) {
        let update = NuvioProgressUpdate(contentID: contentID, contentType: kind.rawValue, season: season, episode: episode,
                                         position: 0, duration: 0, timestamp: nextPlaybackTimestamp())
        let previous = pendingPlayback[profile]?[update.key]
        var edit = previous ?? PendingPlayback(progress: update, title: title, needsProgressUpload: false, historyOnly: true)
        edit.watched = watched ? NuvioWatchedUpdate(contentID: contentID, contentType: kind.rawValue, title: title,
                                                     season: season, episode: episode, timestamp: update.timestamp) : nil
        edit.deletesWatched = watched ? nil : update.timestamp
        let completedProgress = progress.first { update.matches($0) && $0.fraction >= 0.95 }
        if !watched, let completedProgress {
            edit.progress = update
            edit.needsProgressUpload = false
            edit.progressDeletionKey = completedProgress.progressKey ?? update.progressKey
        }
        queueWatchState(edit, profile: profile)
    }

    private func queueWatchState(_ edit: PendingPlayback, profile: Int) {
        let key = edit.progress.key
        pendingPlayback[profile, default: [:]][key] = edit
        recentPlayback[key] = RecentPlayback(update: edit, recordedAt: .now)
        apply(edit)
    }

    private func finishWatchStateEdit(for entry: CinemetaSearchResult) {
        persistPlaybackUpdates()
        let canonical = entry.title.imdbID ?? entry.title.id
        let key = mediaKey(canonical, entry.kind.rawValue)
        continueWatching.removeAll { $0.id == key }
        let aliases = (contentAliases[key] ?? []).union([canonical])
        let dismissedAt = dismissalDate(for: canonical, type: entry.kind.rawValue)
        let progress = inProgress.first {
            $0.contentType == entry.kind.rawValue && aliases.contains($0.contentID)
                && $0.updatedAt > dismissedAt && !isCompleted($0, aliases: aliases)
        }
        if let next = progress ?? suggestedEpisode(for: entry) {
            let index = continueWatching.firstIndex { $0.progress.updatedAt < next.updatedAt } ?? continueWatching.endIndex
            continueWatching.insert(CinemaContinueWatchingItem(entry: entry, progress: next), at: index)
        }
        loadContinueWatching()
        flushPlaybackUpdates()
    }

    private func nextPlaybackTimestamp() -> Int64 {
        let timestamp = max(Int64(Date.now.timeIntervalSince1970 * 1_000), lastPlaybackTimestamp + 1)
        lastPlaybackTimestamp = timestamp
        return timestamp
    }

    private func advancePlaybackClock(past date: Date?) {
        guard let date, let timestamp = Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded()) else { return }
        advancePlaybackClock(to: timestamp)
    }

    private func advancePlaybackClock(to timestamp: Int64) {
        let clockSkewLimit = Int64(Date.now.addingTimeInterval(86_400).timeIntervalSince1970 * 1_000)
        guard timestamp < clockSkewLimit else { return }
        lastPlaybackTimestamp = max(lastPlaybackTimestamp, timestamp)
    }

    private var continueWatchingDismissalsKey: String? {
        guard let userID = session?.userId, let profileID else { return nil }
        return "nuvio.continueWatching.dismissed.\(userID).\(profileID)"
    }

    private func dismissalDate(for id: String, type: String) -> Date {
        continueWatchingDismissals[mediaKey(id, type)] ?? .distantPast
    }

    private struct PendingPlayback: Codable {
        var progress: NuvioProgressUpdate
        var title: String
        var needsProgressUpload = true
        var watched: NuvioWatchedUpdate?
        var historyOnly: Bool?
        var progressDeletionKey: String?
        var deletesWatched: Int64?

        var timestamp: Int64 { max(progress.timestamp, watched?.timestamp ?? 0, deletesWatched ?? 0) }
    }

    private struct RecentPlayback {
        let update: PendingPlayback
        let recordedAt: ContinuousClock.Instant
    }

    private func applyPendingPlayback(_ profile: Int) {
        guard let pending = pendingPlayback[profile] else { return }
        for row in pending.values { apply(row) }
    }

    private func apply(_ pending: PendingPlayback) {
        if pending.progressDeletionKey != nil {
            let cutoff = Date(timeIntervalSince1970: Double(pending.progress.timestamp) / 1_000)
            progress.removeAll { pending.progress.matches($0) && $0.updatedAt <= cutoff }
        } else if pending.historyOnly != true {
            let progressID = progress.first(where: pending.progress.matches)?.id
            apply(pending.progress.row(id: progressID, title: pending.title))
        }
        if let watched = pending.watched {
            let historyID = history.first(where: watched.matches)?.id
            apply(watched.row(key: pending.progress.key, id: historyID))
        }
        if let timestamp = pending.deletesWatched {
            let cutoff = Date(timeIntervalSince1970: Double(timestamp) / 1_000)
            let target = pending.progress
            history.removeAll {
                $0.contentID == target.contentID && $0.contentType == target.contentType
                    && $0.season == target.season && $0.episode == target.episode && $0.watchedAt <= cutoff
            }
        }
    }

    private func apply(_ row: NuvioProgress) {
        if let index = progress.firstIndex(where: {
            $0.contentID == row.contentID && $0.contentType == row.contentType && $0.season == row.season && $0.episode == row.episode
        }) {
            guard progress[index].updatedAt <= row.updatedAt else { return }
            progress.remove(at: index)
        }
        progress.insert(row, at: progress.firstIndex { $0.updatedAt < row.updatedAt } ?? progress.endIndex)
    }

    private func apply(_ row: NuvioHistory) {
        if let index = history.firstIndex(where: {
            $0.contentID == row.contentID && $0.contentType == row.contentType && $0.season == row.season && $0.episode == row.episode
        }) {
            guard history[index].watchedAt <= row.watchedAt else { return }
            history.remove(at: index)
        }
        history.insert(row, at: history.firstIndex { $0.watchedAt < row.watchedAt } ?? history.endIndex)
    }

    private func refreshContinueWatching(for update: NuvioProgressUpdate) {
        let entries = Array(inProgress.prefix(20))
        let matching = entries.first { $0.contentID == update.contentID && $0.contentType == update.contentType }
        if let index = continueWatching.firstIndex(where: {
            $0.progress.contentID == update.contentID && $0.progress.contentType == update.contentType
        }) {
            let previous = continueWatching[index]
            let current = matching ?? suggestedEpisode(for: previous.entry)
            var shelf = continueWatching
            shelf.remove(at: index)
            if let current {
                let index = shelf.firstIndex { $0.progress.updatedAt < current.updatedAt } ?? shelf.endIndex
                shelf.insert(CinemaContinueWatchingItem(entry: previous.entry, progress: current), at: index)
            }
            continueWatching = shelf
            if matching == nil { loadContinueWatching() }
        } else if matching != nil || update.contentType == CinemetaKind.series.rawValue {
            loadContinueWatching()
        }
    }

    private func flushPlaybackUpdates() {
        guard playbackPushTask == nil, let profile = profileID, pendingPlayback[profile]?.isEmpty == false else { return }
        playbackPushTask = Task(priority: .utility) {
            defer {
                if !Task.isCancelled {
                    playbackPushTask = nil
                    if profileID != profile { flushPlaybackUpdates() }
                }
            }
            var retries = 0
            while !Task.isCancelled, profileID == profile,
                  let pending = pendingPlayback[profile], !pending.isEmpty {
                let queued = Dictionary(uniqueKeysWithValues: pending.sorted { $0.key < $1.key }.prefix(100).map { ($0.key, $0.value) })
                do {
                    let watchedDeletions = queued.filter { $0.value.deletesWatched != nil }
                    if !watchedDeletions.isEmpty {
                        let keys = watchedDeletions.values.map {
                            NuvioWatchedKey(contentID: $0.progress.contentID, season: $0.progress.season, episode: $0.progress.episode)
                        }
                        try await sendPlaybackUpdate(profile: profile) { session in
                            try await self.cloud.deleteWatched(keys, profile: profile, session: session)
                        }
                        try Task.checkCancellation()
                        for (key, row) in watchedDeletions where pendingPlayback[profile]?[key]?.deletesWatched == row.deletesWatched {
                            pendingPlayback[profile]?[key]?.deletesWatched = nil
                        }
                        finishPlaybackUpdates(profile)
                    }

                    let progressDeletions = queued.filter { $0.value.progressDeletionKey != nil }
                    if !progressDeletions.isEmpty {
                        let keys = progressDeletions.values.compactMap(\.progressDeletionKey)
                        try await sendPlaybackUpdate(profile: profile) { session in
                            try await self.cloud.deleteProgress(keys, profile: profile, session: session)
                        }
                        try Task.checkCancellation()
                        for (key, row) in progressDeletions where pendingPlayback[profile]?[key]?.progress.timestamp == row.progress.timestamp {
                            guard let current = pendingPlayback[profile]?[key], current.progressDeletionKey == row.progressDeletionKey else { continue }
                            pendingPlayback[profile]?[key]?.progressDeletionKey = nil
                            pendingPlayback[profile]?[key]?.historyOnly = true
                        }
                        finishPlaybackUpdates(profile)
                    }

                    let watched = queued.values.compactMap(\.watched)
                    if !watched.isEmpty {
                        try await sendPlaybackUpdate(profile: profile) { session in
                            try await self.cloud.pushWatched(watched, profile: profile, origin: Self.playbackOriginID, session: session)
                        }
                        try Task.checkCancellation()
                        for (key, snapshot) in queued where snapshot.watched != nil {
                            guard let current = pendingPlayback[profile]?[key], current.watched?.timestamp == snapshot.watched?.timestamp else { continue }
                            pendingPlayback[profile]?[key]?.watched = nil
                        }
                        finishPlaybackUpdates(profile)
                    }

                    guard profileID == profile else { break }
                    let progress = queued.values.filter(\.needsProgressUpload).map(\.progress)
                    if !progress.isEmpty {
                        try await sendPlaybackUpdate(profile: profile) { session in
                            try await self.cloud.pushProgress(progress, profile: profile, origin: Self.playbackOriginID, session: session)
                        }
                        try Task.checkCancellation()
                        for row in progress {
                            guard pendingPlayback[profile]?[row.key]?.progress.timestamp == row.timestamp else { continue }
                            pendingPlayback[profile]?[row.key]?.needsProgressUpload = false
                        }
                        finishPlaybackUpdates(profile)
                    }
                    retries = 0
                } catch {
                    guard !Task.isCancelled else { return }
                    let status = (error as? NuvioCloudError)?.status
                    if error is URLError || status == 429 || (status ?? 0) >= 500, retries < 2 {
                        retries += 1
                        do { try await Task.sleep(for: .seconds(2 * retries)) } catch { return }
                    } else {
                        return
                    }
                }
            }
        }
    }

    private func sendPlaybackUpdate(profile: Int, _ send: (NuvioSession) async throws -> Void) async throws {
        let session = try await validSession()
        try Task.checkCancellation()
        guard profileID == profile else { throw CancellationError() }
        do {
            try await send(session)
        } catch let error as NuvioCloudError where error.isUnauthorized {
            let refreshed = try await validSession(rejectedAccessToken: session.accessToken)
            try Task.checkCancellation()
            guard profileID == profile else { throw CancellationError() }
            try await send(refreshed)
        }
    }

    private func finishPlaybackUpdates(_ profile: Int) {
        pendingPlayback[profile] = pendingPlayback[profile]?.filter {
            $0.value.needsProgressUpload || $0.value.watched != nil || $0.value.progressDeletionKey != nil || $0.value.deletesWatched != nil
        }
        if pendingPlayback[profile]?.isEmpty == true { pendingPlayback.removeValue(forKey: profile) }
        persistPlaybackUpdates()
    }

    private static let playbackOriginID: String = {
        let key = "nuvio.playback.originID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let origin = "nuvio-cinema-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(origin, forKey: key)
        return origin
    }()

    private func restorePlaybackUpdates(owner: String?) {
        guard let owner, playbackOwnerID != owner else { return }
        playbackOwnerID = owner
        if let data = UserDefaults.standard.data(forKey: "nuvio.playback.pending.\(owner)"),
           let saved = try? JSONDecoder().decode([Int: [String: PendingPlayback]].self, from: data) {
            for (profile, rows) in saved {
                if let latest = rows.values.lazy.map(\.timestamp).max() { advancePlaybackClock(to: latest) }
                pendingPlayback[profile, default: [:]].merge(rows) {
                    $0.timestamp >= $1.timestamp ? $0 : $1
                }
            }
        }
    }

    private func persistPlaybackUpdates() {
        guard let playbackOwnerID else { return }
        let key = "nuvio.playback.pending.\(playbackOwnerID)"
        if pendingPlayback.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(pendingPlayback) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func loadContinueWatching() {
        artworkTask?.cancel()
        let catalog = self.catalog
        let entries = Array(inProgress.prefix(20))
        var seenIDs = Set(entries.map { mediaKey($0.contentID, $0.contentType) })
        let nextEpisodeSeeds = history.filter {
            $0.contentType == CinemetaKind.series.rawValue && ($0.season ?? 0) > 0 && $0.episode != nil
                && $0.watchedAt > dismissalDate(for: $0.contentID, type: $0.contentType)
        }.prefix(50).compactMap { row -> NuvioHistory? in
            guard seenIDs.insert(mediaKey(row.contentID, row.contentType)).inserted else { return nil }
            return row
        }.prefix(10)
        let aliasHistory = history.filter { $0.contentID.hasPrefix("tmdb:") }.prefix(50).compactMap { row -> (String, String)? in
            guard seenIDs.insert(mediaKey(row.contentID, row.contentType)).inserted else { return nil }
            return (row.contentID, row.contentType)
        }.prefix(10)
        let ids = entries.map { ($0.contentID, $0.contentType) }
            + nextEpisodeSeeds.map { ($0.contentID, $0.contentType) } + aliasHistory
        artworkTask = Task {
            let fetched = await withTaskGroup(of: (Int, CinemetaSearchResult?).self) { group in
                for (index, id) in ids.enumerated() {
                    guard let kind = CinemetaKind(rawValue: id.1) else { continue }
                    group.addTask {
                        let title = await catalog.details(contentID: id.0, kind: kind)
                        return (index, title.map { CinemetaSearchResult(title: $0, kind: kind) })
                    }
                }
                var results: [(Int, CinemetaSearchResult)] = []
                for await (index, result) in group {
                    if let result { results.append((index, result)) }
                }
                return results.sorted { $0.0 < $1.0 }
            }
            guard !Task.isCancelled else { return }
            let fetchedByIndex = Dictionary(uniqueKeysWithValues: fetched)
            let cachedEntries = Dictionary(continueWatching.map {
                (mediaKey($0.progress.contentID, $0.progress.contentType), $0.entry)
            }, uniquingKeysWith: { first, _ in first })
            let results = ids.enumerated().compactMap { index, id in
                (fetchedByIndex[index] ?? cachedEntries[mediaKey(id.0, id.1)]).map { (index, $0) }
            }
            for (index, result) in results {
                let (id, type) = ids[index]
                progressTitles[mediaKey(id, type)] = result.title.name
                if let imdbID = result.title.imdbID {
                    contentAliases[mediaKey(imdbID, type), default: []].insert(id)
                }
            }
            // Playback can update an existing shelf item while its metadata is loading.
            let currentEntries = inProgress
            let currentShelfProgress = Dictionary(uniqueKeysWithValues: currentEntries.prefix(20).map {
                (mediaKey($0.contentID, $0.contentType), $0)
            })
            var seen = Set<String>()
            let candidates: [CinemaContinueWatchingItem] = results.compactMap { index, entry in
                guard let imdbID = entry.title.imdbID else { return nil }
                let key = mediaKey(imdbID, entry.kind.rawValue)
                let aliases = (contentAliases[key] ?? []).union([imdbID])
                let progress: NuvioProgress
                let (contentID, contentType) = ids[index]
                if let current = currentShelfProgress[mediaKey(contentID, contentType)] {
                    guard !isCompleted(current, aliases: aliases) else { return nil }
                    progress = current
                } else {
                    let seedIndex = index - entries.count
                    guard nextEpisodeSeeds.indices.contains(seedIndex),
                          !currentEntries.contains(where: {
                              $0.contentType == entry.kind.rawValue && aliases.contains($0.contentID) && !isCompleted($0, aliases: aliases)
                          }),
                          let next = nextEpisodeProgress(for: entry.title, after: nextEpisodeSeeds[seedIndex], imdbID: imdbID) else { return nil }
                    progress = next
                }
                guard progress.updatedAt > dismissalDate(for: imdbID, type: contentType) else { return nil }
                guard seen.insert(key).inserted else { return nil }
                return CinemaContinueWatchingItem(entry: entry, progress: progress)
            }
            continueWatching = Array(candidates.sorted { $0.progress.updatedAt > $1.progress.updatedAt }.prefix(20))
        }
    }

    private func nextEpisodeProgress(for title: CinemetaTitle, after watched: NuvioHistory, imdbID: String) -> NuvioProgress? {
        guard let season = watched.season, season > 0, let episode = watched.episode,
              let next = nextUnwatchedEpisode(in: title.episodes, after: (season, episode), contentID: imdbID, includesUpcoming: true),
              let timestamp = Int64(exactly: (watched.watchedAt.timeIntervalSince1970 * 1_000).rounded()) else { return nil }
        return NuvioProgressUpdate(contentID: watched.contentID, contentType: watched.contentType, season: next.season,
                                   episode: next.episode, position: 0, duration: 0,
                                   timestamp: timestamp).row(title: title.name)
    }

    private func suggestedEpisode(for entry: CinemetaSearchResult) -> NuvioProgress? {
        guard entry.kind == .series, let imdbID = entry.title.imdbID else { return nil }
        let type = entry.kind.rawValue
        let aliases = (contentAliases[mediaKey(imdbID, type)] ?? []).union([imdbID])
        let dismissedAt = dismissalDate(for: imdbID, type: type)
        guard let latest = history.first(where: {
            $0.contentType == type && aliases.contains($0.contentID)
                && $0.watchedAt > max(dismissedAt, dismissalDate(for: $0.contentID, type: type))
                && ($0.season ?? 0) > 0 && $0.episode != nil
        }) else { return nil }
        return nextEpisodeProgress(for: entry.title, after: latest, imdbID: imdbID)
    }

    func currentSeriesEpisode(in episodes: [CinemetaEpisode], contentID: String) -> CinemetaEpisode? {
        guard !episodes.isEmpty else { return nil }
        let aliases = contentAliases[mediaKey(contentID, CinemetaKind.series.rawValue)] ?? []
        let watched = history.lazy.filter {
            $0.contentType == CinemetaKind.series.rawValue && ($0.contentID == contentID || aliases.contains($0.contentID))
                && $0.season != nil && $0.episode != nil
        }.max { $0.watchedAt < $1.watchedAt }
        let upNext = continueWatching.first {
            $0.entry.kind == .series && ($0.entry.title.imdbID ?? $0.entry.title.id) == contentID
        }?.progress

        for row in [continueProgress(for: contentID, kind: .series), upNext].compactMap({ $0 })
            .sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard let season = row.season, let number = row.episode,
                  watched.map({ row.updatedAt >= $0.watchedAt }) ?? true,
                  !hasWatched(contentID, kind: .series, season: season, episode: number) else { continue }
            if let match = episodes.first(where: { $0.season == season && $0.episode == number && !$0.isUpcoming() }) {
                return match
            }
        }

        guard let season = watched?.season, let number = watched?.episode else { return nil }
        return nextUnwatchedEpisode(in: episodes, after: (season, number), contentID: contentID)
            ?? episodes.first { $0.season == season && $0.episode == number }
    }

    private func nextUnwatchedEpisode(in episodes: [CinemetaEpisode], after watched: (Int, Int),
                                     contentID: String, includesUpcoming: Bool = false) -> CinemetaEpisode? {
        let next = episodes.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }.first {
            ($0.season, $0.episode) > watched && (watched.0 > 0 || $0.season == 0)
                && !hasWatched(contentID, kind: .series, season: $0.season, episode: $0.episode)
        }
        guard let next, next.releasedAt != nil, includesUpcoming || !next.isUpcoming() else { return nil }
        return next
    }

    func title(for progress: NuvioProgress) -> String {
        progress.title ?? progressTitles[mediaKey(progress.contentID, progress.contentType)]
            ?? history.first { $0.contentID == progress.contentID && $0.contentType == progress.contentType }?.title
            ?? watchlist.first { $0.contentID == progress.contentID && $0.contentType == progress.contentType }?.title
            ?? (progress.contentType == "movie" ? String(localized: "Movie") : String(localized: "Series"))
    }

    func progress(for contentID: String, kind: CinemetaKind, season: Int? = nil, episode: Int? = nil) -> NuvioProgress? {
        let aliases = contentAliases[mediaKey(contentID, kind.rawValue)] ?? []
        return progress.first {
            ($0.contentID == contentID || aliases.contains($0.contentID))
                && $0.contentType == kind.rawValue && $0.season == season && $0.episode == episode
        }
    }

    func continueProgress(for contentID: String, kind: CinemetaKind) -> NuvioProgress? {
        let aliases = contentAliases[mediaKey(contentID, kind.rawValue)] ?? []
        return inProgress.first { ($0.contentID == contentID || aliases.contains($0.contentID)) && $0.contentType == kind.rawValue }
    }

    private func isCompleted(_ progress: NuvioProgress, aliases: Set<String> = []) -> Bool {
        history.contains {
            ($0.contentID == progress.contentID || aliases.contains($0.contentID)) && $0.contentType == progress.contentType
                && $0.season == progress.season && $0.episode == progress.episode && $0.watchedAt >= progress.updatedAt
        }
    }

    func hasWatched(_ contentID: String, kind: CinemetaKind, season: Int? = nil, episode: Int? = nil) -> Bool {
        let progress = progress(for: contentID, kind: kind, season: season, episode: episode)
        if let progress, progress.fraction >= 0.95 { return true }
        let aliases = contentAliases[mediaKey(contentID, kind.rawValue)] ?? []
        return history.contains {
            ($0.contentID == contentID || aliases.contains($0.contentID))
                && $0.contentType == kind.rawValue && $0.season == season && $0.episode == episode
                && $0.watchedAt >= (progress?.updatedAt ?? .distantPast)
        }
    }

    func signOut() {
        let session = self.session
        clearSession()
        message = nil
        if let session { Task { try? await cloud.logout(session) } }
    }

    private func clearSession() {
        cancelLink()
        syncTask?.cancel()
        syncTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        playbackPushTask?.cancel()
        playbackPushTask = nil
        pendingPlayback = [:]
        playbackOwnerID = nil
        isSyncing = false
        isUnlocking = false
        session = nil
        profiles = []
        unlockedProfiles = []
        preferredProfileID = nil
        clearProfile()
        needsSessionRestore = false
        do {
            try SessionKeychain.delete()
            sessionStorageMessage = nil
        } catch {
            sessionStorageMessage = String(localized: "This Apple TV couldn’t remove the saved session from Keychain.")
        }
    }

    private func restoreSession() {
        do {
            if let saved = try SessionKeychain.load() {
                session = saved.session
                preferredProfileID = saved.profileID
                restorePlaybackUpdates(owner: saved.session.userId)
            }
            needsSessionRestore = false
            sessionStorageMessage = nil
        } catch {
            needsSessionRestore = true
            sessionStorageMessage = String(localized: "This Apple TV couldn’t read the saved Nuvio session from Keychain.")
        }
    }

    private func saveSession() {
        guard let session else { return }
        restorePlaybackUpdates(owner: session.userId)
        needsSessionRestore = false
        do {
            try SessionKeychain.save(.init(session: session, profileID: preferredProfileID))
            sessionStorageMessage = nil
        } catch {
            sessionStorageMessage = String(localized: "This Apple TV couldn’t save your Nuvio session to Keychain.")
        }
    }

    private func mediaKey(_ contentID: String, _ contentType: String) -> String { "\(contentType):\(contentID)" }
}

private enum AccountError: LocalizedError {
    case expiredCode, invalidPIN, pinLocked(Int)

    var errorDescription: String? {
        switch self {
        case .expiredCode: String(localized: "The sign-in code expired. Get a new code to try again.")
        case .invalidPIN: String(localized: "That profile PIN didn’t match.")
        case .pinLocked(let seconds): String(localized: "This profile is temporarily locked. Try again in \(seconds) seconds.")
        }
    }
}

private enum SessionKeychain {
    struct Failure: Error { let status: OSStatus }

    struct Saved: Codable {
        let session: NuvioSession
        let profileID: Int?
    }

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.nuviocinema.app.nuvio-cloud",
         kSecAttrAccount as String: "session"]
    }

    static func load() throws -> Saved? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = item as? Data else { throw Failure(status: errSecDecode) }
        return try JSONDecoder().decode(Saved.self, from: data)
    }

    static func save(_ value: Saved) throws {
        let data = try JSONEncoder().encode(value)
        let attributes = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Failure(status: updated) }
        var newItem = query
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(newItem as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}
