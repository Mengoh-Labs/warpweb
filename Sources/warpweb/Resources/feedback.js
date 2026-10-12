// Isolated world: only generic UI state, never field contents or credentials.
(() => {
  let x = -1, y = -1, timer = 0, lastUpdate = -Infinity, previous = '';
  const textField = e => e && (e.localName === 'textarea' || e.localName === 'input' && ['text','search','email','url','tel','password','number'].includes(e.type) || e.isContentEditable);
  const update = () => {
    lastUpdate = performance.now();
    const element = document.elementFromPoint(x, y);
    const css = element ? getComputedStyle(element).cursor : 'default';
    const active = document.activeElement;
    const state = {
      cursor: css === 'pointer' || css === 'auto' && element?.closest('a[href]') ? 'pointer' : css === 'text' || textField(element) ? 'text' : 'default',
      focus: textField(active) ? 'Text field' : active && active.matches('button,a[href],select,input') ? 'Control' : 'Page',
      link: element?.closest('a[href]')?.href || ''
    };
    const value = JSON.stringify(state);
    if (value !== previous) { previous = value; window.webkit.messageHandlers.pageFeedback.postMessage(state); }
  };
  // requestAnimationFrame can pause in the off-display snapshot backend.
  // Leading updates keep pointer feedback responsive without requiring a frame clock.
  const schedule = () => {
    const delay = Math.max(0, 32 - (performance.now() - lastUpdate));
    if (!delay) { clearTimeout(timer); timer = 0; update(); }
    else if (!timer) timer = setTimeout(() => { timer = 0; update(); }, delay);
  };
  for (const name of ['pointermove','pointerdown','pointerup']) document.addEventListener(name, e => { x = e.clientX; y = e.clientY; schedule(); }, true);
  document.addEventListener('pointerout', e => { if (!e.relatedTarget) { x = y = -1; schedule(); } }, true);
  for (const name of ['focusin','focusout']) document.addEventListener(name, update, true);
  document.addEventListener('scroll', schedule, true);
  const style = document.createElement('style');
  style.textContent = ':focus-visible{outline:2px solid #8d5bef!important;outline-offset:2px!important}input:focus,textarea:focus,[contenteditable=true]:focus{outline:2px solid #8d5bef!important;outline-offset:2px!important;caret-color:#8d5bef!important}';
  (document.head || document.documentElement).append(style);
  schedule();
})();
