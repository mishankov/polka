(() => {
  // Match NativeShelfPresentationView: keep the image at its final size and
  // reveal it with a mask. This capture has no safe-area inset, so its closed
  // mask is 96 × 3 points; the native opening takes 100 ms with ease-out.
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  const shelf = document.querySelector('.screenshot-mount img');
  if (shelf && !reducedMotion.matches && typeof shelf.animate === 'function'
    && CSS.supports('clip-path', 'path("M0 0 L1 0 L1 1 Z")')) {
    let animation;
    let completed = false;
    let timeout;
    const sourceWidth = Number(shelf.getAttribute('width'));
    const sourceHeight = Number(shelf.getAttribute('height'));
    function mask(open) {
      const scale = shelf.getBoundingClientRect().width / sourceWidth;
      const width = (open ? sourceWidth : Math.min(96, sourceWidth)) * scale;
      const height = (open ? sourceHeight : 3) * scale;
      const left = (sourceWidth * scale - width) / 2;
      const right = left + width;
      const radius = Math.min((open ? 22 : 12) * scale, width / 2, height / 2);
      // Use the same line and quadratic-curve segments as the native mask.
      return `path("M ${left} 0 L ${right} 0 L ${right} ${height - radius} Q ${right} ${height} ${right - radius} ${height} L ${left + radius} ${height} Q ${left} ${height} ${left} ${height - radius} Z")`;
    }


    const finishReveal = () => {
      if (completed) return;
      completed = true;
      clearTimeout(timeout);
      animation?.cancel();
      shelf.style.removeProperty('clip-path');
      reducedMotion.removeEventListener('change', motionChanged);
      window.removeEventListener('resize', finishReveal);
      window.removeEventListener('pagehide', finishReveal);
    };
    const motionChanged = event => { if (event.matches) finishReveal(); };

    // Hold only the closed shelf while the real screenshot decodes. Text,
    // controls, the mat, and the final image dimensions stay in place.
    shelf.style.clipPath = mask(false);
    reducedMotion.addEventListener('change', motionChanged);
    window.addEventListener('resize', finishReveal);
    window.addEventListener('pagehide', finishReveal);
    timeout = setTimeout(finishReveal, 2000);
    shelf.decode().then(() => {
      if (completed || reducedMotion.matches) return finishReveal();
      clearTimeout(timeout);
      animation = shelf.animate(
        [
          { clipPath: mask(false) },
          { clipPath: mask(true) }
        ],
        // A short hold makes the initial state readable on page load; the
        // expansion itself uses the app's duration and easing.
        { delay: 350, duration: 100, easing: 'cubic-bezier(0,0,.58,1)', iterations: 1, fill: 'backwards' }
      );
      shelf.style.removeProperty('clip-path');
      animation.finished.then(finishReveal, finishReveal);
    }).catch(finishReveal);
    // No scroll, hash, or tab-change handlers restart this reveal. Returning
    // from the back-forward cache leaves the already-open screenshot visible.
  }

  const methods = document.querySelector('.install-methods');
  const tablist = methods?.querySelector('[role="tablist"]');
  if (!tablist) return;
  const tabs = [...tablist.querySelectorAll('[role="tab"]')];
  const panels = [...methods.querySelectorAll('[role="tabpanel"]')];

  function selectMethod(tab) {
    if (tab.disabled) return;
    const selectedPanel = tab.getAttribute('aria-controls');
    tabs.forEach(item => {
      const selected = item === tab;
      item.setAttribute('aria-selected', String(selected));
      item.tabIndex = selected ? 0 : -1;
    });
    panels.forEach(panel => { panel.hidden = panel.id !== selectedPanel; });
  }

  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => selectMethod(tab));
    tab.addEventListener('keydown', event => {
      if (event.isComposing || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey) return;
      let next;
      if (event.key === 'ArrowRight') next = tabs[(index + 1) % tabs.length];
      if (event.key === 'ArrowLeft') next = tabs[(index - 1 + tabs.length) % tabs.length];
      if (event.key === 'Home') next = tabs[0];
      if (event.key === 'End') next = tabs[tabs.length - 1];
      if (!next) return;
      event.preventDefault();
      if (event.repeat || next.disabled) return;
      next.focus();
      selectMethod(next);
    });
  });
  selectMethod(tabs[0]);
  methods.classList.add('is-enhanced');
  tablist.hidden = false;
})();
