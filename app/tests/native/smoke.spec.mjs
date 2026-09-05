import assert from 'node:assert/strict';
it('records through real Rust commands into isolated storage', async () => {
  const settings = await browser.tauri.execute(({ core }) => core.invoke('get_settings'));
  assert.equal(settings.vault_dir, null);
  await browser.waitUntil(async () => {
    try { return (await browser.tauri.execute(({ core }) => core.invoke('list_devices'))).items.length === 1; }
    catch { return false; }
  });
  const started = await browser.tauri.execute(({ core }) => core.invoke('start_session', { micUid: 'synthetic', themSource: 'system' }));
  assert.equal(started.state, 'recording');
  await browser.tauri.execute(({ core }) => core.invoke('save_scratchpad', { text: 'Native smoke notes' }));
  const stopped = await browser.tauri.execute(({ core }) => core.invoke('stop_session'));
  assert.equal(stopped.state, 'idle');
  const sessions = await browser.tauri.execute(({ core }) => core.invoke('list_sessions'));
  assert.equal(sessions.length, 1);
  assert.match(sessions[0].dir, /minutiae-native-/);
  const detail = await browser.tauri.execute(({ core }, dir) => core.invoke('open_session', { dir }), sessions[0].dir);
  assert.equal(detail.scratchpad, 'Native smoke notes');
  assert.equal(detail.segments[0].text, 'Synthetic meeting transcript.');
});
