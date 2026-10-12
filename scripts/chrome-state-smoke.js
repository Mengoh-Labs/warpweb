// Run the shipped chrome script against a minimal DOM to force stale-state races.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
class Element {
  constructor(){this.style={};this.children=[];this.value='';this.classList={toggle(){}};this.dataset={};}
  set innerHTML(value){this.html=value;this.htmlWrites=(this.htmlWrites||0)+1} get innerHTML(){return this.html}
  setAttribute(name,value){this[name]=String(value)}
  append(...items){this.children.push(...items)}
  replaceChildren(){this.children=[]}
  querySelectorAll(){return []}
  focus(){document.activeElement=this} blur(){document.activeElement=null} select(){}
}
const elements=new Map(),messages=[];
const document={activeElement:null,getElementById(id){if(!elements.has(id))elements.set(id,new Element());return elements.get(id)},createElement(){return new Element()},addEventListener(){}};
const window={webkit:{messageHandlers:{chrome:{postMessage:message=>messages.push(message)}}}};
const source=fs.readFileSync(process.argv[2]||'Sources/warpweb/Resources/chrome.html','utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
vm.runInNewContext(source,{document,window,innerWidth:1200});
const address=document.getElementById('address'),form=document.getElementById('navigate');
const state={tabs:[],url:'https://example.com',addressRequest:0};
window.updateChrome(state);
address.focus();address.value='https://new.example/path';address.oninput?.();address.blur();
window.updateChrome(state);
assert.equal(address.value,'https://new.example/path','blur before Go must not overwrite edited URL');
form.onsubmit({preventDefault(){}});
assert.equal(messages.at(-1).url,'https://new.example/path');
window.updateChrome(state);
assert.equal(address.value,'https://new.example/path','stale state after submit must not restore old URL');
window.updateChrome({...state,addressRequest:1,url:'https://new.example/path'});
window.updateChrome({...state,addressRequest:1,url:'https://redirect.example/'});
assert.equal(address.value,'https://redirect.example/','acknowledged redirects must update the address');
console.log('PASS: address draft survives blur/Go and stale state; acknowledged redirects update');

const menu=document.getElementById('menu');
menu.getBoundingClientRect=()=>({left:1008,top:95,width:180,height:460});
const rect=window.menuRect();
assert.equal(rect.x,996,'menu overlay must copy the right-hand region');
assert.equal(rect.width,204);
assert.equal(rect.y,83);
console.log('PASS: menu overlay includes its horizontal origin and shadow bounds');

window.updateChrome({...state,loading:true,progress:45,title:'Old title',pointerSeen:true,focusArea:'Text field',zoom:110});
assert.equal(document.getElementById('load-track').hidden,false);
assert.equal(document.getElementById('load-progress').style.width,'45%');
assert.match(document.getElementById('status').textContent,/Loading 45%/);
assert.match(document.getElementById('pointer').textContent,/Text field.*110%/);
document.getElementById('reload').onclick();assert.equal(messages.at(-1).action,'stop');
const writes=document.getElementById('reload').htmlWrites;
window.updateChrome({...state,loading:true,progress:50,focusArea:'Browser controls'});
assert.equal(document.getElementById('reload').htmlWrites,writes,'focus/progress updates must preserve the pressed button DOM');
window.updateChrome({...state,loading:false,hoverURL:'https://target.example/'});
assert.equal(document.getElementById('load-track').hidden,true);
assert.equal(document.getElementById('status').textContent,'https://target.example/');
document.getElementById('reload').onclick();assert.equal(messages.at(-1).action,'reload');
window.showDialog({kind:'help',origin:'warpweb',message:'Shortcuts'});
assert.equal(document.getElementById('help-list').hidden,false);
assert.equal(document.getElementById('dialog-value').hidden,true);
assert.equal(document.getElementById('cancel').hidden,true);
window.hideDialog();
console.log('PASS: loading progress, stop/reload, focus, zoom, link destination and help');
