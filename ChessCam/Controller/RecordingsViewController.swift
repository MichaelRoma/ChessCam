import AVFoundation
import AVKit
import UIKit

final class RecordingsViewController: UIViewController {
    private nonisolated enum Section: Int { case recordings }

    private nonisolated struct Recording: Hashable, Sendable {
        let id: UUID
        let url: URL
        let date: String
        let duration: String
        let size: String
    }

    private let fileStore: RecordingFileStore
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: Self.makeLayout())
    private let emptyLabel = UILabel()
    private var dataSource: UICollectionViewDiffableDataSource<Section, Recording>!
    private var metadataTask: Task<Void, Never>?

    init(fileStore: RecordingFileStore) {
        self.fileStore = fileStore
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic UI") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Мои записи"
        view.backgroundColor = UIColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1)

        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        emptyLabel.text = "Записей пока нет"
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        configureDataSource()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadRecordings()
    }

    private static func makeLayout() -> UICollectionViewLayout {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .absolute(106))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = 10
        section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)
        return UICollectionViewCompositionalLayout(section: section)
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<RecordingCollectionViewCell, Recording> { [weak self]
            cell, _, recording in
            cell.configure(
                date: recording.date,
                duration: recording.duration,
                size: recording.size,
                videoURL: recording.url
            )
            cell.onMore = { [weak self] button in
                self?.showActions(for: recording, from: button)
            }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, recording in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: recording)
        }
    }

    private func loadRecordings() {
        metadataTask?.cancel()
        do {
            let files = try fileStore.recordings()
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "ru_RU")
            dateFormatter.dateFormat = "d MMMM, HH:mm"
            let recordings = files.map { file in
                Recording(
                    id: file.id,
                    url: file.url,
                    date: dateFormatter.string(from: file.createdAt),
                    duration: "—:—",
                    size: ByteCountFormatter.string(fromByteCount: file.sizeInBytes, countStyle: .file)
                )
            }
            apply(recordings)

            metadataTask = Task { [weak self] in
                var updated = recordings
                for index in updated.indices {
                    guard !Task.isCancelled else { return }
                    let asset = AVURLAsset(url: updated[index].url)
                    if let duration = try? await asset.load(.duration) {
                        let seconds = max(0, Int(CMTimeGetSeconds(duration)))
                        let file = updated[index]
                        updated[index] = Recording(
                            id: file.id,
                            url: file.url,
                            date: file.date,
                            duration: String(format: "%02d:%02d", seconds / 60, seconds % 60),
                            size: file.size
                        )
                    }
                }
                guard !Task.isCancelled else { return }
                self?.apply(updated)
            }
        } catch {
            let alert = UIAlertController(title: "Не удалось открыть записи", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    private func apply(_ recordings: [Recording]) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Recording>()
        snapshot.appendSections([.recordings])
        snapshot.appendItems(recordings)
        dataSource.apply(snapshot, animatingDifferences: false)
        emptyLabel.isHidden = !recordings.isEmpty
    }

    private func showActions(for recording: Recording, from button: UIButton) {
        let actions = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        actions.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in
            self?.confirmDeletion(of: recording)
        })
        actions.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        actions.popoverPresentationController?.sourceView = button
        actions.popoverPresentationController?.sourceRect = button.bounds
        present(actions, animated: true)
    }

    private func confirmDeletion(of recording: Recording) {
        let alert = UIAlertController(
            title: "Удалить запись?",
            message: "Видео будет удалено из ChessCam.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Удалить", style: .destructive) { [weak self] _ in
            self?.delete(recording)
        })
        present(alert, animated: true)
    }

    private func delete(_ recording: Recording) {
        do {
            try fileStore.deleteRecording(id: recording.id)
            loadRecordings()
        } catch {
            let alert = UIAlertController(title: "Не удалось удалить запись", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}

extension RecordingsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let recording = dataSource.itemIdentifier(for: indexPath) else { return }
        collectionView.deselectItem(at: indexPath, animated: true)
        let player = AVPlayer(url: recording.url)
        let controller = AVPlayerViewController()
        controller.player = player
        present(controller, animated: true) { player.play() }
    }
}
