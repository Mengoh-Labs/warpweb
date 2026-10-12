// Let page-owned context menus handle their own events. Otherwise the host
// draws its browser menu inside the terminal's HTML chrome.
window.addEventListener('contextmenu',event=>{
  if(!event.isTrusted || event.defaultPrevented)return;
  event.preventDefault();
  const link=event.composedPath().find(el=>el instanceof HTMLAnchorElement && el.href);
  window.webkit.messageHandlers.pageContext.postMessage({link:link?.href||''});
});
