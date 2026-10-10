const tabs = [...document.querySelectorAll('[role="tab"]')];

function selectTab(tab, focus = false) {
  if (tab.disabled || tab.getAttribute('aria-disabled') === 'true') return;
  tabs.forEach((item) => {
    const active = item === tab;
    item.classList.toggle('active', active);
    item.setAttribute('aria-selected', String(active));
    item.tabIndex = active ? 0 : -1;
    document.getElementById(item.getAttribute('aria-controls')).hidden = !active;
  });
  if (focus) tab.focus();
}

tabs.forEach((tab) => {
  tab.addEventListener('click', () => selectTab(tab));
  tab.addEventListener('keydown', (event) => {
    if (
      event.isComposing ||
      event.repeat ||
      event.metaKey ||
      event.ctrlKey ||
      event.altKey ||
      event.shiftKey
    )
      return;
    const available = tabs.filter(
      (item) => !item.disabled && item.getAttribute('aria-disabled') !== 'true',
    );
    const index = available.indexOf(tab);
    const next = {
      ArrowRight: (index + 1) % available.length,
      ArrowLeft: (index - 1 + available.length) % available.length,
      Home: 0,
      End: available.length - 1,
    }[event.key];
    if (next === undefined || index < 0) return;
    event.preventDefault();
    selectTab(available[next], true);
  });
});
