import UIKit
import WebKit

final class ChessWebViewController: UIViewController {
    let boardBridge = ChessBoardBridge()
    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        boardBridge.install(into: configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        boardBridge.attach(webView)
        return webView
    }()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private var site: ChessSite

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
        loadSite()
    }

    func show(_ site: ChessSite) {
        guard self.site != site else { return }
        boardBridge.clearState()
        self.site = site
        if isViewLoaded { loadSite() }
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
        boardBridge.clearState()
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
