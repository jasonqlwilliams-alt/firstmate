// Execute the built board and exercise its public controls without a browser.
import {readFileSync} from "node:fs";
import vm from "node:vm";
const html=readFileSync(process.argv[2],"utf8");
class Node {
  constructor(tag){this.tagName=tag;this.children=[];this.dataset={};this.listeners={};this.checked=false;this.hidden=false;this.value="";this._text="";}
  set textContent(value){this._text=String(value);this.children=[];}
  get textContent(){return this._text+this.children.map(c=>c.textContent).join(" ");}
  append(...nodes){this.children.push(...nodes);}
  replaceChildren(...nodes){this.children=nodes;}
  setAttribute(){}
  addEventListener(name,fn){(this.listeners[name] ||= []).push(fn);}
  fire(name){for(const fn of this.listeners[name]||[])fn({preventDefault(){},currentTarget:this});}
}
const ids=new Map();
const get=id=>{if(!ids.has(id))ids.set(id,new Node("div"));return ids.get(id);};
get("lineup-data").textContent=html.split('<script id="lineup-data" type="application/json">')[1].split("</script>")[0];
for(const id of ["fallback-arrays","restart-secondmates"]){
  const input=html.match(new RegExp('<input[^>]*id="'+id+'"[^>]*>'))?.[0]||"";
  get(id).checked=/\bchecked(?:\s|=|>)/.test(input);
}
let answer,capture,sent=0;
const context={document:{getElementById:get,createElement:tag=>new Node(tag)},window:{lavish:{queuePrompt:(prompt,options)=>{answer=options.data;capture={prompt,text:options.text,tag:options.tag};},sendQueuedPrompts:()=>{sent++;}}}};
const script=html.match(/<script>\s*([\s\S]*?)<\/script>/)[1];
vm.runInNewContext(script,context);
const defaultRestart=get("restart-secondmates").checked,defaultFallback=get("fallback-arrays").checked;
get("instructions").value="Typed override\nwith every character ✓";
get("lineup-form").fire("submit");
process.stdout.write(JSON.stringify({scores:get("benchmarks").textContent,defaultRestart,defaultFallback,answer,capture,sent})+"\n");
