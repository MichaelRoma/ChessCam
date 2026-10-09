import AVFoundation
import UIKit

final class RecordingCollectionViewCell: UICollectionViewCell {
    private static let imageCache = NSCache<NSURL, UIImage>()
    var onMore: ((UIButton) -> Void)?

    private let thumbnailImageView = UIImageView()
    private let durationLabel = UILabel()
    private let dateLabel = UILabel()
    private let detailsLabel = UILabel()
    private let moreButton = UIButton(type: .system)
    private var thumbnailTask: Task<Void, Never>?
    private var representedURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("Programmatic UI") }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        representedURL = nil
        thumbnailImageView.image = nil
        onMore = nil
    }

    func configure(date: String, duration: String, size: String, videoURL: URL) {
        dateLabel.text = date
        detailsLabel.text = "\(duration)  ·  \(size)"
        durationLabel.text = duration
        accessibilityLabel = "Запись \(date), \(duration), \(size)"

        guard representedURL != videoURL else { return }
        thumbnailTask?.cancel()
        representedURL = videoURL
        let cacheKey = videoURL as NSURL
        if let cached = Self.imageCache.object(forKey: cacheKey) {
            thumbnailImageView.image = cached
            return
        }

        thumbnailImageView.image = nil
        thumbnailTask = Task { [weak self] in
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 300, height: 200)
            guard let result = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)),
                  !Task.isCancelled,
                  let self,
                  self.representedURL == videoURL else { return }
            let image = UIImage(cgImage: result.image)
            Self.imageCache.setObject(image, forKey: cacheKey)
            self.thumbnailImageView.image = image
        }
    }

    private func buildContent() {
        contentView.backgroundColor = UIColor(red: 0.91, green: 0.91, blue: 0.92, alpha: 1)
        contentView.layer.cornerRadius = 16
        contentView.layer.masksToBounds = true

        thumbnailImageView.backgroundColor = .systemGray4
        thumbnailImageView.contentMode = .scaleAspectFill
        thumbnailImageView.layer.cornerRadius = 10
        thumbnailImageView.layer.masksToBounds = true
        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(thumbnailImageView)

        durationLabel.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        durationLabel.textColor = .white
        durationLabel.textAlignment = .center
        durationLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        durationLabel.layer.cornerRadius = 5
        durationLabel.layer.masksToBounds = true
        durationLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(durationLabel)

        dateLabel.font = .systemFont(ofSize: 15, weight: .medium)
        dateLabel.adjustsFontSizeToFitWidth = true
        dateLabel.minimumScaleFactor = 0.8
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(dateLabel)

        detailsLabel.font = .systemFont(ofSize: 14)
        detailsLabel.textColor = .secondaryLabel
        detailsLabel.adjustsFontSizeToFitWidth = true
        detailsLabel.minimumScaleFactor = 0.8
        detailsLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(detailsLabel)

        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = .secondaryLabel
        moreButton.accessibilityLabel = "Действия с записью"
        moreButton.addTarget(self, action: #selector(showMore), for: .touchUpInside)
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(moreButton)

        NSLayoutConstraint.activate([
            thumbnailImageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            thumbnailImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            thumbnailImageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            thumbnailImageView.widthAnchor.constraint(equalToConstant: 150),

            durationLabel.trailingAnchor.constraint(equalTo: thumbnailImageView.trailingAnchor, constant: -5),
            durationLabel.bottomAnchor.constraint(equalTo: thumbnailImageView.bottomAnchor, constant: -5),
            durationLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
            durationLabel.heightAnchor.constraint(equalToConstant: 22),

            dateLabel.leadingAnchor.constraint(equalTo: thumbnailImageView.trailingAnchor, constant: 12),
            dateLabel.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -2),
            dateLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 27),

            detailsLabel.leadingAnchor.constraint(equalTo: dateLabel.leadingAnchor),
            detailsLabel.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -2),
            detailsLabel.topAnchor.constraint(equalTo: dateLabel.bottomAnchor, constant: 7),

            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            moreButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 28),
            moreButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    @objc private func showMore() {
        onMore?(moreButton)
    }
}
