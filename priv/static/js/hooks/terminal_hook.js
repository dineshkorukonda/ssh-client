// Interactive Terminal Hooks (Single session TerminalHook & Split-pane TerminalPane)
(function() {
  function getTerminalTheme(isLight) {
    return isLight ? {
      background: '#ffffff',
      foreground: '#09090b',
      cursor:     '#09090b',
      cursorAccent: '#ffffff',
      selectionBackground: 'rgba(0, 0, 0, 0.15)',
      selectionForeground: '#000000',
      black:      '#09090b',
      brightBlack:'#71717a',
      red:        '#dc2626',
      brightRed:  '#ef4444',
      blue:       '#2563eb',
      brightBlue: '#3b82f6',
      cyan:       '#0891b2',
      brightCyan: '#06b6d4',
      green:      '#16a34a',
      brightGreen:'#22c55e',
      yellow:     '#ca8a04',
      brightYellow:'#eab308',
      magenta:    '#9333ea',
      brightMagenta: '#a855f7',
      white:      '#f4f4f5',
      brightWhite:'#ffffff'
    } : {
      background: '#09090b',
      foreground: '#fafafa',
      cursor:     '#fafafa',
      cursorAccent: '#09090b',
      selectionBackground: 'rgba(255, 255, 255, 0.25)',
      selectionForeground: '#ffffff',
      black:      '#09090b',
      brightBlack:'#3f3f46',
      red:        '#ef4444',
      brightRed:  '#f87171',
      blue:       '#38bdf8',
      brightBlue: '#60a5fa',
      cyan:       '#06b6d4',
      brightCyan: '#22d3ee',
      green:      '#10b981',
      brightGreen:'#34d399',
      yellow:     '#f59e0b',
      brightYellow:'#fbbf24',
      magenta:    '#d946ef',
      brightMagenta: '#f472b6',
      white:      '#a1a1aa',
      brightWhite:'#fafafa'
    };
  }

  window.getTerminalTheme = getTerminalTheme;

  function cancelFitTimers(lv) {
    if (lv._fitTimers) {
      lv._fitTimers.forEach(function(id) { clearTimeout(id); });
      lv._fitTimers = [];
    }
    if (lv._fitRaf) {
      cancelAnimationFrame(lv._fitRaf);
      lv._fitRaf = null;
    }
  }

  function teardownTerminal(lv) {
    lv._destroyed = true;
    cancelFitTimers(lv);
    if (lv.doFit) window.removeEventListener('resize', lv.doFit);
    if (lv.resizeObserver) {
      try { lv.resizeObserver.disconnect(); } catch (e) {}
      lv.resizeObserver = null;
    }
    if (lv.term) {
      try { lv.term.dispose(); } catch (e) {}
      lv.term = null;
    }
  }

  function makeSafeWrite(lv, term) {
    return function(data) {
      if (lv._destroyed || !term || !data) return;
      try {
        term.write(data);
      } catch (e) {}
    };
  }

  function setupKeyHandlers(term, onFontChange, onPaste, pushEvent) {
    term.attachCustomKeyEventHandler(function(e) {
      if ((e.ctrlKey || e.metaKey) && (e.key === 'c' || e.key === 'C') && e.type === 'keydown') {
        if (term.hasSelection()) {
          var sel = term.getSelection();
          if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(sel).catch(function() {});
          }
          return false;
        }
        return true;
      }

      if ((e.ctrlKey || e.metaKey) && (e.key === 'v' || e.key === 'V') && e.type === 'keydown') {
        if (navigator.clipboard && navigator.clipboard.readText) {
          navigator.clipboard.readText().then(function(text) {
            if (text && onPaste) onPaste(text);
          }).catch(function() {});
          return false;
        }
      }

      if ((e.ctrlKey || e.metaKey) && (e.key === '=' || e.key === '+') && e.type === 'keydown') {
        if (onFontChange) onFontChange(1);
        return false;
      }
      if ((e.ctrlKey || e.metaKey) && (e.key === '-' || e.key === '_') && e.type === 'keydown') {
        if (onFontChange) onFontChange(-1);
        return false;
      }

      // Keyboard shortcuts modal toggle (Ctrl+Shift+? or Ctrl+Shift+/)
      if ((e.ctrlKey || e.metaKey) && e.shiftKey && (e.key === '?' || e.key === '/') && e.type === 'keydown') {
        if (pushEvent) pushEvent("toggle_shortcuts", {});
        return false;
      }

      return true;
    });

    term.onSelectionChange(function() {
      var selection = term.getSelection();
      if (selection && selection.trim().length > 0) {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(selection).catch(function() {});
        }
      }
    });
  }

  window.TerminalHook = {
    mounted: function() {
      var el = this.el;
      var lv = this;

      if (typeof Terminal === 'undefined') {
        el.innerHTML = '<div style="color:#ef4444;font-family:monospace;padding:1rem">xterm.js not loaded</div>';
        return;
      }

      var currentFontSize = 13;
      var isLight = document.documentElement.getAttribute('data-theme') === 'light';

      var term = new Terminal({
        cursorBlink: true,
        fontSize: currentFontSize,
        lineHeight: 1.25,
        fontFamily: "'JetBrains Mono', 'Cascadia Code', 'Consolas', monospace",
        allowTransparency: true,
        scrollback: 10000,
        theme: getTerminalTheme(isLight)
      });

      var fitAddon = (typeof FitAddon !== 'undefined') ? new FitAddon.FitAddon() : null;
      if (fitAddon) term.loadAddon(fitAddon);

      var searchAddon = (typeof SearchAddon !== 'undefined') ? new SearchAddon.SearchAddon() : null;
      if (searchAddon) term.loadAddon(searchAddon);

      term.open(el);

      lv._destroyed = false;
      lv._fitTimers = [];
      lv._fitRaf = null;
      var started = false;
      var pendingOutput = [];
      var safeWrite = makeSafeWrite(lv, term);

      var safePushEvent = function(event, payload) {
        try {
          if (lv._destroyed) return;
          if (lv.liveSocket && typeof lv.liveSocket.isConnected === "function" && !lv.liveSocket.isConnected()) {
            return;
          }
          if (typeof lv.pushEvent === "function") {
            lv.pushEvent(event, payload);
          }
        } catch(e) {
          // Socket might still be connecting or destroyed
        }
      };

      var flushPending = function() {
        if (!started || lv._destroyed) return;
        for (var i = 0; i < pendingOutput.length; i++) {
          safeWrite(pendingOutput[i]);
        }
        pendingOutput = [];
      };

      var enqueueWrite = function(data) {
        if (lv._destroyed || !data) return;
        if (!started) {
          pendingOutput.push(data);
          return;
        }
        safeWrite(data);
      };

      var doFit = function() {
        if (lv._destroyed || !fitAddon || !el.clientWidth || !el.clientHeight) return;
        try {
          fitAddon.fit();
          if (term.cols > 0 && term.rows > 0) {
            if (!started) {
              started = true;
              term.writeln('\x1b[1;34mssh-client\x1b[0m');
              term.writeln('\x1b[2mConnecting to ' + (el.dataset.serverId || 'server') + '...\x1b[0m');
              term.writeln('');
              safePushEvent("terminal_ready", {});
              flushPending();
            }
            safePushEvent("resize", { cols: term.cols, rows: term.rows });
          }
        } catch(e) {
          console.debug("fit error:", e);
        }
      };

      lv._fitRaf = requestAnimationFrame(doFit);
      lv._fitTimers.push(setTimeout(doFit, 30));
      lv._fitTimers.push(setTimeout(doFit, 150));
      lv._fitTimers.push(setTimeout(doFit, 400));

      var resizeObserver = null;
      if (window.ResizeObserver) {
        resizeObserver = new ResizeObserver(function() {
          if (lv._destroyed) return;
          lv._fitRaf = requestAnimationFrame(doFit);
        });
        resizeObserver.observe(el);
      }

      this.handleEvent("terminal_output", function(payload) {
        enqueueWrite(payload.data);
      });

      this.handleEvent("terminal_paste", function() {
        if (navigator.clipboard && navigator.clipboard.readText) {
          navigator.clipboard.readText().then(function(text) {
            if (text) safePushEvent("terminal_data", { data: text });
          }).catch(function(err) {
            console.warn("Clipboard read error:", err);
          });
        }
      });

      this.handleEvent("terminal_insert_command", function(payload) {
        var data = payload.execute ? (payload.command + "\n") : payload.command;
        safePushEvent("terminal_data", { data: data });
        if (!lv._destroyed) term.focus();
      });

      this.handleEvent("terminal_clear", function() {
        if (lv._destroyed) return;
        try { term.clear(); } catch (e) {}
      });

      this.handleEvent("terminal_font_change", function(payload) {
        if (lv._destroyed) return;
        currentFontSize = Math.max(9, Math.min(24, currentFontSize + payload.delta));
        term.options.fontSize = currentFontSize;
        lv._fitRaf = requestAnimationFrame(doFit);
      });

      term.onData(function(data) {
        safePushEvent("terminal_data", { data: data });
      });

      setupKeyHandlers(
        term,
        function(delta) {
          if (lv._destroyed) return;
          currentFontSize = Math.max(9, Math.min(24, currentFontSize + delta));
          term.options.fontSize = currentFontSize;
          lv._fitRaf = requestAnimationFrame(doFit);
        },
        function(text) {
          safePushEvent("terminal_data", { data: text });
        },
        safePushEvent
      );

      window.addEventListener('resize', doFit);
      this.doFit = doFit;
      this.resizeObserver = resizeObserver;
      this.term = term;
    },
    destroyed: function() {
      teardownTerminal(this);
    }
  };

  window.TerminalPane = {
    mounted: function() {
      var el = this.el;
      var lv = this;
      var paneId = el.dataset.sessionId || el.dataset.paneId;
      if (!paneId) return;

      if (typeof Terminal === 'undefined') {
        el.innerHTML = '<div style="color:#ef4444;font-family:monospace;padding:1rem">xterm.js not loaded</div>';
        return;
      }

      var currentFontSize = 13;
      var isLight = document.documentElement.getAttribute('data-theme') === 'light';

      var term = new Terminal({
        cursorBlink: true,
        fontSize: currentFontSize,
        lineHeight: 1.25,
        fontFamily: "'JetBrains Mono', 'Cascadia Code', 'Consolas', monospace",
        allowTransparency: true,
        scrollback: 10000,
        theme: getTerminalTheme(isLight)
      });

      var fitAddon = (typeof FitAddon !== 'undefined') ? new FitAddon.FitAddon() : null;
      if (fitAddon) term.loadAddon(fitAddon);

      term.open(el);

      lv._destroyed = false;
      lv._fitTimers = [];
      lv._fitRaf = null;
      var started = false;
      var pendingOutput = [];
      var safeWrite = makeSafeWrite(lv, term);

      var safePushEvent = function(event, payload) {
        try {
          if (lv._destroyed) return;
          if (lv.liveSocket && typeof lv.liveSocket.isConnected === "function" && !lv.liveSocket.isConnected()) {
            return;
          }
          if (typeof lv.pushEvent === "function") {
            lv.pushEvent(event, payload);
          }
        } catch(e) {
          // Socket might still be connecting or destroyed
        }
      };

      var flushPending = function() {
        if (!started || lv._destroyed) return;
        for (var i = 0; i < pendingOutput.length; i++) {
          safeWrite(pendingOutput[i]);
        }
        pendingOutput = [];
      };

      var enqueueWrite = function(data) {
        if (lv._destroyed || !data) return;
        if (!started) {
          pendingOutput.push(data);
          return;
        }
        safeWrite(data);
      };

      var doFit = function() {
        if (lv._destroyed || !fitAddon || !el.clientWidth || !el.clientHeight) return;
        try {
          fitAddon.fit();
          if (term.cols > 0 && term.rows > 0) {
            if (!started) {
              started = true;
              safePushEvent("pane_ready", { pane_id: paneId });
              flushPending();
            }
            safePushEvent("pane_resize", { pane_id: paneId, cols: term.cols, rows: term.rows });
          }
        } catch(e) {}
      };

      lv._fitRaf = requestAnimationFrame(doFit);
      lv._fitTimers.push(setTimeout(doFit, 40));
      lv._fitTimers.push(setTimeout(doFit, 150));
      lv._fitTimers.push(setTimeout(doFit, 400));

      var resizeObserver = null;
      if (window.ResizeObserver) {
        resizeObserver = new ResizeObserver(function() {
          if (lv._destroyed) return;
          lv._fitRaf = requestAnimationFrame(doFit);
        });
        resizeObserver.observe(el);
      }

      term.onData(function(data) {
        safePushEvent("pane_data", { pane_id: paneId, data: data });
      });

      this.handleEvent("terminal_output_" + paneId, function(payload) {
        enqueueWrite(payload.data);
      });

      this.handleEvent("terminal_clear_" + paneId, function() {
        if (lv._destroyed) return;
        pendingOutput = [];
        try { term.clear(); } catch (e) {}
      });

      this.handleEvent("terminal_focus_" + paneId, function() {
        if (!lv._destroyed) term.focus();
      });

      this.handleEvent("terminal_paste_" + paneId, function() {
        if (navigator.clipboard && navigator.clipboard.readText) {
          navigator.clipboard.readText().then(function(text) {
            if (text) safePushEvent("pane_data", { pane_id: paneId, data: text });
          }).catch(function() {});
        }
      });

      this.handleEvent("terminal_font_change_" + paneId, function(payload) {
        if (lv._destroyed) return;
        currentFontSize = Math.max(9, Math.min(24, currentFontSize + payload.delta));
        term.options.fontSize = currentFontSize;
        lv._fitRaf = requestAnimationFrame(doFit);
      });

      setupKeyHandlers(
        term,
        function(delta) {
          if (lv._destroyed) return;
          currentFontSize = Math.max(9, Math.min(24, currentFontSize + delta));
          term.options.fontSize = currentFontSize;
          lv._fitRaf = requestAnimationFrame(doFit);
        },
        function(text) {
          safePushEvent("pane_data", { pane_id: paneId, data: text });
        },
        safePushEvent
      );

      window.addEventListener('resize', doFit);
      this.doFit = doFit;
      this.resizeObserver = resizeObserver;
      this.term = term;
    },
    destroyed: function() {
      teardownTerminal(this);
    }
  };
})();
