// Sync the safety banner's real height into --fab-banner-h. The banner is the sticky header's first
// child (overrides/partials/header.html) and wraps to several lines on narrow screens, so the pieces
// that Material positions from a fixed header height (the drawer, the phone search, the back-to-top
// button, anchor jumps) read this instead. See extra.css. The header persists across instant
// navigation, so one observer covers every page.
(function () {
  var banner = document.querySelector('.md-header .fab-safety-banner');
  if (!banner) { return; }
  function sync() {
    document.documentElement.style.setProperty('--fab-banner-h', banner.offsetHeight + 'px');
  }
  sync();
  // Fires on every height change: window resizes, rotation, and the web font loading and
  // re-wrapping the text.
  if (typeof ResizeObserver !== 'undefined') {
    new ResizeObserver(sync).observe(banner);
  } else {
    window.addEventListener('resize', sync);
    window.addEventListener('load', sync);
  }
})();
