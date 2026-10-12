// Feedback must work when the off-display snapshot view has no animation clock.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const listeners=new Map(),messages=[],timers=new Map();
let now=0,nextTimer=0,hit=null;
const element=(localName,type='')=>({localName,type,isContentEditable:false,matches:()=>false,closest:()=>null,get value(){throw Error('Must not read field contents')}});
const document={activeElement:element('body'),elementFromPoint:()=>hit,createElement:()=>({}),head:{append(){}},addEventListener(name,handler){listeners.set(name,handler)}};
const window={webkit:{messageHandlers:{pageFeedback:{postMessage:s=>messages.push(s)}}}};
vm.runInNewContext(fs.readFileSync('Sources/warpweb/Resources/feedback.js','utf8'),{
  document,window,performance:{now:()=>now},getComputedStyle:()=>({cursor:'auto'}),
  setTimeout:fn=>{timers.set(++nextTimer,fn);return nextTimer},clearTimeout:id=>timers.delete(id)
  // Deliberately no requestAnimationFrame: snapshot capture cannot depend on it.
});
assert.equal(messages.at(-1).focus,'Page');
document.activeElement=element('input','password');listeners.get('focusin')();
assert.equal(messages.at(-1).focus,'Text field');
hit=element('a');hit.closest=()=>({href:'https://target.example/'});now=100;
listeners.get('pointermove')({clientX:5,clientY:5});
assert.equal(messages.at(-1).cursor,'pointer');assert.equal(messages.at(-1).link,'https://target.example/');
const count=messages.length;
for(let n=0;n<10;n++)listeners.get('pointermove')({clientX:5+n,clientY:5});
assert.equal(timers.size,1,'pointer movement must coalesce');
now=132;for(const callback of timers.values())callback();timers.clear();
assert.equal(messages.length,count,'unchanged state must not trigger chrome snapshots');
document.activeElement=element('input','range');document.activeElement.matches=()=>true;listeners.get('focusin')();
assert.equal(messages.at(-1).focus,'Control');
console.log('PASS: feedback without animation clock, password-field privacy, auto link cursor and deduplicated pointer updates');
