// Guest Web Player (spec 3.2 FR-4.2..4.4, 6.2.2). Plain JS, no build step.
// Guests are read-only: every write goes to the server, which answers 403 GUEST_WRITE_FORBIDDEN; the UI
// reacts to that answer (opens the progressive auth modal) instead of hiding controls.
(function () {
  'use strict';

  const API = '';  // same origin as the page (served by the core API on :8080)
  const CART_KEY = 'guest_cart';
  const TOKEN_KEY = 'guest_token';
  const HLS_CDN = 'https://cdn.jsdelivr.net/npm/hls.js@1.5.13/dist/hls.min.js';

  const $ = (sel) => document.querySelector(sel);
  const byTestId = (id) => document.querySelector(`[data-testid="${id}"]`);

  // ---------- session storage (survives reloads in this tab, gone when the tab closes) ----------
  function store(key, value) {
    try {
      if (value === undefined) return sessionStorage.getItem(key);
      if (value === null) sessionStorage.removeItem(key); else sessionStorage.setItem(key, value);
    } catch (_) { /* storage blocked: the page still works, the cart just is not kept */ }
    return null;
  }

  function readCart() {
    try { return JSON.parse(store(CART_KEY) || '[]'); } catch (_) { return []; }
  }

  function writeCart(items) {
    store(CART_KEY, JSON.stringify(items));
    renderCartCount();
  }

  function renderCartCount() {
    const el = byTestId('guest-cart-count');
    if (el) el.textContent = String(readCart().reduce((n, it) => n + (it.quantity || 0), 0));
  }

  // ---------- HTTP ----------
  async function getJson(path) {
    const res = await fetch(API + path, { headers: { Accept: 'application/json' } });
    if (!res.ok) throw new Error(`${path} -> ${res.status}`);
    return res.json();
  }

  async function guestToken() {
    let tok = store(TOKEN_KEY);
    if (tok) return tok;
    try {
      tok = (await getJson('/api/v1/public/guest-token')).guest_token;
      if (tok) store(TOKEN_KEY, tok);
    } catch (_) { tok = null; }
    return tok;
  }

  // ---------- video ----------
  function loadScript(src) {
    return new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = src; s.async = true; s.onload = resolve; s.onerror = reject;
      document.head.appendChild(s);
    });
  }

  // A media server answering 401 + WWW-Authenticate would make the browser pop a credential dialog for
  // <video src> (FR-4.2: zero credential dialogs; the dialog also swallows every click on the page).
  // So probe first with fetch(credentials: 'omit'), which never prompts, and attach only a playable stream;
  // until then keep retrying (the stream may simply not be live yet).
  let probeTimer = null;

  async function streamPlayable(url) {
    try {
      const res = await fetch(url, { credentials: 'omit', cache: 'no-store' });
      return res.ok;
    } catch (_) {
      return false;
    }
  }

  async function attachVideo(url) {
    const video = byTestId('guest-video-player');
    if (!video || !url || video.dataset.src === url || video.dataset.probing === url) return;
    video.dataset.probing = url;
    clearTimeout(probeTimer);
    if (!(await streamPlayable(url))) {
      delete video.dataset.probing;
      probeTimer = setTimeout(() => attachVideo(url), 5000);
      return;
    }
    delete video.dataset.probing;
    video.dataset.src = url;
    const isHls = /\.m3u8(\?|$)/.test(url);
    if (!isHls || video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = url;
      return;
    }
    try {
      if (!window.Hls) await loadScript(HLS_CDN);
      if (window.Hls && window.Hls.isSupported()) {
        const hls = new window.Hls({ lowLatencyMode: true });
        hls.loadSource(url);
        hls.attachMedia(video);
        return;
      }
    } catch (_) { /* CDN unreachable: fall through to native */ }
    video.src = url;
  }

  // ---------- chat ----------
  const seenMessages = new Set();

  function appendMessage(m) {
    const list = byTestId('chat-message-list');
    if (!list || seenMessages.has(m.message_id)) return;
    seenMessages.add(m.message_id);
    const li = document.createElement('li');
    const who = document.createElement('span');
    who.className = 'sender';
    who.textContent = m.sender || 'guest';
    const text = document.createElement('span');
    text.textContent = m.text;  // profanity is already masked (***) by the server
    li.append(who, text);
    const atBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 40;
    list.appendChild(li);
    if (atBottom) list.scrollTop = list.scrollHeight;
  }

  function startChat(roomId) {
    if (!roomId) return;
    const poll = async () => {
      try {
        const msgs = await getJson(`/api/v1/public/chat/${encodeURIComponent(roomId)}`);
        (Array.isArray(msgs) ? msgs : msgs.messages || []).forEach(appendMessage);
      } catch (_) { /* keep polling */ }
    };
    poll();
    setInterval(poll, 1000);

    const form = $('#chat-form');
    form.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const input = byTestId('chat-input-field');
      const text = input.value.trim();
      if (!text) return;
      const headers = { 'Content-Type': 'application/json' };
      const member = store('member_token');
      const tok = member || await guestToken();
      if (tok) headers.Authorization = `Bearer ${tok}`;
      let res;
      try {
        res = await fetch(API + '/api/v1/chat', {
          method: 'POST', headers, body: JSON.stringify({ chat_room_id: roomId, text }),
        });
      } catch (_) {
        setStatus('Chat is unreachable right now.');
        return;
      }
      if (res.status === 401 || res.status === 403) {
        // Guest write blocked server-side: do not show the message, ask the guest to sign in.
        openAuthModal('Sign in to chat', 'Log in or register to send messages. Your cart and your place in the stream are kept.');
        return;
      }
      if (res.ok) {
        input.value = '';
        const body = await res.json().catch(() => null);
        if (body && body.message_id) appendMessage(body);
      } else {
        setStatus(`Message not sent (${res.status}).`);
      }
    });
  }

  function setStatus(text) {
    const el = $('#status');
    if (el) el.textContent = text;
  }

  // ---------- progressive auth modal ----------
  let lastFocus = null;

  function openAuthModal(title, text) {
    const backdrop = $('#auth-backdrop');
    if (!backdrop) return;
    $('#auth-title').textContent = title;
    $('#auth-text').textContent = text;
    $('#auth-error').textContent = '';
    lastFocus = document.activeElement;
    backdrop.hidden = false;
    byTestId('progressive-auth-modal').hidden = false;
    $('#auth-email').focus();
  }

  function closeAuthModal() {
    $('#auth-backdrop').hidden = true;
    byTestId('progressive-auth-modal').hidden = true;
    if (lastFocus && lastFocus.focus) lastFocus.focus();
  }

  function wireAuthModal() {
    const backdrop = $('#auth-backdrop');
    if (!backdrop) return;
    const modal = byTestId('progressive-auth-modal');
    $('#auth-close').addEventListener('click', closeAuthModal);
    backdrop.addEventListener('click', (ev) => { if (ev.target === backdrop) closeAuthModal(); });
    document.addEventListener('keydown', (ev) => {
      if (backdrop.hidden) return;
      if (ev.key === 'Escape') closeAuthModal();
      if (ev.key === 'Tab') {  // keep focus inside the dialog
        const items = modal.querySelectorAll('input, button, a[href]');
        const first = items[0], last = items[items.length - 1];
        if (ev.shiftKey && document.activeElement === first) { ev.preventDefault(); last.focus(); }
        else if (!ev.shiftKey && document.activeElement === last) { ev.preventDefault(); first.focus(); }
      }
    });
    $('#auth-form').addEventListener('submit', async (ev) => {
      ev.preventDefault();
      const err = $('#auth-error');
      err.textContent = '';
      const video = byTestId('guest-video-player');
      const resumeAt = video ? video.currentTime : 0;
      try {
        const res = await fetch(API + '/api/v1/auth/login', {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ email: $('#auth-email').value.trim(), password: $('#auth-password').value }),
        });
        if (!res.ok) { err.textContent = 'Wrong email or password.'; return; }
        const login = await res.json();
        const token = login.access_token || login.token;
        store('member_token', token);
        const userId = (login.user && login.user.user_id) || login.user_id;
        const cart = readCart();
        const guest = store(TOKEN_KEY);
        if (userId && guest && cart.length) {
          const merge = await fetch(API + '/audit/v1/guest/cart-merge', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
            body: JSON.stringify({ guest_token: guest, registered_user_id: userId, guest_cart: cart, test_write_block: false }),
          });
          if (merge.ok) writeCart([]);
        }
        closeAuthModal();
        if (video && resumeAt) video.currentTime = resumeAt;  // back to the exact playback position
        setStatus('Signed in. Your cart was moved to your account.');
      } catch (_) {
        err.textContent = 'Could not reach the server. Try again.';
      }
    });
  }

  // ---------- pages ----------
  function pathParts() {
    return location.pathname.replace(/\/+$/, '').split('/').filter(Boolean).map(decodeURIComponent);
  }

  function renderMatch(m) {
    const home = (m.home && m.home.score) ?? 0;
    const away = (m.away && m.away.score) ?? 0;
    byTestId('live-score-banner').textContent = `${home} - ${away}`;
    $('#home-team').textContent = (m.home && m.home.team_id) || 'Home';
    $('#away-team').textContent = (m.away && m.away.team_id) || 'Away';
    $('#match-status').textContent = m.status ? m.status.replace(/_/g, ' ') : '';
    attachVideo(m.playback_url);
    const p = m.pinned_product;
    if (p) {
      $('#merch-name').textContent = p.name || p.product_id;
      $('#merch-price').textContent = p.price_minor != null ? `PKR ${(p.price_minor / 100).toLocaleString()}` : '';
      byTestId('add-to-guest-cart-btn').dataset.variant = p.variant_id || 'var-jersey-001-L';
    }
  }

  function watchMatch(matchId) {
    const url = `/api/v1/public/matches/${encodeURIComponent(matchId)}`;
    let polling = null;
    const poll = () => getJson(url).then(renderMatch).catch(() => {});
    if (window.EventSource) {
      const es = new EventSource(API + url + '/stream');
      es.addEventListener('match', (ev) => { try { renderMatch(JSON.parse(ev.data)); } catch (_) {} });
      es.onmessage = (ev) => { try { renderMatch(JSON.parse(ev.data)); } catch (_) {} };
      es.onerror = () => { if (!polling) polling = setInterval(poll, 1000); };
      es.onopen = () => { if (polling) { clearInterval(polling); polling = null; } };
    } else {
      polling = setInterval(poll, 1000);
    }
  }

  function wireCart() {
    const btn = byTestId('add-to-guest-cart-btn');
    if (!btn) return;
    btn.addEventListener('click', () => {
      const variant = btn.dataset.variant || 'var-jersey-001-L';
      const cart = readCart();
      const line = cart.find((it) => it.variant_id === variant);
      if (line) line.quantity += 1; else cart.push({ variant_id: variant, quantity: 1 });
      writeCart(cart);
      setStatus('Added to your guest cart.');
    });
    const checkout = $('#checkout-btn');
    if (checkout) {
      checkout.addEventListener('click', () =>
        openAuthModal('Sign in to check out', 'Log in or register to place your order. Your staged cart is kept.'));
    }
  }

  async function initMatch(matchId) {
    $('#match-id').textContent = matchId;
    try {
      const m = await getJson(`/api/v1/public/matches/${encodeURIComponent(matchId)}`);
      renderMatch(m);
      startChat(m.chat_room_id);
    } catch (_) {
      setStatus('Match details are not available yet.');
    }
    watchMatch(matchId);
  }

  async function initCostream(sessionId) {
    $('#session-id').textContent = sessionId;
    const render = (s) => {
      attachVideo(s.composite_playback_url);
      $('#layout').textContent = s.layout || '';
      const list = $('#participants');
      list.textContent = '';
      const people = [];
      if (s.active_host) people.push({ id: s.active_host, host: true });
      (s.active_participants || []).forEach((p) => {
        const id = typeof p === 'string' ? p : (p.user_id || p.participant_id);
        if (id && id !== s.active_host) people.push({ id, host: false });
      });
      people.forEach((p) => {
        const li = document.createElement('li');
        li.textContent = p.host ? `${p.id} (host)` : p.id;
        if (p.host) li.className = 'host';
        list.appendChild(li);
      });
    };
    let started = false;
    const load = async () => {
      try {
        const s = await getJson(`/api/v1/public/costream/${encodeURIComponent(sessionId)}`);
        render(s);
        if (!started) { started = true; startChat(s.chat_room_id || `chat-${sessionId}`); }
      } catch (_) {
        if (!started) { started = true; startChat(`chat-${sessionId}`); }
      }
    };
    await load();
    setInterval(load, 3000);
  }

  function initEntity(kind, id) {
    $('#entity-kind').textContent = kind === 'clubs' ? 'Club' : 'Player';
    $('#entity-id').textContent = id;
    $('#open-app').href = `nascon://entity/${encodeURIComponent(id)}`;
  }

  function initNotice(matchId) {
    const state = new URLSearchParams(location.search).get('state') || 'unavailable';
    $('#match-id').textContent = matchId;
    $('#notice-state').textContent = state;
  }

  document.addEventListener('DOMContentLoaded', () => {
    renderCartCount();
    wireAuthModal();
    wireCart();
    guestToken();  // issue the read-only guest token up front (no login wall)

    const parts = pathParts();  // e.g. ['web','matches','match-m1','live']
    const page = document.body.dataset.page;
    if (page === 'match') initMatch(parts[2]);
    else if (page === 'costream') initCostream(parts[2]);
    else if (page === 'entity') initEntity(parts[1], parts[2]);
    else if (page === 'notice') initNotice(parts[2]);
  });
})();
