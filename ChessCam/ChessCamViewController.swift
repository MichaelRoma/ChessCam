import UIKit

final class ChessCamViewController: UIViewController {
    private let green = UIColor(red: 0.29, green: 0.49, blue: 0.30, alpha: 1)
    private var settings = AppSettings.load()
    private lazy var chessWebController = ChessWebViewController(site: settings.site)
    private lazy var cameraController = CameraViewController(mirrored: settings.mirrorCamera)
    private var webHeightConstraint: NSLayoutConstraint!
    private var fileStore: RecordingFileStore?
    private var recordingService: ScreenRecordingService?
    private let photoExporter = PhotoLibraryExporter()
    private var storageError: Error?
    private let recordButton = UIButton(type: .system)
    private let recordingTimerLabel = UILabel()
    private var recordingTimer: Timer?
    private var recordingStartDate: Date?
    private var isRecordingUI = false

    override var prefersStatusBarHidden: Bool { isRecordingUI }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "ChessCam"
        view.backgroundColor = .white
        do {
            let store = try RecordingFileStore()
            fileStore = store
            recordingService = ScreenRecordingService(fileStore: store)
        } catch {
            storageError = error
        }
        configureNavigationBar()
        buildContent()
    }
}

private extension ChessCamViewController {
    func configureNavigationBar() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "‹ Записи", style: .plain, target: self, action: #selector(openRecordings)
        )
        navigationItem.leftBarButtonItem?.tintColor = green
        navigationItem.backButtonDisplayMode = .minimal
        navigationController?.navigationBar.tintColor = green
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            style: .plain,
            target: self,
            action: #selector(openSettings)
        )
        navigationItem.rightBarButtonItem?.tintColor = green

        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = .white
        appearance.shadowColor = UIColor.systemGray5
        navigationController?.navigationBar.standardAppearance = appearance
        navigationController?.navigationBar.scrollEdgeAppearance = appearance
    }

    func buildContent() {
        addChild(chessWebController)
        addChild(cameraController)
        let webContentView = chessWebController.view!
        let cameraContentView = cameraController.view!

        let content = UIStackView(arrangedSubviews: [webContentView, cameraContentView])
        content.axis = .vertical
        content.spacing = 0
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)

        webHeightConstraint = webContentView.heightAnchor.constraint(
            equalTo: cameraContentView.heightAnchor,
            multiplier: CGFloat(settings.boardFraction / (1 - settings.boardFraction))
        )

        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            webHeightConstraint
        ])

        recordButton.setTitle("●  Начать запись", for: .normal)
        recordButton.setTitleColor(.white, for: .normal)
        recordButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        recordButton.backgroundColor = UIColor(red: 0.91, green: 0.18, blue: 0.18, alpha: 1)
        recordButton.layer.cornerRadius = 27
        recordButton.addTarget(self, action: #selector(startRecording), for: .touchUpInside)
        recordButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(recordButton)

        recordingTimerLabel.font = .monospacedDigitSystemFont(ofSize: 19, weight: .semibold)
        recordingTimerLabel.textColor = .white
        recordingTimerLabel.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        recordingTimerLabel.textAlignment = .center
        recordingTimerLabel.layer.cornerRadius = 8
        recordingTimerLabel.layer.masksToBounds = true
        recordingTimerLabel.isHidden = true
        recordingTimerLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(recordingTimerLabel)

        let stopGesture = UITapGestureRecognizer(target: self, action: #selector(stopRecording))
        stopGesture.numberOfTapsRequired = 2
        cameraContentView.addGestureRecognizer(stopGesture)

        NSLayoutConstraint.activate([
            recordButton.centerXAnchor.constraint(equalTo: cameraContentView.centerXAnchor),
            recordButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            recordButton.widthAnchor.constraint(equalToConstant: 220),
            recordButton.heightAnchor.constraint(equalToConstant: 54),
            recordingTimerLabel.topAnchor.constraint(equalTo: cameraContentView.topAnchor, constant: 12),
            recordingTimerLabel.trailingAnchor.constraint(equalTo: cameraContentView.trailingAnchor, constant: -12),
            recordingTimerLabel.widthAnchor.constraint(equalToConstant: 86),
            recordingTimerLabel.heightAnchor.constraint(equalToConstant: 36)
        ])
        chessWebController.didMove(toParent: self)
        cameraController.didMove(toParent: self)
    }

    @objc func openRecordings() {
        guard let fileStore else {
            showError(storageError ?? ScreenRecordingService.RecordingError.unavailable)
            return
        }
        navigationController?.pushViewController(RecordingsViewController(fileStore: fileStore), animated: true)
    }

    @objc func openSettings() {
        let controller = SettingsViewController(settings: settings)
        controller.onSave = { [weak self] updatedSettings in
            self?.applySettings(updatedSettings)
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    func applySettings(_ updatedSettings: AppSettings) {
        let siteChanged = settings.site != updatedSettings.site
        let fractionChanged = settings.boardFraction != updatedSettings.boardFraction
        settings = updatedSettings
        settings.save()
        if siteChanged { chessWebController.show(settings.site) }
        cameraController.setMirrored(settings.mirrorCamera)
        if fractionChanged {
            webHeightConstraint.isActive = false
            webHeightConstraint = chessWebController.view.heightAnchor.constraint(
                equalTo: cameraController.view.heightAnchor,
                multiplier: CGFloat(settings.boardFraction / (1 - settings.boardFraction))
            )
            webHeightConstraint.isActive = true
        }
    }

    @objc func startRecording() {
        guard let recordingService else {
            showError(storageError ?? ScreenRecordingService.RecordingError.unavailable)
            return
        }
        recordButton.isEnabled = false
        Task { [weak self] in
            guard let self else { return }
            defer { self.recordButton.isEnabled = true }
            do {
                try await recordingService.start()
                self.enterRecordingMode()
            } catch {
                self.showError(error)
            }
        }
    }

    @objc func stopRecording() {
        guard let recordingService, recordingService.state == .recording else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let recording = try await recordingService.stop()
                self.leaveRecordingMode()
                if self.settings.saveToPhotos {
                    do {
                        try await self.photoExporter.saveVideo(at: recording.url)
                        self.showMessage("Видео сохранено в ChessCam и Фото")
                    } catch {
                        self.showMessage("Видео сохранено в ChessCam. Не удалось добавить его в Фото: \(error.localizedDescription)")
                    }
                } else {
                    self.showMessage("Видео сохранено в ChessCam")
                }
            } catch {
                if recordingService.state == .idle { self.leaveRecordingMode() }
                self.showError(error)
            }
        }
    }

    func enterRecordingMode() {
        isRecordingUI = true
        recordButton.isHidden = true
        recordingStartDate = Date()
        recordingTimerLabel.isHidden = false
        updateRecordingTimer()
        recordingTimer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(updateRecordingTimer),
            userInfo: nil,
            repeats: true
        )
        UIApplication.shared.isIdleTimerDisabled = true
        navigationController?.setNavigationBarHidden(true, animated: false)
        setNeedsStatusBarAppearanceUpdate()
    }

    func leaveRecordingMode() {
        isRecordingUI = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingStartDate = nil
        recordingTimerLabel.isHidden = true
        recordButton.isHidden = false
        UIApplication.shared.isIdleTimerDisabled = false
        navigationController?.setNavigationBarHidden(false, animated: false)
        setNeedsStatusBarAppearanceUpdate()
    }

    @objc func updateRecordingTimer() {
        guard let recordingStartDate else { return }
        let seconds = Int(Date().timeIntervalSince(recordingStartDate))
        recordingTimerLabel.text = String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func showError(_ error: Error) {
        let alert = UIAlertController(title: "Ошибка", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func showMessage(_ message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
