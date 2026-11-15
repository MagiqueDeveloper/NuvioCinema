import SwiftUI
import UIKit

final class PosterCell: UICollectionViewCell {
    private let poster = UIImageView()
    private let label = UILabel()
    private let placeholder = UIImageView(image: UIImage(systemName: "film"))
    private let titleSkeleton = UIView()
    private var loadTask: Task<Void, Never>?
    private var artworkURLs: [URL]?
    private var artworkMissingHandler: (() -> Void)?
    private var didConfirmMissingArtwork = false
    private var isSkeleton = false

    override var canBecomeFocused: Bool { !isSkeleton && super.canBecomeFocused }

    override init(frame: CGRect) {
        super.init(frame: frame)
        poster.contentMode = .scaleAspectFit
        poster.backgroundColor = UIColor(white: 0.09, alpha: 1)
        poster.layer.cornerRadius = 14
        poster.clipsToBounds = true
        poster.layer.borderColor = UIColor.white.cgColor
        placeholder.tintColor = .lightGray
        label.textColor = .white
        label.font = .systemFont(ofSize: 25, weight: .medium)
        label.numberOfLines = 2
        label.isAccessibilityElement = false
        contentView.addSubview(poster)
        contentView.addSubview(label)
        contentView.addSubview(titleSkeleton)
        poster.addSubview(placeholder)
        titleSkeleton.backgroundColor = UIColor.white.withAlphaComponent(0.10)
        titleSkeleton.layer.cornerRadius = 7
        poster.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        titleSkeleton.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        titleSkeleton.isHidden = true
        placeholder.isHidden = true
        NSLayoutConstraint.activate([
            poster.topAnchor.constraint(equalTo: contentView.topAnchor),
            poster.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            poster.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            poster.heightAnchor.constraint(equalTo: poster.widthAnchor, multiplier: 1.5),
            label.topAnchor.constraint(equalTo: poster.bottomAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            titleSkeleton.leadingAnchor.constraint(equalTo: poster.leadingAnchor),
            titleSkeleton.topAnchor.constraint(equalTo: poster.bottomAnchor, constant: 13),
            titleSkeleton.widthAnchor.constraint(equalTo: poster.widthAnchor, multiplier: 0.70),
            titleSkeleton.heightAnchor.constraint(equalToConstant: 14),
            placeholder.centerXAnchor.constraint(equalTo: poster.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: poster.centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Poster cells are created in code") }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations { [weak self] in self?.updateFocusAppearance(focused) }
    }

    private func updateFocusAppearance(_ focused: Bool) {
        poster.layer.borderWidth = focused ? 3 : 0
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        resetArtworkLoad()
        poster.image = nil
        updateFocusAppearance(false)
        titleSkeleton.isHidden = true
        placeholder.isHidden = true
        isSkeleton = false
    }

    func showSkeleton() {
        resetArtworkLoad()
        isSkeleton = true
        isAccessibilityElement = false
        titleSkeleton.isHidden = false
        poster.backgroundColor = UIColor(white: 0.16, alpha: 1)
        poster.image = nil
        label.text = nil
        placeholder.isHidden = true
        updateFocusAppearance(false)
    }

    func configure(name: String, artworkURLs: [URL], onArtworkMissing: @escaping () -> Void) {
        isSkeleton = false
        isAccessibilityElement = true
        titleSkeleton.isHidden = true
        label.text = name
        accessibilityLabel = name
        updateFocusAppearance(isFocused)

        var seen = Set<URL>()
        let urls = artworkURLs.filter { seen.insert($0).inserted }
        if self.artworkURLs == urls {
            // Updating a display name does not need another artwork request.
            if loadTask != nil {
                artworkMissingHandler = onArtworkMissing
            } else if didConfirmMissingArtwork {
                onArtworkMissing()
            }
            return
        }

        resetArtworkLoad()
        self.artworkURLs = urls

        guard !urls.isEmpty else {
            showPlaceholder()
            return
        }

        placeholder.isHidden = true
        for url in urls {
            guard let image = CinemaImageCache.cached(url) else { continue }
            CinemaNetworkMetrics.recordCacheHit(for: url, resource: .artwork, tier: .memory)
            showPoster(image)
            return
        }
        poster.image = nil
        poster.backgroundColor = UIColor(white: 0.16, alpha: 1)
        artworkMissingHandler = onArtworkMissing
        loadTask = Task { [weak self] in
            var allMissing = true
            for url in urls {
                guard self != nil, !Task.isCancelled else { return }
                do {
                    let image = try await CinemaImageCache.shared.image(for: url)
                    guard let self, !Task.isCancelled else { return }
                    loadTask = nil
                    artworkMissingHandler = nil
                    showPoster(image)
                    return
                } catch CinemaImageError.missing {
                    continue
                } catch {
                    allMissing = false
                }
            }
            guard let self, !Task.isCancelled else { return }
            let reportMissing = artworkMissingHandler
            loadTask = nil
            artworkMissingHandler = nil
            didConfirmMissingArtwork = allMissing
            showPlaceholder()
            if allMissing { reportMissing?() }
        }
    }

    private func resetArtworkLoad() {
        loadTask?.cancel()
        loadTask = nil
        artworkURLs = nil
        artworkMissingHandler = nil
        didConfirmMissingArtwork = false
    }

    private func showPoster(_ image: CGImage) {
        poster.image = UIImage(cgImage: image)
        poster.backgroundColor = UIColor(white: 0.09, alpha: 1)
    }

    private func showPlaceholder() {
        poster.image = nil
        poster.backgroundColor = UIColor(white: 0.09, alpha: 1)
        placeholder.isHidden = false
    }
}
