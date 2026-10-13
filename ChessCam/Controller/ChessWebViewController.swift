import UIKit
import WebKit

final class ChessWebViewController: UIViewController {
    private let webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.ignoresViewportScaleLimits = true
        return WKWebView(frame: .zero, configuration: configuration)
    }()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private lazy var boardFramer = ChessBoardFramer(webView: webView)
    private var urlObservation: NSKeyValueObservation?
    private var site: ChessSite
    var onBoardFramingChanged: ((Bool) -> Void)?

    init(site: ChessSite) {
        self.site = site
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("Programmatic UI")
    }

    override func loadView() {
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        activityIndicator.hidesWhenStopped = true
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(activityIndicator)
        NSLayoutConstraint.activate([
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        webView.navigationDelegate = self
        urlObservation = webView.observe(\.url, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue != change.newValue else { return }
            Task { @MainActor [weak self] in
                self?.resetBoardFraming()
            }
        }
        loadSite()
    }

    func show(_ site: ChessSite) {
        guard self.site != site else { return }
        resetBoardFraming()
        self.site = site
        if isViewLoaded { loadSite() }
    }

    func toggleBoardFraming() async throws -> Bool {
        if boardFramer.isFramed {
            resetBoardFraming()
        } else {
            try await boardFramer.frameBoard()
            onBoardFramingChanged?(true)
        }
        return boardFramer.isFramed
    }

    func resetBoardFraming() {
        let wasFramed = boardFramer.isFramed
        boardFramer.restore()
        if wasFramed { onBoardFramingChanged?(false) }
    }

    private func loadSite() {
        webView.load(URLRequest(url: site.url))
    }

    private func handleNavigationError(_ error: Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else {
            return
        }

        activityIndicator.stopAnimating()
        guard view.window != nil, presentedViewController == nil else { return }

        let message = nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorNotConnectedToInternet
            ? "Проверьте подключение к интернету."
            : "Не удалось открыть \(site.title)."
        let alert = UIAlertController(title: "Ошибка загрузки", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel))
        alert.addAction(UIAlertAction(title: "Повторить", style: .default) { [weak self] _ in
            self?.loadSite()
        })
        present(alert, animated: true)
    }
}

extension ChessWebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        resetBoardFraming()
        activityIndicator.startAnimating()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        activityIndicator.stopAnimating()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationError(error)
    }
}
