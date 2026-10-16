// ChessBoardBridge.swift
// Связь приложения с сайтом (chess.com / lichess.org) внутри WKWebView:
//  • подключает ChessCamBoardMode.js (доска сама встаёт на всю ширину, когда идёт партия);
//  • получает со страницы имена, аватарки и время обоих игроков (4 раза в секунду);
//  • даёт кнопке «⤢» переключать режим доски вручную.
//
// Подключение (один раз, при создании WKWebView):
//   let bridge = ChessBoardBridge()
//   let config = WKWebViewConfiguration()
//   bridge.install(into: config)
//   let webView = WKWebView(frame: .zero, configuration: config)
//   bridge.attach(webView)

import Foundation
import WebKit
import Combine

struct ChessPlayer: Equatable {
    var name: String = ""
    var avatarURL: URL? = nil
    var time: String = ""      // "2:58", "00:44", "0:07.3"
    var isActive: Bool = false // сейчас ход этого игрока

    /// Меньше 20 секунд — подсвечиваем красным
    var isLowTime: Bool {
        let parts = time.split(separator: ":").compactMap { Double($0) }
        guard parts.count >= 2 else { return false }
        let seconds = parts.reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
        return seconds < 20
    }
}

final class ChessBoardBridge: NSObject, ObservableObject {
    @Published private(set) var opponent = ChessPlayer() // верхний игрок на доске
    @Published private(set) var me = ChessPlayer()       // нижний игрок на доске
    @Published private(set) var boardFound = false
    @Published private(set) var boardMode = false        // доска сейчас развёрнута на весь блок

    private weak var webView: WKWebView?
    private static let handlerName = "chesscam"

    // MARK: Подключение

    func install(into config: WKWebViewConfiguration) {
        guard let url = Bundle.main.url(forResource: "ChessCamBoardMode", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            assertionFailure("ChessCamBoardMode.js не добавлен в Copy Bundle Resources")
            return
        }
        let script = WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        // WeakHandler — чтобы WKUserContentController не держал bridge навсегда
        config.userContentController.add(WeakHandler(self), name: Self.handlerName)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
    }

    func attach(_ webView: WKWebView) {
        self.webView = webView
        let sv = webView.scrollView
        // Нативный зум и прокрутка больше не нужны: доску ставит скрипт.
        // Если оставить зум, старое увеличение ломает подгонку.
        sv.contentInsetAdjustmentBehavior = .never
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 1
        sv.setZoomScale(1, animated: false)
        sv.bouncesZoom = false
        sv.bounces = false
        sv.pinchGestureRecognizer?.isEnabled = false
    }

    func clearState() {
        opponent = ChessPlayer()
        me = ChessPlayer()
        boardFound = false
        boardMode = false
    }

    // MARK: Кнопка «⤢»

    /// Включить/выключить режим доски вручную (действует до перехода на другую страницу)
    func toggleBoardMode() {
        webView?.evaluateJavaScript("window.__cc ? window.__cc.toggle() : null", completionHandler: nil)
    }

    /// Пересчитать подгонку (например, после изменения размеров верхнего блока)
    func refit() {
        webView?.evaluateJavaScript("window.__cc ? window.__cc.refit() && 1 : null", completionHandler: nil)
    }

    // MARK: Данные со страницы

    fileprivate func receive(_ body: Any) {
        guard let dict = body as? [String: Any],
              (dict["type"] as? String) == "state",
              let data = dict["data"] as? [String: Any] else { return }

        let top = Self.parsePlayer(data["top"])
        let bottom = Self.parsePlayer(data["bottom"])
        let found = data["boardFound"] as? Bool ?? false
        let mode = data["boardMode"] as? Bool ?? false

        DispatchQueue.main.async {
            if self.opponent != top { self.opponent = top }
            if self.me != bottom { self.me = bottom }
            if self.boardFound != found { self.boardFound = found }
            if self.boardMode != mode { self.boardMode = mode }
        }
    }

    private static func parsePlayer(_ any: Any?) -> ChessPlayer {
        guard let p = any as? [String: Any] else { return ChessPlayer() }
        let avatar = (p["avatar"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return ChessPlayer(name: p["name"] as? String ?? "",
                           avatarURL: avatar,
                           time: p["time"] as? String ?? "",
                           isActive: p["active"] as? Bool ?? false)
    }
}

private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: ChessBoardBridge?
    init(_ target: ChessBoardBridge) { self.target = target }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message.body)
    }
}
