// Observe playback without changing the site's media, controls, or autoplay rules.
// Runs in an isolated world in every frame, including cross-origin players.
(() => {
  const id = `${Date.now()}-${Math.random()}`;
  let last, scheduled = false;
  function update() {
    scheduled = false;
    const playing = [...document.querySelectorAll('video,audio')]
      .some(media => !media.paused && !media.ended && media.readyState >= 2);
    if (playing !== last) {
      last = playing;
      window.webkit.messageHandlers.mediaState.postMessage({id, playing});
    }
  }
  function schedule() {
    if (!scheduled) { scheduled = true; queueMicrotask(update); }
  }
  for (const event of ['playing','pause','ended','emptied','loadeddata']) document.addEventListener(event,schedule,true);
  new MutationObserver(schedule).observe(document,{childList:true,subtree:true});
  addEventListener('pagehide',()=>{last=undefined;window.webkit.messageHandlers.mediaState.postMessage({id,playing:false})});
  addEventListener('pageshow',schedule);
  schedule();
})();
