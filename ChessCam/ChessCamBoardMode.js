// ChessCam — режим «Только доска» для chess.com и lichess.org
// Вставляется в WKWebView как WKUserScript (injectionTime: .atDocumentEnd, forMainFrameOnly: true).
// Сообщения в приложение: window.webkit.messageHandlers.chesscam.postMessage({type, data})
//   type "state": { boardFound, boardMode, live, top:{name,avatar,time,active}, bottom:{...} }  — 4 раза в секунду
// Управление из приложения: window.__cc.toggle(), window.__cc.setMode('auto'|'on'|'off'), window.__cc.refit()
(function () {
  if (window.__cc) { window.__cc.refit(); return; }

  var SITES = [
    {
      name: 'lichess',
      host: /(^|\.)lichess\.org$/,
      board: ['.round__app__board.main-board', '.puzzle__board.main-board', '.analyse__board.main-board', '.main-board'],
      clockTop: '.rclock-top', clockBottom: '.rclock-bottom',
      nameTop: '.ruser-top', nameBottom: '.ruser-bottom',
      avatarTop: null, avatarBottom: null,
      gamePage: function () { return !!document.querySelector('.round__app'); }, // страница партии (своей или TV)
      gameOver: '.result-wrap, .rcontrols .follow-up',
      firstMove: '[class*="expiration"]'
    },
    {
      name: 'chesscom',
      host: /(^|\.)chess\.com$/,
      board: ['#board-layout-chessboard wc-chess-board', '#board-single', 'wc-chess-board', 'chess-board'],
      clockTop: '#board-layout-player-top', clockBottom: '#board-layout-player-bottom',
      nameTop: '#board-layout-player-top [data-test-element="user-tagline-username"]',
      nameBottom: '#board-layout-player-bottom [data-test-element="user-tagline-username"]',
      avatarTop: '#board-layout-player-top img', avatarBottom: '#board-layout-player-bottom img',
      gamePage: function () { return /^\/(game\/(live|daily)\/|game\/\d|live\/game)/.test(location.pathname); },
      gameOver: '[class*="game-over-modal"], .board-modal-container-container .game-over',
      firstMove: '[class*="first-move"]'
    }
  ];

  var site = null;
  for (var i = 0; i < SITES.length; i++) if (SITES[i].host.test(location.hostname)) site = SITES[i];
  if (!site) return;

  var style = document.createElement('style');
  style.id = 'cc-board-mode';
  (document.head || document.documentElement).appendChild(style);

  var mode = 'auto';            // 'auto' — само; 'on'/'off' — пользователь нажал кнопку
  var modeUrl = location.href;  // ручной режим действует до смены страницы
  var applied = '';             // ключ применённого стиля
  var lastLiveAt = 0;
  var lastTimes = '';

  function q(sel) { return sel ? document.querySelector(sel) : null; }
  function txt(el) { return el ? (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim() : ''; }

  function findBoard() {
    var cur = document.querySelector('[data-cc-board]');
    if (cur && cur.isConnected && cur.offsetWidth > 50) return cur;
    if (cur) cur.removeAttribute('data-cc-board');
    for (var i = 0; i < site.board.length; i++) {
      var list = document.querySelectorAll(site.board[i]);
      for (var j = 0; j < list.length; j++) {
        if (list[j].offsetWidth > 100) { list[j].setAttribute('data-cc-board', '1'); return list[j]; }
      }
    }
    return null;
  }

  // Часы: внутри контейнера ищем элемент, текст которого похож на время (0:59, 02:58, 0:07.3)
  var TIME = /^\d{1,2}(:\d{2}){1,2}(\.\d)?$/;
  function clockOf(sel) {
    var box = q(sel);
    if (!box) return null;
    var best = null;
    var all = [box].concat(Array.prototype.slice.call(box.querySelectorAll('*')));
    for (var i = all.length - 1; i >= 0; i--) {
      var t = (all[i].innerText || '').replace(/\s+/g, '');
      if (TIME.test(t)) { best = all[i]; break; }
    }
    if (!best) return null;
    var active = false;
    for (var e = best; e && e !== box.parentElement; e = e.parentElement) {
      if (/running|player-turn|clock-active|\bactive\b/.test(String(e.className))) { active = true; break; }
    }
    return { time: (best.innerText || '').replace(/\s+/g, ''), active: active };
  }

  function player(nameSel, avatarSel, clockSel) {
    var c = clockOf(clockSel);
    var n = txt(q(nameSel)).replace(/\s*\(?\d{3,4}\)?\s*$/, ''); // убираем рейтинг в конце
    var a = q(avatarSel);
    return { name: n, avatar: a && a.src ? a.src : '', time: c ? c.time : '', active: c ? c.active : false };
  }

  function isLive(top, bottom) {
    if (q(site.gameOver)) return false;
    var times = top.time + '|' + bottom.time;
    var now = Date.now();
    var signal = top.active || bottom.active || !!q(site.firstMove) ||
                 site.gamePage() ||
                 (lastTimes && times !== lastTimes && (top.time || bottom.time));
    lastTimes = times;
    if (signal) lastLiveAt = now;
    return now - lastLiveAt < 1500; // небольшая задержка, чтобы режим не мигал
  }

  function applyBoardMode(board) {
    var vw = document.documentElement.clientWidth || window.innerWidth;
    var vh = window.innerHeight;
    var size = Math.floor(Math.min(vw, vh));
    var left = Math.floor((vw - size) / 2);
    var top = Math.floor((vh - size) / 2);
    var key = size + ':' + left + ':' + top;
    if (applied === key) return;
    applied = key;
    style.textContent =
      'html,body{overflow:hidden!important;overscroll-behavior:none!important;touch-action:none!important;}' +
      '[data-cc-board]{position:fixed!important;left:' + left + 'px!important;top:' + top + 'px!important;' +
      'width:' + size + 'px!important;height:' + size + 'px!important;min-width:0!important;min-height:0!important;' +
      'max-width:none!important;max-height:none!important;margin:0!important;padding:0!important;' +
      'transform:none!important;z-index:2147483646!important;touch-action:none!important;}' +
      'html::after{content:"";position:fixed;inset:0;background:#262421;z-index:2147483645;}';
    window.scrollTo(0, 0);
    // сайты пересчитывают координаты клеток по resize — без этого ходы попадали бы мимо
    window.dispatchEvent(new Event('resize'));
    try { document.body.dispatchEvent(new Event('chessground.resize')); } catch (e) {}
  }

  function clearBoardMode() {
    if (!applied) return;
    applied = '';
    style.textContent = '';
    window.dispatchEvent(new Event('resize'));
    try { document.body.dispatchEvent(new Event('chessground.resize')); } catch (e) {}
  }

  var state = {};
  function tick() {
    if (location.href !== modeUrl) { mode = 'auto'; modeUrl = location.href; }
    var board = findBoard();
    var top = player(site.nameTop, site.avatarTop, site.clockTop);
    var bottom = player(site.nameBottom, site.avatarBottom, site.clockBottom);
    var live = isLive(top, bottom);
    var on = !!board && (mode === 'on' || (mode === 'auto' && live));
    if (on) applyBoardMode(board); else clearBoardMode();
    state = { site: site.name, boardFound: !!board, boardMode: on, live: live, mode: mode, top: top, bottom: bottom };
    try { window.webkit.messageHandlers.chesscam.postMessage({ type: 'state', data: state }); } catch (e) {}
  }

  var pending = false;
  function soon() {
    if (pending) return;
    pending = true;
    requestAnimationFrame(function () { pending = false; tick(); });
  }
  new MutationObserver(soon).observe(document.documentElement, { childList: true, subtree: true });
  // реальный поворот/изменение размера: ключ размера сам изменится, и стиль пересчитается.
  // Наши собственные события resize (из applyBoardMode) сюда тоже попадут, но tick идемпотентен — цикла нет.
  window.addEventListener('resize', soon);
  setInterval(tick, 250);

  window.__cc = {
    // кнопка «⤢»: включить/выключить режим доски вручную
    toggle: function () { mode = state.boardMode ? 'off' : 'on'; modeUrl = location.href; applied = applied ? 'stale' : ''; tick(); return mode; },
    setMode: function (m) { mode = m; modeUrl = location.href; applied = applied ? 'stale' : ''; tick(); return mode; },
    refit: function () { applied = applied ? 'stale' : ''; tick(); return state; },
    state: function () { return state; }
  };
  tick();
})();
