const note = document.querySelector('#preview-note');
const buttons = document.querySelectorAll('[data-demo]');
const captures = document.querySelectorAll('[data-capture]');

buttons.forEach((button) => {
  button.addEventListener('click', () => {
    buttons.forEach((tab) => {
      const active = tab === button;
      tab.classList.toggle('active', active);
      tab.setAttribute('aria-pressed', String(active));
    });
    captures.forEach((capture) => {
      capture.hidden = capture.dataset.capture !== button.dataset.demo;
    });
    note.textContent =
      button.dataset.demo === 'apps'
        ? 'Actual Polka app, captured on macOS. Desktop background is illustrative.'
        : 'Actual Polka calculator. Type an expression in the app and press Enter to copy the result.';
  });
});
