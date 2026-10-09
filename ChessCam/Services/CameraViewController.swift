import UIKit
import AVFoundation

final class CameraViewController: UIViewController {
    private let previewView = CameraPreviewView()
    private let messageLabel = UILabel()
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "ChessCam.camera.session")
    private var isSessionConfigured = false
    private var isVisible = false
    private var isRequestingPermission = false
    private var isMirrored: Bool

    init(mirrored: Bool) {
        isMirrored = mirrored
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("Programmatic UI")
    }

    override func loadView() {
        view = previewView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        previewView.backgroundColor = .black
        previewView.previewLayer.session = session
        previewView.previewLayer.videoGravity = .resizeAspectFill

        messageLabel.textColor = .white
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.font = .systemFont(ofSize: 16)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        previewView.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: previewView.centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: previewView.centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: previewView.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: previewView.trailingAnchor, constant: -24)
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        prepareCamera()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        let session = session
        sessionQueue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    func setMirrored(_ mirrored: Bool) {
        isMirrored = mirrored
        updatePreviewMirroring()
    }

    private func prepareCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCamera()
        case .notDetermined:
            guard !isRequestingPermission else { return }
            isRequestingPermission = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRequestingPermission = false
                    guard self.isVisible else { return }
                    if granted {
                        self.startCamera()
                    } else {
                        self.showMessage("Разрешите доступ к камере в настройках iPhone.")
                    }
                }
            }
        case .denied, .restricted:
            showMessage("Разрешите доступ к камере в настройках iPhone.")
        @unknown default:
            showMessage("Камера недоступна.")
        }
    }

    private func startCamera() {
        messageLabel.isHidden = true
        let session = session
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isSessionConfigured {
                guard let camera = AVCaptureDevice.default(
                    .builtInWideAngleCamera, for: .video, position: .front
                ), let input = try? AVCaptureDeviceInput(device: camera) else {
                    DispatchQueue.main.async { self.showMessage("Фронтальная камера недоступна.") }
                    return
                }

                session.beginConfiguration()
                session.sessionPreset = .high
                guard session.canAddInput(input) else {
                    session.commitConfiguration()
                    DispatchQueue.main.async { self.showMessage("Не удалось открыть камеру.") }
                    return
                }
                session.addInput(input)
                session.commitConfiguration()
                self.isSessionConfigured = true
                DispatchQueue.main.async { self.updatePreviewMirroring() }
            }
            if !session.isRunning { session.startRunning() }
        }
    }

    private func updatePreviewMirroring() {
        guard let connection = previewView.previewLayer.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = isMirrored
    }

    private func showMessage(_ text: String) {
        messageLabel.text = text
        messageLabel.isHidden = false
    }
}

private final class CameraPreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
