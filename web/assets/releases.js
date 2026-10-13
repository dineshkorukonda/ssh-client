// Resolve download buttons from published release assets, independently of site builds.
(async () => {
  const repository = "https://github.com/dineshkorukonda/ssh-client";
  const matchers = {
    installer: /^ssh-client-setup-v[\d.]+-windows-x64\.exe$/,
    portable: /^ssh-client-windows-x64\.zip$/,
    linux: /^ssh-client-linux-x64\.tar\.gz$/
  };
  try {
    const response = await fetch("https://api.github.com/repos/dineshkorukonda/ssh-client/releases/latest");
    if (!response.ok) return;
    const release = await response.json();
    if (release.draft || !Array.isArray(release.assets)) return;
    document.querySelectorAll("[data-release-asset]").forEach(link => {
      const matcher = matchers[link.dataset.releaseAsset];
      const asset = matcher && release.assets.find(item => matcher.test(item.name));
      if (asset && asset.browser_download_url.startsWith(repository + "/releases/download/")) {
        link.href = asset.browser_download_url;
      }
    });
  } catch {
    // Static links still open GitHub's latest release if its API is unavailable.
  }
})();
