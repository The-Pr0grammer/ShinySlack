/* SHINY-HTML-PROD-COPY-ACCENT-V10.1: copy polish and Activity accent color parity. */
/* SHINY-HTML-LIVE-BRIDGE-V1. No network calls, eval, or arbitrary host commands. */
/* SHINY-HTML-CONTROLS-GLOW-V3: speaker warning, native direction layout. */
/* SHINY-HTML-PARITY-V4: stable keyed card rendering; compact volume overlay. */
(()=>{'use strict';
const $=id=>document.getElementById(id);
const bridge=window.chrome&&window.chrome.webview;
let state=null;
let errorUntil=0;
let lastFeedSignature=null;
const request=(action,details={})=>{ if(!bridge){showError('Requires the ShinySlack WebView2 host.');return} bridge.postMessage({action,...details}); };
function showError(text){$('error-banner').textContent=String(text);$('error-banner').hidden=false;errorUntil=Date.now()+7000;}
const node=(tag,cls,txt)=>{const n=document.createElement(tag);if(cls)n.className=cls;if(txt!==undefined)n.textContent=String(txt);return n;};
/* SHINY-HTML-ICONS-V6: local stroke icons, no external dependencies. */
const svg=(content)=>'<svg viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" aria-hidden="true" focusable="false" fill="none" stroke="currentColor" stroke-width="1.85" stroke-linecap="round" stroke-linejoin="round">'+content+'</svg>';
const GLYPHS=Object.freeze({
 home:svg('<path d="m3 10 9-7 9 7"/><path d="M5 9v11h14V9M9 20v-7h6v7"/>'),
 up:svg('<path d="M12 20V4M5 11l7-7 7 7"/>'),
 down:svg('<path d="M12 4v16M5 13l7 7 7-7"/>'),
 automatic:svg('<path d="M4 8V4h4M20 16v4h-4M20 8V4h-4M4 16v4h4"/><path d="M8 12h8M12 8v8"/>'),
 once:svg('<rect x="5" y="5" width="14" height="14" rx="3"/><path d="M12 9v6M10 11l2-2 2 2"/>'),
 locked:svg('<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V7a4 4 0 0 1 8 0v3M12 15v2"/>'),
 tuck:svg('<path d="m5 14 7-7 7 7M5 19h14"/>'),
 expand:svg('<path d="m5 10 7 7 7-7M5 5h14"/>'),
 hide:svg('<path d="M5 12h14"/><path d="m16 9 3 3-3 3"/>'),
 close:svg('<path d="M5 5 19 19M19 5 5 19"/>'),
 sparkle:svg('<path d="m12 2 2.5 7.5L22 12l-7.5 2.5L12 22l-2.5-7.5L2 12l7.5-2.5z"/><path d="M19 2v4M17 4h4"/>'),
 trash:svg('<path d="M4 7h16M9 7V4h6v3M6 7l1 14h10l1-14M10 11v6M14 11v6"/>'),
 refresh:svg('<path d="M20 7v5h-5M4 17v-5h5"/><path d="M6.1 9A7.5 7.5 0 0 1 19 7l1 5M4 12l1 5a7.5 7.5 0 0 0 12.9-2"/>'),
 volume:svg('<path d="M4 9h4l5-4v14l-5-4H4z"/><g class="volume-waves"><path d="M16 9a4 4 0 0 1 0 6M19 6a8 8 0 0 1 0 12"/></g><g class="volume-off"><path d="m16 9 5 6m0-6-5 6"/></g>')
});
function iconButton(id,key){
 const b=$(id); if(!b)return;
 if(b.dataset.ssGlyph===key && b.querySelector('svg'))return;
 b.classList.add('ss-polished-icon');b.innerHTML=GLYPHS[key];b.dataset.ssGlyph=key;
}
function textIcon(id,key,label){
 const b=$(id);if(!b)return;
 const safe=document.createElement('span');safe.className='ss-tool-label';safe.textContent=label;
 b.replaceChildren();const image=document.createElement('span');image.className='ss-tool-icon';image.innerHTML=GLYPHS[key];b.append(image,safe);
}

function decorate(card,a){
 const top=node('div','activityTop');
 const ch=node('span','activitySource',a.channel);ch.title=a.sample?'Local test notification':'Open Slack';ch.tabIndex=0;ch.setAttribute('role','button');
 const open=()=>request('open-slack',{id:a.id});
 ch.addEventListener('click',event=>{event.stopPropagation();open()});
 card.tabIndex=0;
 card.title=a.sample?'Local test notification':'Open Slack';
 card.addEventListener('click',event=>{if(!event.target.closest('button'))open()});
 card.addEventListener('keydown',event=>{
   if(event.target!==card)return;
   if(event.key==='Enter'||event.key===' '){event.preventDefault();open()}
 });
 ch.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();open()}});
 const time=node('time','activityTime',a.time);
 const close=node('button','dismiss ss-polished-dismiss');close.innerHTML=GLYPHS.close;close.title='Dismiss this alert';close.setAttribute('aria-label','Dismiss '+a.channel);
 close.addEventListener('click',()=>request('dismiss-one',{id:a.id}));
 top.append(ch,time,close);card.append(top);
 // Production cards only contain channel and time. Keep route metadata
 // in a tooltip rather than adding a second line that native never shows.
 card.dataset.kind=a.kind;
 if(a.sample) card.append(node('div','activityMessage','Preview alert · no sound'));
}
function render(next){
 state=next;
 document.body.dataset.theme=state.theme;
 document.documentElement.dataset.ssTheme=state.theme;
 document.body.dataset.direction=state.direction;
 document.body.classList.toggle('tucked',!!state.tucked);
 // Keep the volume panel available when the deck is tucked: the host makes
 // room for it, and CSS hides the rest of the tucked deck content.
 document.body.classList.toggle('volume-open',!!state.volumePanelOpen);
 $('volume-panel').hidden=!state.volumePanelOpen;
 const volumeMuted=(!state.volumeEnabled || state.volumePercent===0);
 const volumeWarning=(!state.volumeEnabled || state.volumePercent<=20);
 document.body.classList.toggle('volume-muted',volumeMuted);
 document.body.classList.toggle('volume-warning',volumeWarning);
 $('theme').value=state.theme;
 textIcon('follow','refresh',state.followingTheme?'Synced':'Use dashboard');
 $('follow').title=state.followingTheme?'Following dashboard theme. Select a theme to preview.':'Restore the dashboard theme';
 $('count').textContent=state.count;
 iconButton('direction',state.direction==='up'?'up':'down');
 $('direction').title='Expansion: '+state.direction+'. Click to switch.';
 iconButton('growth',state.growth==='locked'?'locked':state.growth==='once'?'once':'automatic');
 $('growth').title='Growth: '+state.growth+'. Click to cycle.';
 iconButton('tuck',state.tucked?'expand':'tuck');
 $('sound').setAttribute('aria-label',volumeMuted?'Router volume muted':'Router volume '+state.volumePercent+' percent'+(volumeWarning?' — low':'') );
 $('sound').title='Router volume: '+(volumeMuted?'MUTED':state.volumePercent+'%')+(volumeWarning?' (warning: 20% or lower)':'');
 iconButton('sound','volume');
 $('auto-dismiss').checked=!!state.autoDismiss;
 $('seconds').textContent=state.seconds+'s';
 $('volume-value').textContent=state.volumeEnabled?state.volumePercent+'%':'MUTED';
 if(document.activeElement!==$('volume-slider')) $('volume-slider').value=state.volumePercent;
 textIcon('mute','volume',state.volumeEnabled&&state.volumePercent>0?'Mute':'Unmute');
 $('status').textContent=state.status==='Watching live router events'?'Listening for alerts':state.status==='Waiting for channel-router.log'?'Waiting for notifications':state.status;
 const feed=$('feed');
 // The host refreshes status every four seconds. Do not destroy live DOM and
 // keyboard focus when no alerts have changed (especially during an X click).
 const signature=JSON.stringify(state.events.map(a=>[a.id,a.channel,a.time,a.color,!!a.sample]));
 if(signature!==lastFeedSignature){
   const oldScroll=feed.scrollTop;
   const focused=document.activeElement;
   const focusedCard=focused&&focused.closest?focused.closest('article.activityItem'):null;
   const focusedId=focusedCard?focusedCard.dataset.alertId:null;
   const focusTarget=focusedCard?(focused.classList.contains('dismiss')?'dismiss':focused.classList.contains('activitySource')?'activitySource':'activityItem'):null;
   const frag=document.createDocumentFragment();
   if(!state.events.length) frag.append(node('div','live-empty','All caught up. New alerts will appear here.'));
   else for(const a of state.events){
     const card=node('article','activityItem');card.dataset.alertId=String(a.id);
     card.style.setProperty('--activityAccent',a.color);decorate(card,a);frag.append(card);
   }
   feed.replaceChildren(frag);
   feed.scrollTop=oldScroll;
   if(focusedId && focusTarget){
     // Alert IDs are integers from the host, not arbitrary selector strings.
     const nextCard=Array.from(feed.children).find(n=>n.dataset.alertId===focusedId);
     const toFocus=nextCard&&(focusTarget==='activityItem'?nextCard:nextCard.querySelector('.'+focusTarget));
     if(toFocus)toFocus.focus({preventScroll:true});
   }
   lastFeedSignature=signature;
 }
 if(Date.now()>errorUntil)$('error-banner').hidden=true;
}
if(bridge){bridge.addEventListener('message',event=>{
 const data=event.data;
 if(!data||typeof data!=='object')return;
 if(data.type==='error'){showError(data.message||'Unknown host error');return}
 if(data.type==='state'&&data.marker==='SHINY-HTML-LIVE-BRIDGE-V1')render(data);
});}
else showError('Open this page in ShinySlack Alert Deck.');
$('dashboard').addEventListener('click',()=>request('show-dashboard'));
$('direction').addEventListener('click',()=>request('toggle-direction'));
$('growth').addEventListener('click',()=>request('toggle-growth'));
$('tuck').addEventListener('click',()=>request('toggle-tuck'));
$('hide').addEventListener('click',()=>request('hide-deck'));
$('sample').addEventListener('click',()=>request('sample'));
$('dismissAll').addEventListener('click',()=>request('dismiss-all'));
$('auto-dismiss').addEventListener('change',e=>request('set-auto-dismiss',{value:e.target.checked}));
$('theme').addEventListener('change',e=>request('select-theme',{value:e.target.value}));
$('follow').addEventListener('click',()=>request('follow-theme'));
$('sound').addEventListener('click',()=>request('toggle-volume-panel'));
$('mute').addEventListener('click',()=>request('toggle-volume'));
$('volume-slider').addEventListener('change',e=>request('set-volume',{value:Number(e.target.value)}));
$('volume-slider').addEventListener('input',e=>{const v=Number(e.target.value);$('volume-value').textContent=v+'%';document.body.classList.toggle('volume-warning',v<=20);document.body.classList.toggle('volume-muted',v===0);});
document.addEventListener('keydown',e=>{if(e.key==='Escape' && state && state.volumePanelOpen){e.preventDefault();request('close-volume-panel');$('sound').focus();}});
$('drag-zone').addEventListener('mousedown',e=>{if(e.button!==0||e.detail>1)return;if(e.target.closest('button,select,input,label'))return;request('drag');});
$('drag-zone').addEventListener('dblclick',e=>{if(e.target.closest('button,select,input,label'))return;request('toggle-tuck');});
iconButton('dashboard','home');
iconButton('hide','hide');
textIcon('sample','sparkle','Test');
textIcon('dismissAll','trash','Dismiss all');
request('ready');
})();
