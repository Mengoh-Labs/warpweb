// Native AppKit select menus are separate windows and cannot appear in a
// WKWebView snapshot. Expand the original control into an in-page list instead.
(() => {
  let expanded;
  function close() {
    if (!expanded) return;
    const {select, size, style, placeholder} = expanded;
    expanded = undefined;
    select.removeEventListener('blur', close);
    if (size === null) select.removeAttribute('size'); else select.setAttribute('size', size);
    if (style === null) select.removeAttribute('style'); else select.setAttribute('style', style);
    placeholder.remove();
  }
  function open(select) {
    close();
    const rect = select.getBoundingClientRect();
    const placeholder = document.createElement('span');
    placeholder.style.cssText = `display:inline-block;width:${rect.width}px;height:${rect.height}px`;
    expanded = {select, size:select.getAttribute('size'), style:select.getAttribute('style'), placeholder};
    select.before(placeholder);
    select.size = Math.min(8, Math.max(2, select.options.length));
    Object.assign(select.style, {position:'fixed', left:`${rect.left}px`, top:`${rect.top}px`,
      width:`${Math.max(100,rect.width)}px`, height:'auto', minHeight:'0', maxHeight:`${Math.max(60,innerHeight-rect.top-8)}px`, zIndex:'2147483647'});
    select.focus();
    select.addEventListener('blur', close, {once:true});
  }
  function target(event) {
    return event.composedPath().find(node => node instanceof HTMLSelectElement);
  }
  document.addEventListener('pointerdown', event => {
    const select = target(event);
    if (expanded && expanded.select !== select) close();
    if (select && !select.disabled && !select.multiple && select.size <= 1) {
      open(select); expanded.openingRelease = true; event.preventDefault();
    }
  }, true);
  document.addEventListener('keydown', event => {
    const select = target(event);
    if (!select || select.disabled || select.multiple) return;
    if (expanded?.select === select && ['Enter','Escape'].includes(event.key)) {
      close(); event.preventDefault();
    } else if (select.size <= 1 && ['Enter',' ','ArrowDown','ArrowUp'].includes(event.key)) {
      open(select);
      if (event.key === 'Enter' || event.key === ' ') event.preventDefault();
    }
  }, true);
  document.addEventListener('pointerup', event => {
    // The first release can hit an option after the control changes shape.
    if (expanded?.openingRelease) { expanded.openingRelease = false; return; }
    if (expanded && target(event) === expanded.select && event.target instanceof HTMLOptionElement) close();
  });
})();
