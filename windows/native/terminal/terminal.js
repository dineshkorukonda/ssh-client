const terminal = new Terminal({fontFamily:'Consolas, monospace',fontSize:13,scrollback:1000,theme:{background:'#121419',foreground:'#e8e9ed'},cursorBlink:true});
const fit = new FitAddon.FitAddon();
terminal.loadAddon(fit); terminal.open(document.getElementById('terminal'));
const send = message => window.chrome.webview.postMessage(message);
terminal.onData(data => send({type:'input',data}));
terminal.onResize(({cols,rows}) => send({type:'resize',cols,rows}));
new ResizeObserver(() => fit.fit()).observe(document.getElementById('terminal'));
window.chrome.webview.addEventListener('message',({data}) => {
  if(data.type === 'settings') {
    terminal.options.fontSize = data.settings.font_size || 13;
    terminal.options.scrollback = data.settings.scrollback || 1000;
    fit.fit();
  }
  if(data.type === 'output') {
    if(data.snapshot.reset) {terminal.reset(); terminal.write(data.snapshot.screen || '');}
    else for(const chunk of data.snapshot.output) terminal.write(Uint8Array.from(atob(chunk.data), c => c.charCodeAt(0)));
  }
});
send({type:'ready'}); fit.fit();
