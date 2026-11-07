// Run with Node.js and sharp. These are proposals, not application icon assets.
const fs = require('node:fs');
const path = require('node:path');
const sharp = require('sharp');
const out = __dirname;
const designs = [
  {id:'01-orbit', name:'源环', tag:'聚合 · 连续 · 播放', color:'#2168D8',
   description:'开放圆环汇聚内容，中央留白形成播放键。',
   body:`<path d="M390 181a153 153 0 1 0 0 150" fill="none" stroke="CURRENT" stroke-width="62" stroke-linecap="round"/><path d="M219 168c-8-5-19 1-19 11v154c0 10 11 16 19 11l124-77c8-5 8-17 0-22z" fill="CURRENT"/>`},
  {id:'02-frames', name:'叠映', tag:'片库 · 秩序 · 轻快', color:'#5A56D9',
   description:'层叠画面呼应多源片库，轮廓适合桌面图标。',
   body:`<rect x="83" y="103" width="295" height="269" rx="58" fill="CURRENT" opacity=".22"/><rect x="119" y="139" width="295" height="269" rx="58" fill="CURRENT"/><path d="M235 208c-7-4-15 1-15 9v115c0 8 8 13 15 9l93-57c7-4 7-14 0-18z" fill="BACKGROUND"/>`},
  {id:'03-current', name:'流光', tag:'流动 · 源影 S · 灵巧', color:'#128779',
   description:'两道弧线组成 S，让播放与流动融为一体。',
   body:`<path d="M366 143H211c-50 0-89 33-89 76 0 30 20 51 57 64l83 29" fill="none" stroke="CURRENT" stroke-width="58" stroke-linecap="round"/><path d="M146 369h155c50 0 89-33 89-76 0-30-20-51-57-64l-83-29" fill="none" stroke="CURRENT" stroke-width="58" stroke-linecap="round"/><path d="m245 234 45 22-45 22z" fill="CURRENT"/>`},
  {id:'04-screen', name:'映窗', tag:'影院 · 安静 · 清晰', color:'#C46B39',
   description:'宽银幕与微弧底线，偏向沉稳的影音工具。',
   body:`<rect x="88" y="111" width="336" height="254" rx="56" fill="none" stroke="CURRENT" stroke-width="40"/><path d="M219 182c-6-4-14 1-14 8v96c0 7 8 12 14 8l78-48c6-4 6-12 0-16z" fill="CURRENT"/><path d="M180 415q76-24 152 0" fill="none" stroke="CURRENT" stroke-width="28" stroke-linecap="round"/>`},
];
function shape(d,color=d.color,bg='#fff'){return d.body.replaceAll('CURRENT',color).replaceAll('BACKGROUND',bg);}
function svg(d,mono=false){return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><title>源影 · ${d.name}</title>${shape(d,mono?'#16191F':d.color)}</svg>`;}
function icon(d,x,y,size,color=d.color,bg='#fff'){return `<g transform="translate(${x} ${y}) scale(${size/512})">${shape(d,color,bg)}</g>`;}
const text=(x,y,size,fill,content,weight=400)=>`<text x="${x}" y="${y}" font-family="Microsoft YaHei, sans-serif" font-size="${size}" font-weight="${weight}" fill="${fill}">${content}</text>`;
async function main(){
  for(const d of designs){
    fs.writeFileSync(path.join(out,d.id+'.svg'),svg(d));
    fs.writeFileSync(path.join(out,d.id+'-mono.svg'),svg(d,true));
    await sharp(Buffer.from(svg(d))).resize(512,512).png().toFile(path.join(out,d.id+'.png'));
  }
  let board=`<svg xmlns="http://www.w3.org/2000/svg" width="1560" height="1300" viewBox="0 0 1560 1300"><rect width="1560" height="1300" fill="#F4F5F8"/>`;
  board+=text(64,77,18,'#627185','SOURIN / BRAND EXPLORATION',600);
  board+=text(64,136,44,'#171C25','源影 · 四个标识方向',700);
  board+=text(64,179,20,'#657080','同一套深浅色界面，四种不同的品牌气质。');
  designs.forEach((d,i)=>{
    const x=64+(i%2)*732,y=220+Math.floor(i/2)*494;
    board+=`<rect x="${x}" y="${y}" width="700" height="462" rx="26" fill="#FFF"/>`;
    board+=text(x+32,y+49,19,'#8992A1',String(i+1).padStart(2,'0'),600);
    board+=`<rect x="${x+32}" y="${y+86}" width="210" height="210" rx="48" fill="#F5F6F8"/>`;
    board+=icon(d,x+40,y+94,194);
    board+=text(x+284,y+146,36,'#171C25',d.name,700);
    board+=text(x+284,y+186,18,d.color,d.tag,500);
    board+=text(x+284,y+227,17,'#6A7280',d.description.slice(0,17));
    board+=text(x+284,y+254,17,'#6A7280',d.description.slice(17));
    board+=`<path d="M${x+32} ${y+328}H${x+668}" stroke="#EDF0F4"/>`;
    board+=text(x+32,y+368,14,'#8A93A2','深色适配');
    board+=`<rect x="${x+128}" y="${y+346}" width="72" height="72" rx="18" fill="#15181F"/>`;
    board+=icon(d,x+132,y+350,64,'#EDF2FA','#15181F');
    board+=text(x+240,y+368,14,'#8A93A2','单色');board+=icon(d,x+292,y+350,64,'#202733');
    board+=text(x+394,y+368,14,'#8A93A2','32 px / 24 px');
    board+=icon(d,x+508,y+362,32);board+=icon(d,x+562,y+366,24);
  });
  board+=text(64,1256,17,'#768091','候选稿  ·  可编辑 SVG / PNG  ·  尚未替换应用图标');
  board+='</svg>';
  fs.writeFileSync(path.join(out,'overview.svg'),board);
  await sharp(Buffer.from(board)).png().toFile(path.join(out,'overview.png'));
}
main().catch(e=>{console.error(e);process.exitCode=1;});
