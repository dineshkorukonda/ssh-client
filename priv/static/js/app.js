// Phoenix LiveView Application Entrypoint & Hook Registration
(function() {
  var csrfToken = document.querySelector("meta[name='csrf-token']")
    ? document.querySelector("meta[name='csrf-token']").getAttribute("content")
    : "";

  var hooks = {};
  if (window.TerminalHook) hooks.TerminalHook = window.TerminalHook;
  if (window.TerminalPane) hooks.TerminalPane = window.TerminalPane;
  if (window.DualPaneSFTPHook) hooks.DualPaneSFTPHook = window.DualPaneSFTPHook;
  if (window.CommandPaletteHook) hooks.CommandPaletteHook = window.CommandPaletteHook;
  if (window.ThemeHook) hooks.ThemeHook = window.ThemeHook;

  window.liveSocketHooks = hooks;

  var Socket = (typeof Phoenix !== 'undefined') ? Phoenix.Socket : (window.Socket || null);
  var LiveSocket = (typeof LiveView !== 'undefined') ? LiveView.LiveSocket : (window.LiveSocket || null);

  if (!Socket || !LiveSocket) {
    console.error("Phoenix or LiveView client library failed to load.", { Socket: Socket, LiveSocket: LiveSocket });
    return;
  }

  var liveSocket = new LiveSocket("/live", Socket, {
    params: { _csrf_token: csrfToken },
    hooks: hooks
  });

  liveSocket.connect();
  window.liveSocket = liveSocket;
})();
