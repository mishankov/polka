import { test, expect } from '@playwright/test';

test('keyboard navigation exposes each real screenshot and continues through the page', async ({
  page,
}) => {
  await page.goto('/');
  const apps = page.getByRole('tab', { name: 'Apps', exact: true });
  await page.keyboard.press('Tab');
  await expect(page.getByRole('link', { name: 'Skip to content' })).toBeFocused();
  // Follow the document's tab order to reach the gallery without pointer input.
  for (
    let step = 0;
    step < 12 && !(await apps.evaluate((el) => el === document.activeElement));
    step++
  ) {
    await page.keyboard.press('Tab');
  }
  await expect(apps).toBeFocused();
  for (const name of ['Clipboard', 'Snippets', 'Emoji', 'Files', 'Apps']) {
    await page.keyboard.press('ArrowRight');
    await expect(page.getByRole('tab', { name, exact: true })).toBeFocused();
    await expect(page.getByRole('tab', { name, exact: true })).toHaveAttribute(
      'aria-selected',
      'true',
    );
    await expect(page.getByRole('tabpanel', { name, exact: true })).toBeVisible();
    await expect(page.getByRole('tabpanel')).toHaveCount(1);
  }
  await page.keyboard.press('End');
  await expect(page.getByRole('tab', { name: 'Files', exact: true })).toBeFocused();
  await page.keyboard.press('Home');
  await expect(apps).toBeFocused();
  await page.keyboard.press('Tab');
  await expect(page.getByRole('tabpanel', { name: 'Apps', exact: true })).toBeFocused();
  const installation = page.getByText('Installing for the first time?', { exact: true });
  await installation.focus();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('link', { name: 'installation guide', exact: true })).toBeVisible();
});

test('gallery guards composition, repeated keys and disabled tabs without global bindings', async ({
  page,
}) => {
  await page.goto('/');
  const apps = page.getByRole('tab', { name: 'Apps', exact: true });
  await apps.focus();
  for (const extra of [
    { isComposing: true },
    { repeat: true },
    { metaKey: true },
    { ctrlKey: true },
    { altKey: true },
  ]) {
    await apps.dispatchEvent('keydown', { key: 'ArrowRight', code: 'ArrowRight', ...extra });
    await expect(apps).toHaveAttribute('aria-selected', 'true');
  }
  // A Cyrillic character with an arrow-like physical code must remain ordinary input.
  await apps.dispatchEvent('keydown', { key: 'ф', code: 'ArrowRight' });
  await expect(apps).toHaveAttribute('aria-selected', 'true');
  await page.getByRole('tab', { name: 'Clipboard', exact: true }).evaluate((el) => {
    el.disabled = true;
  });
  await page.keyboard.press('ArrowRight');
  await expect(page.getByRole('tab', { name: 'Snippets', exact: true })).toBeFocused();
  await page.getByRole('tab', { name: 'Emoji', exact: true }).click();
  await expect(page.getByRole('tabpanel', { name: 'Emoji', exact: true })).toBeVisible();
  await page.getByRole('link', { name: 'Skip to content' }).focus();
  await page.keyboard.press('ArrowLeft');
  await expect(page.getByRole('tab', { name: 'Emoji', exact: true })).toHaveAttribute(
    'aria-selected',
    'true',
  );
});

for (const width of [390, 1440]) {
  test(`all captures load and fit at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 1000 });
    await page.goto('/');
    for (const name of ['Apps', 'Clipboard', 'Snippets', 'Emoji', 'Files']) {
      await page.getByRole('tab', { name, exact: true }).click();
      const image = page.getByRole('tabpanel').locator('img');
      await expect
        .poll(() => image.evaluate((el) => el.complete && el.naturalWidth > 0))
        .toBe(true);
      const bounds = await image.boundingBox();
      const frame = await page.locator('.desktop').boundingBox();
      expect(bounds.x).toBeGreaterThanOrEqual(frame.x);
      expect(bounds.x + bounds.width).toBeLessThanOrEqual(frame.x + frame.width);
      expect(bounds.y + bounds.height).toBeLessThanOrEqual(frame.y + frame.height);
    }
    expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(width);
    await expect(
      page.getByRole('link', { name: 'Get Polka for Mac', exact: false }),
    ).toHaveAttribute('href', 'https://github.com/mishankov/polka/releases/latest');
  });
}
