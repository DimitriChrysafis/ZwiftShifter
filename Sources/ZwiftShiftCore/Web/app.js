// One confirmed press at a time. No queue and no automatic mutation retries.
export class PressRepeater {
  constructor({send, interval, changed = () => {}, failed = () => {},
    now = () => performance.now(), sleep = ms => new Promise(resolve => setTimeout(resolve, ms))}) {
    Object.assign(this, {send, interval, changed, failed, now, sleep});
    this.running = false;
    this.held = false;
  }
  release() { this.held = false; }
  async press(direction) {
    if (this.running) return;
    this.held = true;
    this.running = true;
    this.changed(true, direction);
    const start = this.now();
    try {
      do {
        const before = this.now();
        await this.send(direction);
        if (!this.held) break;
        await this.sleep(Math.max(0, this.interval() - (this.now() - before)));
      } while (this.held && this.now() - start < 30000);
    } catch (error) {
      this.failed(error);
    } finally {
      this.running = false;
      this.held = false;
      this.changed(false, direction);
    }
  }
}

if (typeof document !== 'undefined') {
  const byId = id => document.getElementById(id);
  const buttons = ['down', 'up'].map(direction => [direction, byId(`shift-${direction}`)]);
  let key = null;
  try { key = localStorage.getItem('zwiftshift-key'); } catch { /* Private browsing may disable storage. */ }
  const incoming = new URLSearchParams(location.hash.slice(1)).get('key');
  if (incoming && /^[0-9a-f]{64}$/.test(incoming)) {
    key = incoming;
    try { localStorage.setItem('zwiftshift-key', key); } catch { /* This tab still works. */ }
  }
  if (location.hash) history.replaceState(null, '', location.pathname);
  let state = null;
  let receivedAt = 0;
  let pollTimer;
  let polling = false;
  let activeDirection;

  function message(text, error = false) {
    byId('message').textContent = text;
    byId('message').classList.toggle('error', error);
  }
  function render() {
    byId('gear').textContent = state?.gear ?? '—';
    byId('gear-count').textContent = state?.gearCount ? `of ${state.gearCount}` : '\u00a0';
    byId('connection').textContent = state?.connection ?? (key ? 'Mac disconnected' : 'Private link needed');
    for (const [direction, button] of buttons) {
      button.disabled = !state?.canShift || (state.busy && !repeater.running)
        || (repeater.running && activeDirection !== direction);
      button.classList.toggle('pressed', repeater.held && activeDirection === direction);
    }
  }
  function update(value) {
    if (state && value.serverTime < state.serverTime) return;
    state = value;
    receivedAt = performance.now();
    render();
  }
  async function api(path, body) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);
    try {
      const response = await fetch(path, {
        method: body ? 'POST' : 'GET', cache: 'no-store', credentials: 'omit',
        headers: {Authorization: `Bearer ${key}`, 'ngrok-skip-browser-warning': '1',
          ...(body ? {'Content-Type': 'application/json'} : {})},
        body: body ? JSON.stringify(body) : undefined, signal: controller.signal,
      });
      if (response.status === 401) {
        key = null;
        try { localStorage.removeItem('zwiftshift-key'); } catch { /* No saved key. */ }
      }
      if (!response.headers.get('content-type')?.includes('application/json')) {
        throw new Error('Connection unavailable. Reopen the phone link from your Mac.');
      }
      const result = await response.json();
      if (!response.ok) throw new Error(result.error ?? 'The request could not be completed.');
      return result;
    } catch (error) {
      if (error.name === 'AbortError' || error instanceof TypeError) {
        throw new Error('Connection lost. Check the gear before pressing again.');
      }
      throw error;
    } finally { clearTimeout(timeout); }
  }
  const repeater = new PressRepeater({
    interval: () => state?.repeatMilliseconds ?? 400,
    changed: (running, direction) => { activeDirection = running ? direction : null; render(); },
    failed: error => { message(error.message, true); },
    send: async direction => {
      if (!state?.canShift || performance.now() - receivedAt > 6000) {
        throw new Error('Wait for a fresh connection, then press again.');
      }
      const bytes = crypto.getRandomValues(new Uint8Array(16));
      const id = Array.from(bytes, byte => byte.toString(16).padStart(2, '0')).join('');
      const result = await api('/api/shift', {
        id, direction, expiresAt: state.serverTime + (performance.now() - receivedAt) + 2000,
      });
      update(result.state);
      if (!result.ok || !result.confirmed) throw new Error(result.message);
      message('Hold to repeat');
    },
  });
  function release() { repeater.release(); render(); }
  for (const [direction, button] of buttons) {
    button.addEventListener('pointerdown', event => {
      if (event.button !== 0 || button.disabled || repeater.running) return;
      event.preventDefault();
      button.setPointerCapture(event.pointerId);
      void repeater.press(direction);
    });
    for (const event of ['pointerup', 'pointercancel', 'lostpointercapture']) {
      button.addEventListener(event, release);
    }
    button.addEventListener('keydown', event => {
      if (![' ', 'Enter'].includes(event.key)) return;
      event.preventDefault();
      if (!event.repeat && !button.disabled) void repeater.press(direction);
    });
    button.addEventListener('keyup', event => {
      if ([' ', 'Enter'].includes(event.key)) { event.preventDefault(); release(); }
    });
    // Accessibility activation generates a click without pointer/keyboard events.
    button.addEventListener('click', event => {
      if (event.detail === 0 && !repeater.running && !button.disabled) {
        void repeater.press(direction);
        release();
      }
    });
    button.addEventListener('contextmenu', event => event.preventDefault());
  }
  async function poll() {
    clearTimeout(pollTimer);
    if (polling || document.hidden || !key) return;
    polling = true;
    try { update(await api('/api/status')); }
    catch (error) {
      release();
      state = null;
      message(error.message, true);
      render();
    } finally {
      polling = false;
      if (!document.hidden && key) pollTimer = setTimeout(poll, 2000);
    }
  }
  for (const event of ['blur', 'pagehide']) window.addEventListener(event, release);
  document.addEventListener('visibilitychange', () => {
    release();
    clearTimeout(pollTimer);
    if (!document.hidden) void poll();
  });
  window.addEventListener('online', () => void poll());
  window.addEventListener('offline', () => {
    release(); state = null; render(); message('Mac disconnected. Reconnect before shifting.', true);
  });
  render();
  if (key) void poll();
  else message('Scan the QR code or open the private link shown in ZwiftShift on your Mac.');
}
