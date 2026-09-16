// Dual-Pane Drag & Drop SFTP Hook
(function() {
  window.DualPaneSFTPHook = {
    mounted: function() {
      var lv = this;
      var el = this.el;

      el.addEventListener('dragstart', function(e) {
        var target = e.target.closest('[data-drag-path]');
        if (!target) return;
        var path = target.getAttribute('data-drag-path');
        var side = target.getAttribute('data-drag-side');
        var name = target.getAttribute('data-drag-name');
        var type = target.getAttribute('data-drag-type');

        e.dataTransfer.setData('application/json', JSON.stringify({ path: path, side: side, name: name, type: type }));
        e.dataTransfer.effectAllowed = 'copyMove';
        target.classList.add('opacity-40');
      });

      el.addEventListener('dragend', function(e) {
        var target = e.target.closest('[data-drag-path]');
        if (target) target.classList.remove('opacity-40');
        document.querySelectorAll('[data-drop-side]').forEach(function(node) {
          node.classList.remove('ring-2', 'ring-blue-500', 'bg-blue-500/10');
        });
      });

      el.addEventListener('dragover', function(e) {
        var dropZone = e.target.closest('[data-drop-side]');
        if (!dropZone) return;
        e.preventDefault();
        e.dataTransfer.dropEffect = 'copy';
        dropZone.classList.add('ring-2', 'ring-blue-500', 'bg-blue-500/10');
      });

      el.addEventListener('dragleave', function(e) {
        var dropZone = e.target.closest('[data-drop-side]');
        if (dropZone && !dropZone.contains(e.relatedTarget)) {
          dropZone.classList.remove('ring-2', 'ring-blue-500', 'bg-blue-500/10');
        }
      });

      el.addEventListener('drop', function(e) {
        var dropZone = e.target.closest('[data-drop-side]');
        if (!dropZone) return;
        e.preventDefault();
        dropZone.classList.remove('ring-2', 'ring-blue-500', 'bg-blue-500/10');

        try {
          var raw = e.dataTransfer.getData('application/json');
          if (!raw) return;
          var item = JSON.parse(raw);
          var targetSide = dropZone.getAttribute('data-drop-side');

          if (item.side === 'local' && targetSide === 'remote') {
            lv.pushEvent("drop_upload", { local_path: item.path, filename: item.name });
          } else if (item.side === 'remote' && targetSide === 'local') {
            lv.pushEvent("drop_download", { remote_path: item.path, filename: item.name });
          }
        } catch (err) {
          console.error("Drop transfer error:", err);
        }
      });
    }
  };
})();
