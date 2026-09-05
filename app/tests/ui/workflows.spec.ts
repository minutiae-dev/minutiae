import { test, expect } from '@playwright/test';

test('recording transitions and scratchpad survive reload', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('button', { name: 'Record', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Stop', exact: true })).toBeEnabled();
  await page.getByRole('textbox', { name: 'Meeting notes' }).fill('Follow up with design');
  await page.getByRole('textbox', { name: 'Meeting notes' }).blur();
  await expect(page.getByText('Saved', { exact: true })).toBeVisible();
  await page.getByRole('button', { name: 'Stop', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Record', exact: true })).toBeEnabled();
  await page.reload();
  await page.getByRole('button', { name: /Design review/ }).first().click();
  await expect(page.getByRole('textbox', { name: 'Meeting notes' })).toHaveValue('Follow up with design');
});

test('choose a vault and cancel enhancement', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('button', { name: /Design review/ }).first().click();
  await page.getByRole('button', { name: 'Choose folder…', exact: true }).click();
  await page.getByRole('tab', { name: 'Enhanced', exact: true }).click();
  await page.getByRole('button', { name: 'Enhance notes', exact: true }).click();
  await page.getByRole('button', { name: 'Interrupt', exact: true }).click();
  await expect(page.getByRole('button', { name: 'Interrupt', exact: true })).toHaveCount(0);
  await expect(page.getByText('Ship the new design on Friday.', { exact: true })).toHaveCount(0);
});

test('an enhancement stays attached to its own meeting while you browse', async ({ page }) => {
  await page.goto('/');
  await page.getByRole('button', { name: /Design review/ }).first().click();
  await page.getByRole('button', { name: 'Choose folder…', exact: true }).click();
  await page.getByRole('tab', { name: 'Enhanced', exact: true }).click();
  await page.getByRole('button', { name: 'Enhance notes', exact: true }).click();

  // Walk away mid-run. The other meeting must not show this one's output, and
  // must not offer to start a second enhancement on top of it.
  await page.getByRole('button', { name: /Weekly standup/ }).first().click();
  await page.getByRole('tab', { name: 'Enhanced', exact: true }).click();
  await expect(page.getByText('Ship the new design on Friday.')).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Enhance notes', exact: true })).toBeDisabled();

  await page.getByRole('button', { name: /Design review/ }).first().click();
  await expect(page.getByText('Ship the new design on Friday.')).toBeVisible();
});
