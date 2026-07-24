// Sync the pinned safety banner's real height into --fab-banner-h so the sticky header
// sits directly below it (the banner wraps to 2+ lines on narrow screens). See extra.css.
(function () {
  function sync() {
    // Measure the sticky announce wrapper (its height == the banner's) so the header stacks below it.
    var b = document.querySelector('[data-md-component="announce"]') || document.querySelector('.md-banner');
    if (b) {
      document.documentElement.style.setProperty('--fab-banner-h', b.offsetHeight + 'px');
    }
  }
  window.addEventListener('load', sync);
  window.addEventListener('resize', sync);
  document.addEventListener('DOMContentLoaded', sync);
  // Re-sync after mkdocs-material instant navigation, just in case.
  if (typeof document$ !== 'undefined' && document$.subscribe) { document$.subscribe(sync); }
})();
