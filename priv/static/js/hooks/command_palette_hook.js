// Universal Command Palette keyboard shortcut hook
(function() {
  window.CommandPaletteHook = {
    mounted: function() {
      var lv = this;
      var handler = function(e) {
        if ((e.ctrlKey || e.metaKey) && (e.key === 'k' || e.key === 'K')) {
          e.preventDefault();
          lv.pushEvent("toggle_command_palette", {});
        }
        if (e.key === 'Escape') {
          lv.pushEvent("close_command_palette", {});
        }
      };
      window.addEventListener('keydown', handler);
      this.handler = handler;
    },
    destroyed: function() {
      if (this.handler) {
        window.removeEventListener('keydown', this.handler);
      }
    }
  };
})();
