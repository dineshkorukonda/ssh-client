// Theme management and LiveView hook
(function() {
  function applyTheme(theme) {
    localStorage.setItem('ssh_client_theme', theme);
    document.documentElement.setAttribute('data-theme', theme);
    if (theme === 'dark') {
      document.documentElement.classList.add('dark');
      document.documentElement.classList.remove('light');
    } else {
      document.documentElement.classList.add('light');
      document.documentElement.classList.remove('dark');
    }
    window.dispatchEvent(new CustomEvent('theme-changed', { detail: { theme: theme } }));
  }

  window.applyAppTheme = applyTheme;

  window.toggleAppTheme = function() {
    var current = document.documentElement.getAttribute('data-theme') || 'dark';
    var next = current === 'dark' ? 'light' : 'dark';
    applyTheme(next);
  };

  window.ThemeHook = {
    mounted: function() {
      var lv = this;
      this.handleEvent('toggle_theme', function(payload) {
        applyTheme(payload.theme);
      });
    }
  };
})();
