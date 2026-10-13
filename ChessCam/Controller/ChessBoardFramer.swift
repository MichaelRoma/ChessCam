import UIKit
import WebKit

@MainActor
final class ChessBoardFramer {
    enum FramingError: LocalizedError {
        case boardNotFound
        case invalidGeometry
        case zoomUnavailable
        case centeringUnavailable
        case pageChanged
        case pageUnavailable

        var errorDescription: String? {
            switch self {
            case .boardNotFound:
                return "Доска не найдена. Откройте партию или анализ на Chess.com либо Lichess и попробуйте ещё раз."
            case .invalidGeometry:
                return "Не удалось определить размер доски. Дождитесь загрузки страницы и попробуйте ещё раз."
            case .zoomUnavailable:
                return "Эта страница не позволила изменить масштаб доски. Попробуйте обновить её и повторить подгонку."
            case .centeringUnavailable:
                return "Не удалось полностью показать доску. Попробуйте прокрутить страницу и повторить подгонку."
            case .pageChanged:
                return "Страница изменилась во время подгонки доски."
            case .pageUnavailable:
                return "Не удалось прочитать страницу. Дождитесь её загрузки и попробуйте ещё раз."
            }
        }
    }

    private struct SavedState {
        let zoomScale: CGFloat
        let minimumZoomScale: CGFloat
        let maximumZoomScale: CGFloat
        let contentOffset: CGPoint
        let contentInset: UIEdgeInsets
    }

    private struct BoardGeometry {
        let rect: CGRect
        let viewportWidth: CGFloat

        func rectInPoints(for scrollView: UIScrollView, includingOverscroll: Bool) -> CGRect {
            let pointsPerCSSPixel = scrollView.bounds.width / viewportWidth
            // During native overscroll WebKit moves the rendered page, while
            // getBoundingClientRect() stays at the CSS viewport position.
            let extraX = includingOverscroll ? max(0, -scrollView.contentOffset.x) : 0
            let extraY = includingOverscroll ? max(0, -scrollView.contentOffset.y) : 0
            return CGRect(
                x: rect.minX * pointsPerCSSPixel + extraX,
                y: rect.minY * pointsPerCSSPixel + extraY,
                width: rect.width * pointsPerCSSPixel,
                height: rect.height * pointsPerCSSPixel
            )
        }
    }

    private weak var webView: WKWebView?
    private var savedState: SavedState?
    private var pageRevision = 0

    var isFramed: Bool { savedState != nil }

    init(webView: WKWebView) {
        self.webView = webView
    }

    func frameBoard() async throws {
        guard let webView, !isFramed else { return }

        let revision = pageRevision
        var board = try await measureBoard(in: webView, revision: revision)
        let scrollView = webView.scrollView
        let bounds = scrollView.bounds
        let host = webView.url?.host?.lowercased() ?? ""
        let isLichess = host == "lichess.org" || host.hasSuffix(".lichess.org")
        let margin: CGFloat = 12
        let topClearance = min(CGFloat(64), bounds.height * 0.18)
        let usableRect = CGRect(
            x: margin,
            y: topClearance,
            width: bounds.width - margin * 2,
            height: bounds.height - topClearance - margin
        )
        guard usableRect.width > 0, usableRect.height > 0,
              scrollView.zoomScale > 0 else {
            throw FramingError.invalidGeometry
        }

        let state = SavedState(
            zoomScale: scrollView.zoomScale,
            minimumZoomScale: scrollView.minimumZoomScale,
            maximumZoomScale: scrollView.maximumZoomScale,
            contentOffset: scrollView.contentOffset,
            contentInset: scrollView.contentInset
        )
        // Store the state before any change so navigation can undo a partially
        // completed framing operation while JavaScript is being evaluated.
        savedState = state
        scrollView.contentInset = UIEdgeInsets(
            top: state.contentInset.top + bounds.height / 2,
            left: state.contentInset.left + bounds.width / 2,
            bottom: state.contentInset.bottom + bounds.height / 2,
            right: state.contentInset.right + bounds.width / 2
        )

        do {
            // Both sites can resize their board after WebKit zooms. Re-read the
            // rendered rectangle instead of extrapolating its old document offset.
            for _ in 0..<3 {
                board = try await measureBoard(in: webView, revision: revision)
                let rect = board.rectInPoints(for: scrollView, includingOverscroll: isLichess)
                let fitFactor = min(usableRect.width / rect.width, usableRect.height / rect.height)
                // Lichess already sizes its mobile board to the viewport. Zooming
                // it in can push it sideways when horizontal scrolling is locked.
                let factor = isLichess ? min(1, fitFactor) : fitFactor
                guard factor.isFinite, factor > 0 else { throw FramingError.invalidGeometry }
                if abs(factor - 1) < 0.02 { break }

                let zoom = scrollView.zoomScale * factor
                guard zoom.isFinite, zoom > 0 else { throw FramingError.invalidGeometry }
                scrollView.minimumZoomScale = min(scrollView.minimumZoomScale, zoom)
                scrollView.maximumZoomScale = max(scrollView.maximumZoomScale, zoom)
                scrollView.setZoomScale(zoom, animated: false)
                webView.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 50_000_000)

                let updated = try await measureBoard(in: webView, revision: revision)
                let updatedRect = updated.rectInPoints(for: scrollView, includingOverscroll: isLichess)
                board = updated
                // A responsive board can retain the same screen size while the
                // surrounding page zooms. Repeating that zoom would not help.
                if factor > 1,
                   updatedRect.width <= rect.width * 1.01,
                   updatedRect.height <= rect.height * 1.01 {
                    break
                }
            }

            var rect = board.rectInPoints(for: scrollView, includingOverscroll: isLichess)
            guard rect.width <= usableRect.width + 6,
                  rect.height <= usableRect.height + 6 else {
                throw FramingError.zoomUnavailable
            }

            for _ in 0..<3 {
                let delta = CGPoint(
                    x: rect.midX - usableRect.midX,
                    y: rect.midY - usableRect.midY
                )
                if abs(delta.x) < 2, abs(delta.y) < 2 { break }
                scrollView.setContentOffset(
                    CGPoint(
                        x: scrollView.contentOffset.x + delta.x,
                        y: scrollView.contentOffset.y + delta.y
                    ),
                    animated: false
                )
                webView.layoutIfNeeded()
                try await Task.sleep(nanoseconds: 50_000_000)
                board = try await measureBoard(in: webView, revision: revision)
                rect = board.rectInPoints(for: scrollView, includingOverscroll: isLichess)
            }

            let horizontallyPlaced = abs(rect.midX - usableRect.midX) < 10 ||
                (isLichess && rect.minX >= 4 && rect.maxX <= bounds.width - 4)
            guard horizontallyPlaced,
                  abs(rect.midY - usableRect.midY) < 10,
                  rect.width <= usableRect.width + 6,
                  rect.height <= usableRect.height + 6 else {
                throw FramingError.centeringUnavailable
            }
        } catch {
            if revision == pageRevision { restore() }
            throw error
        }
    }

    private func measureBoard(in webView: WKWebView, revision: Int) async throws -> BoardGeometry {
        let result: Any?
        do {
            result = try await webView.evaluateJavaScript(Self.measureBoardScript)
        } catch {
            if revision != pageRevision { throw FramingError.pageChanged }
            throw FramingError.pageUnavailable
        }
        guard revision == pageRevision else { throw FramingError.pageChanged }
        guard let values = result as? [String: Any] else { throw FramingError.boardNotFound }

        func number(_ key: String) throws -> CGFloat {
            guard let value = values[key] as? NSNumber,
                  value.doubleValue.isFinite else {
                throw FramingError.invalidGeometry
            }
            return CGFloat(value.doubleValue)
        }

        let rect = CGRect(
            x: try number("x"),
            y: try number("y"),
            width: try number("width"),
            height: try number("height")
        )
        let viewportWidth = try number("viewportWidth")
        guard rect.width > 0, rect.height > 0, viewportWidth > 0 else {
            throw FramingError.invalidGeometry
        }
        return BoardGeometry(rect: rect, viewportWidth: viewportWidth)
    }

    func restore() {
        pageRevision += 1
        guard let webView, let state = savedState else { return }
        savedState = nil
        restore(state, in: webView.scrollView)
    }

    private func restore(_ state: SavedState, in scrollView: UIScrollView) {
        scrollView.minimumZoomScale = min(scrollView.minimumZoomScale, state.zoomScale)
        scrollView.maximumZoomScale = max(scrollView.maximumZoomScale, state.zoomScale)
        scrollView.setZoomScale(state.zoomScale, animated: false)
        scrollView.contentInset = state.contentInset
        scrollView.minimumZoomScale = state.minimumZoomScale
        scrollView.maximumZoomScale = state.maximumZoomScale
        scrollView.layoutIfNeeded()
        scrollView.setContentOffset(state.contentOffset, animated: false)
    }

    private static let measureBoardScript = #"""
    (() => {
        const host = location.hostname.toLowerCase();
        const belongsTo = domain => host === domain || host.endsWith('.' + domain);
        const selector = belongsTo('lichess.org')
            ? 'cg-board'
            : belongsTo('chess.com')
                ? 'wc-chess-board, chess-board'
                : null;
        if (!selector) return null;

        const boards = Array.from(document.querySelectorAll(selector))
            .map(element => {
                for (let node = element; node && node.nodeType === 1; node = node.parentElement) {
                    const style = getComputedStyle(node);
                    if (style.display === 'none' || style.visibility === 'hidden' ||
                        Number(style.opacity) === 0) return null;
                }
                const rect = element.getBoundingClientRect();
                const ratio = rect.width / rect.height;
                return rect.width >= 120 && rect.height >= 120 &&
                    ratio > 0.8 && ratio < 1.2 ? rect : null;
            })
            .filter(Boolean)
            .sort((a, b) => b.width * b.height - a.width * a.height);

        const board = boards[0];
        if (!board) return null;
        const viewport = window.visualViewport;
        return {
            x: board.left - (viewport?.offsetLeft ?? 0),
            y: board.top - (viewport?.offsetTop ?? 0),
            width: board.width,
            height: board.height,
            viewportWidth: viewport?.width ?? window.innerWidth
        };
    })();
    """#
}
