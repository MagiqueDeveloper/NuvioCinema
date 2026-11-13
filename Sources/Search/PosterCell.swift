import SwiftUI
import UIKit

private struct PosterLoadingIndicator: View {
    var body: some View {
        ProgressView().progressViewStyle(.circular).tint(.white)
    }
}

final class PosterCell: UICollectionViewCell {
    private let poster = UIImageView()
    private let label = UILabel()
    private let placeholder = UIImageView(image: UIImage(systemName: "film"))
    private let spinner = UIHostingConfiguration { PosterLoadingIndicator() }
        .margins(.all, 0)
        .makeContentView()
    private var loadTask: Task<Void, Never>?
    private var url: URL?

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
        poster.addSubview(spinner)
        poster.addSubview(placeholder)
        poster.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true
        placeholder.isHidden = true
        NSLayoutConstraint.activate([
            poster.topAnchor.constraint(equalTo: contentView.topAnchor),
            poster.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            poster.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            poster.heightAnchor.constraint(equalTo: poster.widthAnchor, multiplier: 1.5),
            label.topAnchor.constraint(equalTo: poster.bottomAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: poster.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: poster.centerYAnchor),
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
        loadTask?.cancel()
        loadTask = nil
        url = nil
        poster.image = nil
        updateFocusAppearance(false)
        spinner.isHidden = true
        placeholder.isHidden = true
    }

    func configure(name: String, url: URL?, onMissing: (() -> Void)? = nil) {
        label.text = name
        accessibilityLabel = name
        updateFocusAppearance(isFocused)
        guard let url else {
            loadTask?.cancel()
            self.url = nil
            showMissingPoster(onMissing)
            return
        }
        guard self.url != url else { return }
        self.url = url
        loadTask?.cancel()

        placeholder.isHidden = true
        if let image = CinemaImageCache.cached(url) {
            poster.image = UIImage(cgImage: image)
            spinner.isHidden = true
            return
        }
        poster.image = nil
        spinner.isHidden = false
        loadTask = Task { [weak self] in
            var delay = 2
            while !Task.isCancelled {
                do {
                    let image = try await CinemaImageCache.shared.image(for: url)
                    guard !Task.isCancelled else { return }
                    self?.poster.image = UIImage(cgImage: image)
                    self?.spinner.isHidden = true
                    return
                } catch CinemaImageError.missing {
                    guard !Task.isCancelled else { return }
                    self?.showMissingPoster(onMissing)
                    return
                } catch {
                    guard self != nil, !Task.isCancelled,
                          (try? await Task.sleep(for: .seconds(delay))) != nil else { return }
                    delay = min(delay * 2, 30)
                }
            }
        }
    }

    private func showMissingPoster(_ onMissing: (() -> Void)?) {
        if let onMissing {
            onMissing()
        } else {
            poster.image = nil
            spinner.isHidden = true
            placeholder.isHidden = false
        }
    }
}
