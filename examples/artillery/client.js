/* Artillery Duel — dumb renderer. All game logic lives in the Nim backend;
 * this file only paints state, previews the same physics constants locally,
 * and forwards player input over the WebSocket. */
"use strict";
const COLS=320,ROWS=180,CELL=4,GRAV=250,WINDACC=6,MAXV=560;
const W=1280,H=720;
const cv=document.getElementById("cv"),ctx=cv.getContext("2d");
const WPN=["Howitzer","Nuke","Dirt Wall","MIRV","Toxin","Triple"];
const WPN_ICON=["💥","☢️","🧱","🛰️","☣️","🎯"];
const WPN_DESC=["clean crater","big area, launch","raises terrain","splits in air","flowing poison","3 spread shells"];

let ws=null,me=null,M=null,prev=null,tPrev=0,trails=[],fx=[],parts=[];
let shake=0,shakeT=0;
let localAngle=null,localPower=null,lastMouseAim=0,lastAimSent=0,lastAimDeg=90;
let matchCode=null;
const WSURL=(location.protocol==="https:"?"wss://":"ws://")+location.host+"/ws";

/* ---------------- connection ----------------
 * One WebSocket carries both protocols: htmx's ws extension drives the
 * lobby (ws-send button -> JSON action, server -> HTML fragment that
 * htmx OOB-swaps into #lobby-body) and this script drives the game
 * (JSON state/ev/result). htmx owns the connection lifecycle
 * (jittered reconnect); we hook the very same socket through
 * htmx.createWebSocket so both sides share a single connection. */
function makeSocket(url){
  const s=new WebSocket(url);
  ws=s;
  s.addEventListener("open",()=>{
    document.getElementById("conn").textContent="connected";
    if(matchCode)send({t:"join",code:matchCode});
  });
  s.addEventListener("close",()=>{
    document.getElementById("conn").textContent="reconnecting…";
    if(ws===s)ws=null;
  });
  s.addEventListener("message",onMsg);
  return s;
}
function connect(){
  if(typeof htmx!=="undefined"){
    htmx.createWebSocket=makeSocket; // <body hx-ws="connect:/ws"> uses it
    return;
  }
  // CDN fallback: plain socket with manual reconnect
  makeSocket(WSURL).addEventListener("close",()=>setTimeout(connect,1500));
}
function send(o){if(ws&&ws.readyState===1)ws.send(JSON.stringify(o));}

function onMsg(e){
  let m;
  try{m=JSON.parse(e.data);}catch(_){return;} // HTML fragment for htmx
  if(m.t==="error"){
    const s=document.querySelector("#lobby-body");
    if(s&&M===null){s.innerHTML='<div class="got-error">'+m.s+"</div>";}
    return;
  }
  if(m.t==="offer"){
    me=0;matchCode=m.match;
    const share=location.origin+"/?c="+m.match;
    const lb=document.getElementById("lobby-body");
    if(lb)lb.innerHTML=
      '<div class="got-card"><div class="got-title">Match created</div>'+
      '<div class="got-code">'+m.match+'</div>'+
      '<a class="got-link" href="'+share+'">'+share+'</a>'+
      '<div class="got-status">Waiting for your opponent…</div></div>';
    return;
  }
  else if(m.t==="hello"){me=m.you;if(M)updateHud();}
  else if(m.t==="state"){
    if(prev&&m.ph==="sim")prev=M;
    if(m.tm===undefined&&M)m.tm=M.tm; // terrain is dirty-sent; keep last copy
    // sync optimistic aim from the server when the player has been idle
    if(M&&M.ph==="prep"&&M.cur===me&&!M.ai[me]&&
       performance.now()-lastMouseAim>500){
      localAngle=M.tk[me][2];localPower=M.tk[me][3];
    }
    M=m;
    tPrev=performance.now();
    if(m.ph!=="sim")prev=null;
    if(m.pr&&m.pr.length!==trails.length)trails=m.pr.map((_,i)=>trails[i]||[]);
    // overlays follow the match phase (lobby shows the htmx-swapped
    // code card while waiting; the game takes over once it starts)
    if(m.ph==="draft"||m.ph==="prep"||m.ph==="sim"){
      document.getElementById("lobby").style.display="none";
      document.getElementById("over").style.display="none";
    }
    updateHud();
  }
  else if(m.t==="ev"){
    fx.push(Object.assign({b:performance.now()},m));
    if(m.k==="launch"&&M)trails=(M.pr||[]).map(()=>[]);
    if(m.k==="split"&&M)trails=M.pr.map((p,i)=>trails[i]||[]);
    if(m.k==="boom"){spawnDebris(m.x,m.y,m.r||40,"#ffb14d");shake=7;shakeT=performance.now();}
    if(m.k==="dirt"){spawnDebris(m.x,m.y,(m.r||30)*0.8,"#a97c48");shake=4;shakeT=performance.now();}
  }
  else if(m.t==="result"){
    const names=["RED WINS","BLUE WINS","DRAW"];
    const cls=["red","blue","draw"][m.winner];
    const el=document.getElementById("winTxt");
    el.textContent=names[m.winner];el.className="big "+cls;
    document.getElementById("finScores").textContent=
      "Red "+m.score[0]+"  —  Blue "+m.score[1];
    document.getElementById("dock").style.display="none";
    document.getElementById("over").style.display="flex";
    cv.classList.remove("aiming");
  }
}

/* ---------------- input ---------------- */
function myPrep(){return M&&M.ph==="prep"&&M.cur===me&&!M.ai[me];}
function clampAng(a){return Math.max(5,Math.min(175,a));}
function aimTo(deg){
  if(!myPrep())return;
  deg=clampAng(deg);
  localAngle=deg;
  const now=performance.now();
  if(Math.abs(deg-lastAimDeg)>=0.2||now-lastAimSent>60){
    lastAimDeg=deg;lastAimSent=now;
    send({t:"aim",deg:Math.round(deg*10)/10});
  }
}
function powerTo(pct){
  if(!myPrep())return;
  pct=Math.max(10,Math.min(100,pct));
  localPower=pct;
  send({t:"power",pct:Math.round(pct)});
}
function move(d){if(!myPrep())return;send({t:"move",d});}
function selW(i){if(!myPrep())return;send({t:"sel",idx:i});}
function fireNow(){
  if(!myPrep())return;
  send({t:"fire"});
  document.getElementById("dock").style.display="none";
  cv.classList.remove("aiming");
}
function tankAngle(){return localAngle!==null&&localAngle!==undefined?
  localAngle:(M?M.tk[me][2]:90);}
function tankPower(){return localPower!==null&&localPower!==undefined?
  localPower:(M?M.tk[me][3]:50);}

/* mouse aiming: the angle is set by CLICKING (or holding + dragging)
 * on the field — the angle from my tank to the pointer. Plain hovering
 * never changes the angle, so it stays fixed until you act again. */
let dragAiming=false;
function aimFromMouse(e){
  const r=cv.getBoundingClientRect();
  const mx=(e.clientX-r.left)*(W/r.width);
  const my=(e.clientY-r.top)*(H/r.height);
  const tk=M.tk[me];
  const tx=tk[0],ty=tk[1]-12;
  const deg=Math.atan2(ty-my,mx-tx)*180/Math.PI;
  lastMouseAim=performance.now();
  aimTo(deg);
}
cv.addEventListener("mousedown",e=>{
  if(!myPrep()||e.button!==0)return;
  dragAiming=true;
  aimFromMouse(e);
});
window.addEventListener("mouseup",()=>{dragAiming=false;});
cv.addEventListener("mousemove",e=>{
  if(!myPrep()||!dragAiming)return;
  aimFromMouse(e);
});
document.addEventListener("keydown",e=>{
  if(!myPrep())return;
  const k=e.key;
  if(k==="ArrowUp"){powerTo(tankPower()+1);lastMouseAim=performance.now();e.preventDefault();}
  else if(k==="ArrowDown"){powerTo(tankPower()-1);lastMouseAim=performance.now();e.preventDefault();}
  else if(k==="ArrowLeft"){aimTo(tankAngle()-1);lastMouseAim=performance.now();e.preventDefault();}
  else if(k==="ArrowRight"){aimTo(tankAngle()+1);lastMouseAim=performance.now();e.preventDefault();}
  else if(k==="a"||k==="A")move(-1);
  else if(k==="d"||k==="D")move(1);
  else if(k>="1"&&k<="3")selW(+k-1);
  else if(k===" "||k==="Enter"){fireNow();e.preventDefault();}
});

/* ---------------- HUD ---------------- */
function updateHud(){
  if(!M)return;
  document.getElementById("s0").innerHTML=
    '<span class="dot"></span>RED&nbsp;<b>'+M.sc[0]+"</b>";
  document.getElementById("s1").innerHTML=
    '<span class="dot"></span>BLUE&nbsp;<b>'+M.sc[1]+"</b>";
  const prep=M.ph==="prep";
  document.getElementById("s0").classList.toggle("active",prep&&M.cur===0);
  document.getElementById("s1").classList.toggle("active",prep&&M.cur===1);
  document.getElementById("round").textContent=
    (M.ph==="draft")?"Draft":(M.ph==="over")?"Final":"Round "+M.rnd+"/10";
  const wa=document.getElementById("warr");
  wa.style.transform="scaleX("+Math.max(.2,Math.abs(M.wind))*Math.sign(M.wind||1)+")";
  document.getElementById("wval").textContent=Math.abs(M.wind);
  const tEl=document.getElementById("timer");
  tEl.textContent=(M.ph==="prep")?(" "+M.timer+"s"):
    (M.ph==="draft")?(" pick "+M.timer+"s"):"";
  tEl.classList.toggle("hot",M.ph==="prep"&&M.timer<=10);
  const dock=document.getElementById("dock");
  dock.style.display=myPrep()?"flex":"none";
  cv.classList.toggle("aiming",myPrep());
  if(myPrep()){
    const ang=tankAngle(),pwr=tankPower();
    document.getElementById("angV").textContent=Math.round(ang)+"°";
    document.getElementById("pwrV").textContent=Math.round(pwr)+"%";
    document.getElementById("angBar").style.width=((ang-5)/170*100)+"%";
    document.getElementById("pwrBar").style.width=((pwr-10)/90*100)+"%";
    // barrel points along the angle: 90° = up
    document.getElementById("dialI").style.transform=
      "rotate("+(-ang+90)+"deg)";
    const tk=M.tk[me];
    let pips="";
    const maxF=10;
    for(let i=0;i<maxF;i++)
      pips+="<i"+(i<tk[4]?" class='on'":"")+"></i>";
    document.getElementById("pips").innerHTML=pips;
    let wc="";
    for(let i=0;i<3;i++){
      const w=M.inv[me][i];
      wc+='<button class="wcard'+(M.sel[me]===i?" sel":"")+'" onclick="selW('+i+')">'+
        WPN[w]+"</button>";
    }
    document.getElementById("wcards").innerHTML=wc;
    document.getElementById("fireBtn").classList.add("pulse");
  }
  // draft overlay
  const dr=document.getElementById("draft");
  dr.style.display=M.ph==="draft"?"flex":"none";
  if(M.ph==="draft"){
    const myTurn=M.nxt===me&&!M.ai[me];
    const col=M.nxt===0?"var(--red)":"var(--blue)";
    document.getElementById("driftxt").innerHTML=
      "Pick 3 weapons. Choosing: <b style='color:"+col+"'>"+
      (M.nxt===0?"RED":"BLUE")+"</b>"+(myTurn?"":" &mdash; wait…");
    let html="";
    for(const w of M.pool){
      html+='<button class="wcard" '+(myTurn?"":"disabled")+
        ' onclick="send({t:\'pick\',idx:'+w+'})">'+
        '<span class="wm">'+WPN_ICON[w]+'</span><span class="wn">'+WPN[w]+"</span>"+
        "<small>"+WPN_DESC[w]+"</small></button>";
    }
    document.getElementById("pool").innerHTML=html;
  }
}

/* ---------------- effects ---------------- */
function spawnDebris(x,y,r,color){
  for(let i=0;i<18;i++){
    const a=Math.random()*Math.PI*2,sp=(0.3+Math.random()*0.9)*r*2.2;
    parts.push({x,y,vx:Math.cos(a)*sp,vy:Math.sin(a)*sp-r,
      life:0.55+Math.random()*0.5,t:0,c:color,s:2+Math.random()*3});
  }
}

/* ---------------- rendering ---------------- */
function lerpVal(a,b,t){
  if(!a||!b||a.length!==b.length)return null;
  const out=[];
  for(let i=0;i<a.length;i++)out.push(a[i]+(b[i]-a[i])*t);
  return out;
}
function groundY(tm,c){return (180-tm[c])*4;}
function easeOut(t){return 1-Math.pow(1-t,3);}

function draw(now){
  requestAnimationFrame(draw);
  if(!M||!M.tm)return; // first full snapshot not arrived yet
  let t=0;
  if(prev&&M.ph==="sim")t=Math.min(1,(now-tPrev)/25);
  ctx.save();
  if(shake>0){
    const k=Math.max(0,1-(now-shakeT)/220);
    if(k<=0)shake=0;
    else{
      ctx.translate((Math.random()-.5)*2*shake*k,
                    (Math.random()-.5)*2*shake*k);
    }
  }
  /* sky */
  const g=ctx.createLinearGradient(0,0,0,H);
  g.addColorStop(0,"#274b73");g.addColorStop(.45,"#6d9cc4");
  g.addColorStop(.8,"#b9d7ea");g.addColorStop(1,"#dcebf5");
  ctx.fillStyle=g;ctx.fillRect(0,0,W,H);
  /* sun */
  const sg=ctx.createRadialGradient(1050,120,10,1050,120,190);
  sg.addColorStop(0,"rgba(255,244,214,.95)");
  sg.addColorStop(.25,"rgba(255,236,180,.4)");
  sg.addColorStop(1,"rgba(255,236,180,0)");
  ctx.fillStyle=sg;ctx.fillRect(840,0,440,340);
  /* clouds (drift with wind) */
  const cshift=(now/1000*(6+Math.abs(M.wind)*7));
  ctx.fillStyle="rgba(255,255,255,.34)";
  for(let i=0;i<4;i++){
    const base=i*340+120,cx=((base+cshift*(0.4+i*0.22))%1700)-200;
    const cy=90+i*52+((i*53)%30);
    ctx.beginPath();
    ctx.ellipse(cx,cy,66+i*10,15+i*2.5,0,0,7);
    ctx.ellipse(cx+42,cy-9,38,12,0,0,7);
    ctx.fill();
  }
  /* wind streaks */
  const wdt=(now/60*M.wind)%1280;
  for(let i=0;i<8;i++){
    const y=60+i*74+((i*37)%23);
    const x=((i*197+wdt)%1400+1400)%1400-60;
    const len=30*Math.sign(M.wind||1)*(0.5+Math.abs(M.wind)/6);
    ctx.strokeStyle="rgba(255,255,255,"+(0.08+0.05*((i*29)%3)/2)+")";
    ctx.lineWidth=1.4;
    ctx.beginPath();ctx.moveTo(x,y);ctx.lineTo(x+len,y);ctx.stroke();
  }
  /* terrain */
  const tm=M.tm;
  const tg=ctx.createLinearGradient(0,200,0,H);
  tg.addColorStop(0,"#8a6242");tg.addColorStop(.5,"#6b4a2f");tg.addColorStop(1,"#3d2917");
  ctx.fillStyle=tg;ctx.beginPath();ctx.moveTo(0,H);
  ctx.lineTo(0,groundY(tm,0));
  for(let c=1;c<COLS;c++)ctx.lineTo(c*4,groundY(tm,c));
  ctx.lineTo(W,H);ctx.closePath();ctx.fill();
  /* grass cap */
  ctx.strokeStyle="#6fae4e";ctx.lineWidth=3.5;ctx.lineJoin="round";
  ctx.beginPath();ctx.moveTo(0,groundY(tm,0));
  for(let c=1;c<COLS;c++)ctx.lineTo(c*4,groundY(tm,c));
  ctx.stroke();
  ctx.strokeStyle="rgba(255,255,255,.16)";ctx.lineWidth=1.2;
  ctx.beginPath();ctx.moveTo(0,groundY(tm,0)-1.5);
  for(let c=1;c<COLS;c++)ctx.lineTo(c*4,groundY(tm,c)-1.5);
  ctx.stroke();
  /* toxin pools */
  const pulse=0.75+0.25*Math.sin(now/300);
  for(const [c,n0,n1] of (M.tx||[])){
    const base=groundY(tm,c);
    for(let i=0;i<n0;i++){
      ctx.fillStyle="rgba(126,211,33,"+(0.55+0.35*pulse)+")";
      ctx.fillRect(c*4,base-(i+1)*4,4,4);}
    for(let i=0;i<n1;i++){
      ctx.fillStyle="rgba(33,212,181,"+(0.55+0.35*pulse)+")";
      ctx.fillRect(c*4,base-(i+n0+1)*4,4,4);}
    if(n0+n1>0){
      const gg=ctx.createRadialGradient(c*4,base-(n0+n1)*2,1,
        c*4,base-(n0+n1)*2,14);
      const col=n0>0?"126,211,33":"33,212,181";
      gg.addColorStop(0,"rgba("+col+","+(0.22*pulse)+")");
      gg.addColorStop(1,"rgba("+col+",0)");
      ctx.fillStyle=gg;ctx.fillRect(c*4-14,base-(n0+n1)*2-14,28,28);
    }
  }
  /* aim guide */
  if(M.ph==="prep"&&M.cur===me&&!M.ai[me]){
    const a=tankAngle()*Math.PI/180,v=tankPower()/100*MAXV;
    const tk=M.tk[me];
    let gx=tk[0]+Math.cos(a)*24,gy=(tk[1]-12)-Math.sin(a)*24;
    let vx=Math.cos(a)*v,vy=-Math.sin(a)*v;
    for(let i=0;i<130;i++){
      vx+=M.wind*WINDACC/60;vy+=GRAV/60;gx+=vx/60;gy+=vy/60;
      if(gx<0||gx>W)break;
      const c=Math.max(0,Math.min(COLS-1,gx/4|0));
      if(gy>=groundY(tm,c)){
        /* landing marker */
        ctx.strokeStyle="rgba(255,200,87,.85)";ctx.lineWidth=2;
        ctx.beginPath();ctx.arc(gx,groundY(tm,c),9,0,7);ctx.stroke();
        ctx.beginPath();ctx.arc(gx,groundY(tm,c),3,0,7);
        ctx.fillStyle="rgba(255,200,87,.9)";ctx.fill();
        break;
      }
      if(i%5===0){
        const al=Math.max(.08,.6-(i/130)*.5);
        ctx.fillStyle="rgba(255,255,255,"+al+")";
        ctx.beginPath();ctx.arc(gx,gy,Math.max(1,2.4-i*0.012),0,7);ctx.fill();
      }
    }
  }
  /* tanks */
  const tks=[lerpVal(prev&&prev.tk?prev.tk[0]:null,M.tk[0],t),
             lerpVal(prev&&prev.tk?prev.tk[1]:null,M.tk[1],t)];
  const cols=["#ff4d5a","#4d9fff"],colsHi=["#ff8f98","#a8d1ff"];
  for(let i=0;i<2;i++){
    const p=tks[i]||M.tk[i];
    const x=p[0],y=p[1];
    const ang=(i===me&&myPrep())?tankAngle()*Math.PI/180:p[2]*Math.PI/180;
    if(M.cur===i&&M.ph==="prep"){
      ctx.fillStyle=i===0?"rgba(255,77,90,.22)":"rgba(77,159,255,.22)";
      ctx.beginPath();ctx.ellipse(x,y+2,26,8,0,0,7);ctx.fill();
    }
    /* barrel (with slight recoil right after a launch event) */
    let rec=0;
    for(const f of fx)if(f.k==="launch"){
      const age=(now-f.b)/1000;
      if(age<0.18&&Math.abs(f.x-x)<70&&Math.abs(f.y-y)<50)
        rec=easeOut(1-age/0.18)*5;
    }
    const bl=18-rec;
    const bg=ctx.createLinearGradient(x,y-12,
      x+Math.cos(ang)*bl,y-12-Math.sin(ang)*bl);
    bg.addColorStop(0,"#3a4258");bg.addColorStop(1,cols[i]);
    ctx.strokeStyle=bg;ctx.lineWidth=5;ctx.lineCap="round";
    ctx.beginPath();ctx.moveTo(x,y-12);
    ctx.lineTo(x+Math.cos(ang)*bl,y-12-Math.sin(ang)*bl);ctx.stroke();
    /* hull */
    const hg=ctx.createLinearGradient(0,y-18,0,y-6);
    hg.addColorStop(0,colsHi[i]);hg.addColorStop(1,cols[i]);
    ctx.fillStyle=hg;
    ctx.beginPath();
    if(ctx.roundRect)ctx.roundRect(x-16,y-17,32,11,4);
    else ctx.rect(x-16,y-17,32,11);
    ctx.fill();
    /* turret dome */
    ctx.fillStyle=colsHi[i];
    ctx.beginPath();ctx.arc(x,y-16,7,Math.PI,0);ctx.fill();
    /* treads */
    ctx.fillStyle="#252b3d";
    ctx.beginPath();ctx.arc(x-9,y-5,4.6,0,7);ctx.arc(x+9,y-5,4.6,0,7);ctx.fill();
    ctx.fillStyle="#4a5470";
    ctx.beginPath();ctx.arc(x-9,y-5,1.8,0,7);ctx.arc(x+9,y-5,1.8,0,7);ctx.fill();
    if(M.cur===i&&M.ph==="prep"){
      ctx.strokeStyle="rgba(255,255,255,.75)";ctx.lineWidth=1.6;
      ctx.setLineDash([5,4]);
      ctx.strokeRect(x-21,y-27,42,30);
      ctx.setLineDash([]);
    }
  }
  /* projectiles + glowing trails */
  for(let i=0;i<(M.pr||[]).length;i++){
    const p=M.pr[i],pt=lerpVal(prev&&prev.pr?prev.pr[i]:null,p,t);
    const x=pt?pt[0]:p[0],y=pt?pt[1]:p[1];
    if(trails[i]){trails[i].push([x,y]);if(trails[i].length>13)trails[i].shift();}
    if(trails[i]&&trails[i].length>1){
      for(let k=1;k<trails[i].length;k++){
        const al=k/trails[i].length;
        ctx.strokeStyle="rgba(255,240,200,"+(al*0.5)+")";
        ctx.lineWidth=al*3;
        ctx.beginPath();
        ctx.moveTo(trails[i][k-1][0],trails[i][k-1][1]);
        ctx.lineTo(trails[i][k][0],trails[i][k][1]);
        ctx.stroke();
      }
    }
    const pg=ctx.createRadialGradient(x,y,0.5,x,y,7);
    pg.addColorStop(0,"#fff8e7");pg.addColorStop(.4,"rgba(255,214,140,.9)");
    pg.addColorStop(1,"rgba(255,190,90,0)");
    ctx.fillStyle=pg;ctx.beginPath();ctx.arc(x,y,7,0,7);ctx.fill();
    ctx.fillStyle="#1a1a1a";ctx.beginPath();ctx.arc(x,y,2.6,0,7);ctx.fill();
  }
  /* event effects */
  const nowMs=performance.now();
  fx=fx.filter(f=>nowMs-f.b<1500);
  for(const f of fx){
    const age=(nowMs-f.b)/1000;
    if(f.k==="boom"){
      const r=(f.r||40)*easeOut(Math.min(1,age/0.35));
      ctx.strokeStyle="rgba(255,170,40,"+(1-age/0.5)+")";ctx.lineWidth=3.5;
      ctx.beginPath();ctx.arc(f.x,f.y,r,0,7);ctx.stroke();
      const fg=ctx.createRadialGradient(f.x,f.y,0,f.x,f.y,r*0.7);
      fg.addColorStop(0,"rgba(255,240,180,"+(0.85-age)+")");
      fg.addColorStop(1,"rgba(255,140,40,0)");
      ctx.fillStyle=fg;ctx.beginPath();ctx.arc(f.x,f.y,r*0.7,0,7);ctx.fill();
    }else if(f.k==="dirt"){
      ctx.strokeStyle="rgba(150,110,60,"+(1-age/0.6)+")";ctx.lineWidth=3;
      ctx.beginPath();ctx.arc(f.x,f.y,(f.r||30)*easeOut(Math.min(1,age/0.4)),0,7);
      ctx.stroke();
    }else if(f.k==="split"){
      ctx.fillStyle="rgba(255,255,255,"+(1-age/0.5)+")";
      for(let k=0;k<8;k++){const a=k*0.785;
        ctx.fillRect(f.x+Math.cos(a)*age*100-2,f.y+Math.sin(a)*age*100-2,4,4);}
    }else if(f.k==="score"){
      ctx.font="800 24px system-ui";ctx.textAlign="center";
      ctx.fillStyle=f.s&&f.s[0]==="+"?"#41d98d":"#ff5c5c";
      ctx.globalAlpha=Math.max(0,1-age/1.3);
      ctx.fillText(f.s||"",f.x,f.y-easeOut(Math.min(1,age/1.3))*44);
      ctx.globalAlpha=1;
    }else if(f.k==="launch"){
      const lr=12*(1-age/0.4)+2;
      if(lr>2){
        const lg=ctx.createRadialGradient(f.x,f.y,0,f.x,f.y,lr);
        lg.addColorStop(0,"rgba(255,250,220,"+(1-age/0.4)+")");
        lg.addColorStop(1,"rgba(255,200,90,0)");
        ctx.fillStyle=lg;ctx.beginPath();ctx.arc(f.x,f.y,lr,0,7);ctx.fill();
      }
    }
  }
  /* debris particles */
  parts=parts.filter(p=>p.t<p.life);
  for(const p of parts){
    p.t+=1/60;p.vy+=340/60;p.x+=p.vx/60;p.y+=p.vy/60;
    const al=1-p.t/p.life;
    ctx.globalAlpha=al;
    ctx.fillStyle=p.c;
    ctx.fillRect(p.x-p.s/2,p.y-p.s/2,p.s,p.s);
    ctx.globalAlpha=1;
  }
  ctx.restore();
  /* vignette (not shaken) */
  const vg=ctx.createRadialGradient(W/2,H/2,H*0.45,W/2,H/2,H*0.85);
  vg.addColorStop(0,"rgba(0,0,0,0)");vg.addColorStop(1,"rgba(8,10,20,.28)");
  ctx.fillStyle=vg;ctx.fillRect(0,0,W,H);
}

/* test/inspection hook: read {M, me, ws} from the dev console */
Object.defineProperty(window, "__game", { get: () => ({ M, me, ws }) });

/* ---------------- boot ---------------- */
(function boot(){
  const c=new URLSearchParams(location.search).get("c");
  if(c)matchCode=c.toUpperCase(); // joined on socket open (share link)
  connect();
  requestAnimationFrame(draw);
})();
