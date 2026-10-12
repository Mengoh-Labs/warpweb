let count=0;
document.getElementById('counter').onclick=()=>{document.title=`Clicks: ${++count}`;document.getElementById('result').textContent=document.title;};
document.getElementById('name').oninput=event=>{document.title=`Typed: ${event.target.value}`;};
if(location.search) document.title='Second test page';

window.addEventListener('scroll',()=>{document.title='Scrolled: '+Math.round(window.scrollY);});
