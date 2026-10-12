'use strict';
const $ = id => document.getElementById(id);
const screen = $('screen'), context = screen.getContext('2d'), viewport = $('viewport');
let paused = false, queue = Promise.resolve(), size = {width: 1100, height: 720}, generation = 0;
function report(message) { $('error').hidden = !message; $('error').textContent = message || ''; }
async function request(route, options) {
  const response = await fetch(new URL(route, location.href), options);
  if (!response.ok) { let body; try { body = await response.json(); } catch {} throw new Error(body?.error || `Bridge returned ${response.status}`); }
  return response;
}
function command(payload) {
  // Preserve order when typing quickly or clicking immediately before a key.
  queue = queue.catch(() => {}).then(() => request('command', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)}));
  queue.catch(error => report(error.message));
  return queue;
}
$('navigate').onsubmit = event => { event.preventDefault(); command({action:'navigate',url:$('address').value}); screen.focus(); };
for (const action of ['back','forward','reload']) $(action).onclick = () => command({action});
$('pause').onclick = () => { paused = !paused; $('pause').textContent = paused ? '▶' : 'Ⅱ'; $('pause').ariaLabel = paused ? 'Resume stream' : 'Pause stream'; $('connection').textContent = paused ? 'Paused' : 'Live'; };
screen.onclick = event => {
  screen.focus(); const rect = screen.getBoundingClientRect();
  command({action:'click',x:(event.clientX-rect.left)*size.width/rect.width,y:(event.clientY-rect.top)*size.height/rect.height});
};
screen.onkeydown = event => {
  if (event.key === 'Escape') { screen.blur(); return; }
  if (['Shift','Control','Alt','Meta','CapsLock'].includes(event.key)) return;
  if (event.metaKey && event.key.toLowerCase() === 'l') { event.preventDefault(); $('address').focus(); $('address').select(); return; }
  event.preventDefault(); command({action:'key',key:event.key,meta:event.metaKey,ctrl:event.ctrlKey,alt:event.altKey,shift:event.shiftKey});
};
let wheel = 0, wheelTimer;
screen.addEventListener('wheel', event => { event.preventDefault(); wheel += event.deltaY * (event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? size.height : 1); if (!wheelTimer) wheelTimer = setTimeout(() => { command({action:'scroll',dy:wheel}); wheel=0; wheelTimer=null; },40); }, {passive:false});
let resizeTimer;
new ResizeObserver(() => { clearTimeout(resizeTimer); resizeTimer=setTimeout(async () => { const rect=viewport.getBoundingClientRect(); const width=Math.max(320,Math.min(1920,Math.round(rect.width))), height=Math.max(240,Math.min(1200,Math.round(rect.height))); try { await command({action:'resize',width,height}); size={width,height}; generation++; } catch {} },150); }).observe(viewport);
async function poll() {
  if (!paused && !document.hidden) {
    try {
      const start=performance.now(), current=generation;
      const state=await (await request('state')).json();
      $('title').textContent=state.title; document.title=`${state.title} · warpweb`;
      if (document.activeElement !== $('address')) $('address').value=state.url;
      $('back').disabled=!state.back; $('forward').disabled=!state.forward;
      const response=await request('frame'); const bitmap=await createImageBitmap(await response.blob());
      if (current === generation) { screen.width=bitmap.width; screen.height=bitmap.height; context.drawImage(bitmap,0,0); size={width:state.width,height:state.height}; $('waiting').style.display='none'; screen.style.visibility='visible'; }
      bitmap.close(); $('connection').textContent=state.loading?'Loading…':'Live'; $('metrics').textContent=`${size.width} × ${size.height} · ${Math.round(performance.now()-start)} ms`; report(state.error);
    } catch(error) { $('connection').textContent='Disconnected'; screen.style.visibility='hidden'; $('waiting').style.display='grid'; $('waiting').textContent='Waiting for a fresh WebKit frame…'; report(error.message); }
  }
  setTimeout(poll,200);
}
poll();
