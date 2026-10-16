const themes = {
  dark: {background:'#0b0d11',foreground:'#f1f3f7',cursor:'#77b8ff',selectionBackground:'#334969'},
  light: {background:'#f6f8fb',foreground:'#172133',cursor:'#1769c2',selectionBackground:'#bfd9f5'}
};
const terminal = new Terminal({fontFamily:'Cascadia Code, Consolas, monospace',fontSize:13,lineHeight:1.15,scrollback:1000,theme:themes.dark,cursorBlink:true});
const fit = new FitAddon.FitAddon();
terminal.loadAddon(fit); terminal.open(document.getElementById('terminal'));
const send = message => window.chrome.webview.postMessage(message);
terminal.attachCustomKeyEventHandler(event => {
  if(event.ctrlKey && event.key.toLowerCase() === 'k') { if(event.type === 'keydown') send({type:'palette'}); return false; }
  if(event.ctrlKey && event.shiftKey && !event.altKey && event.key.toLowerCase() === 'b') { if(event.type === 'keydown') send({type:'sidebar'}); return false; }
  return true;
});
terminal.onData(data => send({type:'input',data}));
terminal.onResize(({cols,rows}) => send({type:'resize',cols,rows}));
let fitting = false;
const scheduleFit = () => {
  if(fitting) return;
  fitting = true;
  requestAnimationFrame(() => {
    fitting = false;
    const bounds = document.getElementById('terminal').getBoundingClientRect();
    if(bounds.width > 20 && bounds.height > 20) fit.fit();
  });
};
new ResizeObserver(scheduleFit).observe(document.getElementById('terminal'));
window.chrome.webview.addEventListener('message',({data}) => {
  if(data.type === 'settings') {
    terminal.options.fontSize = data.settings.font_size || 13;
    terminal.options.fontFamily = `${data.settings.font_family || 'Cascadia Code'}, Consolas, monospace`;
    terminal.options.lineHeight = data.settings.line_height || 1.15;
    terminal.options.scrollback = data.settings.scrollback || 1000;
    terminal.options.theme = themes[data.settings.theme] || themes.dark;
    document.documentElement.style.setProperty('--terminal-background', terminal.options.theme.background);
    terminal.options.cursorBlink = !data.settings.reduced_motion && !matchMedia('(prefers-reduced-motion: reduce)').matches;
    scheduleFit();
  }
  if(data.type === 'output') {
    if(data.snapshot.reset) {terminal.reset(); terminal.write(data.snapshot.screen || '');}
    else for(const chunk of data.snapshot.output) terminal.write(Uint8Array.from(atob(chunk.data), c => c.charCodeAt(0)));
  }
});
send({type:'ready'}); scheduleFit();
