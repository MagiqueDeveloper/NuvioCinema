import SwiftUI
import UIKit

struct CinemetaSearchView: UIViewControllerRepresentable {
    let isActive: Bool
    let account: NuvioAccount

    func makeUIViewController(context: Context) -> SearchViewController {
        SearchViewController(account: account)
    }

    func updateUIViewController(_ controller: SearchViewController, context: Context) {
        controller.setTabActive(isActive)
    }
}

final class SearchViewController: UIViewController, UISearchResultsUpdating {
    private let results: SearchResultsController
    private var isTabActive = false

    init(account: NuvioAccount) {
        results = SearchResultsController(account: account)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Search is created in code") }

    private lazy var searchContainer: UISearchContainerViewController = {
        let search = UISearchController(searchResultsController: results)
        search.searchResultsUpdater = self
        search.searchBar.placeholder = String(localized: "Search movies and series")
        search.searchControllerObservedScrollView = results.collectionView
        return UISearchContainerViewController(searchController: search)
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(searchContainer)
        let searchView: UIView = searchContainer.view
        searchView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchView)
        NSLayoutConstraint.activate([
            searchView.topAnchor.constraint(equalTo: view.topAnchor),
            searchView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            searchView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        searchContainer.didMove(toParent: self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(searchFocusDidUpdate(_:)), name: UIFocusSystem.didUpdateNotification, object: nil
        )
    }

    func setTabActive(_ isActive: Bool) {
        guard isTabActive != isActive else { return }
        isTabActive = isActive
        results.setActive(isActive)
        if isActive { scheduleSearchInputActivation() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        scheduleSearchInputActivation()
    }

    @objc private func searchFocusDidUpdate(_ notification: Notification) {
        // The container presents its search controller, so its focus updates can bypass this controller.
        guard isTabActive,
              let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext,
              isSearchInput(context.nextFocusedItem), !isSearchInput(context.previouslyFocusedItem) else { return }
        scheduleSearchInputActivation()
    }

    private func isSearchInput(_ focusedItem: (any UIFocusItem)?) -> Bool {
        guard let focusedItem, let searchView = searchContainer.searchController.viewIfLoaded,
              searchView.contains(focusedItem) else { return false }
        return !results.contains(focusedItem)
    }

    private func scheduleSearchInputActivation() {
        // Remote focus can enter the inline keyboard before the bar owns text input.
        // Wait for UIKit to finish the focus update before requesting the responder.
        DispatchQueue.main.async { [weak self] in
            guard let self, isTabActive, viewIfLoaded?.window != nil,
                  isSearchInput(UIFocusSystem.focusSystem(for: self)?.focusedItem) else { return }
            let searchBar = searchContainer.searchController.searchBar
            if searchBar.window != nil, !searchBar.isFirstResponder {
                searchBar.becomeFirstResponder()
            }
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        results.setQuery(searchController.searchBar.text ?? "")
    }
}

private final class SearchResultsController: UICollectionViewController, UICollectionViewDelegateFlowLayout {
    private static let posterWidth: CGFloat = 240
    private let account: NuvioAccount
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private var searchTask: Task<Void, Never>?
    private var removalTask: Task<Void, Never>?
    private var query = ""
    private var isActive = false
    private var rankedResults: [CinemetaSearchResult] = []
    private var resultsByID: [String: CinemetaSearchResult] = [:]
    private var names: [String: String] = [:]
    private var missingIDs = Set<String>()
    private var hasFailure = false
    private var searchFinished = false
    private var gridStatus: GridStatus?
    private weak var detailController: SearchTitleDetailsController?
    private var restoringResultID: String?

    private struct GridStatus: Equatable {
        let message: String
        var isLoading = false
        var canRetry = false
    }

    init(account: NuvioAccount) {
        self.account = account
        let layout = UICollectionViewFlowLayout()
        layout.itemSize = CGSize(width: Self.posterWidth, height: Self.posterWidth * 1.5 + 70)
        layout.sectionInset = UIEdgeInsets(top: 30, left: 28, bottom: 32, right: 28)
        layout.minimumInteritemSpacing = 32
        layout.minimumLineSpacing = 32
        super.init(collectionViewLayout: layout)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Search results are created in code") }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .clear
        collectionView.remembersLastFocusedIndexPath = false
        collectionView.alwaysBounceVertical = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.register(SearchGridStatus.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
                                withReuseIdentifier: "Status")
        let registration = UICollectionView.CellRegistration<PosterCell, String> { [weak self] cell, _, id in
            guard let self, let result = resultsByID[id] else { return }
            cell.configure(name: names[id] ?? result.title.name, url: BetterPosters.url(for: result.title.imdbID)) {
                [weak self] in self?.markMissing(id)
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { [weak self] view, kind, indexPath in
            guard let self, let footer = view.dequeueReusableSupplementaryView(
                ofKind: kind, withReuseIdentifier: "Status", for: indexPath
            ) as? SearchGridStatus else { return nil }
            configureStatus(footer)
            return footer
        }
        applyResults()
    }

    func setActive(_ active: Bool) {
        guard isActive != active else { return }
        isActive = active
        if active && !query.isEmpty && !searchFinished {
            startSearch()
        } else if !active {
            searchTask?.cancel()
        }
    }

    func setQuery(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query != trimmed else { return }
        query = trimmed
        startSearch()
    }

    private func startSearch() {
        searchTask?.cancel()
        removalTask?.cancel()
        removalTask = nil
        searchFinished = false
        hasFailure = false
        rankedResults = []
        missingIDs = []
        loadViewIfNeeded()
        applyResults()
        collectionView.setContentOffset(CGPoint(x: -collectionView.adjustedContentInset.left,
                                                 y: -collectionView.adjustedContentInset.top), animated: false)
        guard isActive, !query.isEmpty else { return }
        let term = query
        searchTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(300))) != nil else { return }
            let catalog = await CinemetaClient().load(query: term)
            guard !Task.isCancelled, let self, isActive, query == term else { return }
            rankedResults = catalog.rankedResults(for: term)
            hasFailure = catalog.hasFailure
            searchFinished = true
            applyResults()
        }
    }

    private func markMissing(_ id: String) {
        guard resultsByID[id] != nil, missingIDs.insert(id).inserted else { return }
        guard removalTask == nil else { return }
        // Apply nearby artwork failures together so rows don’t shift for each response.
        removalTask = Task { [weak self] in
            guard (try? await Task.sleep(for: .milliseconds(100))) != nil, let self else { return }
            removalTask = nil
            applyResults()
        }
    }

    private func applyResults() {
        let results = rankedResults.filter { $0.title.imdbID != nil && !missingIDs.contains($0.id) }
        let newNames = CinemetaSearchResult.disambiguatedNames(for: results)
        let previousIDs = Set(dataSource.snapshot().itemIdentifiers)
        resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(results.map(\.id))
        snapshot.reconfigureItems(results.map(\.id).filter { previousIDs.contains($0) && names[$0] != newNames[$0] })
        names = newNames
        let previousStatus = gridStatus
        gridStatus = statusForResults(hasResults: !results.isEmpty)
        dataSource.apply(snapshot, animatingDifferences: false)

        if previousStatus != gridStatus {
            collectionView.collectionViewLayout.invalidateLayout()
            for footer in collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionFooter) {
                if let footer = footer as? SearchGridStatus {
                    configureStatus(footer)
                }
            }
        }
    }

    private func statusForResults(hasResults: Bool) -> GridStatus? {
        guard !query.isEmpty else { return nil }
        if !searchFinished {
            return GridStatus(message: String(localized: "Searching Cinemeta…"), isLoading: true)
        }
        if hasFailure {
            let message = hasResults
                ? String(localized: "Some search results couldn’t load.")
                : String(localized: "Couldn’t load search results.")
            return GridStatus(message: message, canRetry: true)
        }
        guard !hasResults else { return nil }
        let message = rankedResults.isEmpty
            ? String(localized: "No results for “\(query)”.")
            : String(localized: "No results with posters for “\(query)”.")
        return GridStatus(message: message)
    }

    private func configureStatus(_ footer: SearchGridStatus) {
        footer.isHidden = gridStatus == nil
        guard let gridStatus else { return }
        footer.configure(gridStatus.message, isLoading: gridStatus.isLoading, canRetry: gridStatus.canRetry)
        footer.retryAction = { [weak self] in self?.startSearch() }
    }

    override func indexPathForPreferredFocusedView(in collectionView: UICollectionView) -> IndexPath? {
        let visible = collectionView.indexPathsForVisibleItems.sorted()
        if let id = restoringResultID, let indexPath = dataSource.indexPath(for: id), visible.contains(indexPath) {
            return indexPath
        }
        let viewport = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        return visible.first { indexPath in
            collectionView.layoutAttributesForItem(at: indexPath).map { viewport.contains($0.frame) } ?? false
        } ?? visible.first
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        referenceSizeForFooterInSection section: Int) -> CGSize {
        guard let gridStatus else { return .zero }
        return CGSize(width: collectionView.bounds.width, height: gridStatus.canRetry ? 180 : 150)
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard detailController == nil,
              let id = dataSource.itemIdentifier(for: indexPath), let result = resultsByID[id] else { return }
        let offset = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let resultIDs = dataSource.snapshot().itemIdentifiers
        let controller = SearchTitleDetailsController(title: result.title, kind: result.kind, account: account)
        controller.onBack = { [weak self, weak controller] in
            guard let controller else { return }
            self?.dismissDetails(controller, for: id, offset: offset, resultIDs: resultIDs)
        }
        controller.modalPresentationStyle = .fullScreen
        detailController = controller
        present(controller, animated: true)
    }

    private func dismissDetails(_ controller: SearchTitleDetailsController, for id: String, offset: CGFloat, resultIDs: [String]) {
        guard detailController === controller, controller.presentingViewController != nil,
              !controller.isBeingDismissed else { return }
        controller.onBack = nil
        restoringResultID = id
        controller.dismiss(animated: true) { [weak self] in
            guard let self else { return }
            detailController = nil
            defer { restoringResultID = nil }
            guard isActive, viewIfLoaded?.window != nil, let indexPath = dataSource.indexPath(for: id) else { return }

            // Keep UIKit's normal transition restoration when it already returned to this card.
            if dataSource.snapshot().itemIdentifiers == resultIDs {
                let y = offset - collectionView.adjustedContentInset.top
                if abs(collectionView.contentOffset.y - y) > 1 {
                    collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: y), animated: false)
                }
            }
            collectionView.layoutIfNeeded()
            if !collectionView.indexPathsForVisibleItems.contains(indexPath) {
                collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
                collectionView.layoutIfNeeded()
            }
            guard let cell = collectionView.cellForItem(at: indexPath), !cell.isFocused else { return }
            let focusSystem = UIFocusSystem.focusSystem(for: self)
            focusSystem?.requestFocusUpdate(to: collectionView)
            focusSystem?.updateFocusIfNeeded()
        }
    }
}

private final class SearchGridStatus: UICollectionReusableView {
    var retryAction: (() -> Void)?
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let retry = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textColor = .lightGray
        label.font = .preferredFont(forTextStyle: .body)
        label.textAlignment = .center
        label.numberOfLines = 2
        retry.setTitle(String(localized: "Try Again"), for: .normal)
        retry.addAction(UIAction { [weak self] _ in self?.retryAction?() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [spinner, label, retry])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Search status is created in code") }

    func configure(_ message: String, isLoading: Bool = false, canRetry: Bool = false) {
        label.text = message
        retry.isHidden = !canRetry
        if isLoading { spinner.startAnimating() } else { spinner.stopAnimating() }
        spinner.isHidden = !isLoading
    }
}
