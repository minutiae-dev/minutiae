import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
const root = mkdtempSync(`${tmpdir()}/minutiae-native-`);
writeFileSync(`${root}/.native-test`, '');
mkdirSync(`${root}/vault`);
process.env.MINUTIAE_TEST_DATA_DIR = root;
process.env.MINUTIAE_TEST_SIDECAR = resolve('tests/native/sidecar.py');
/// The `native-test` build (`pnpm build:native-test`) lands in cargo's target
/// directory, which is not always `src-tauri/target` — a shared target dir is
/// common — so ask cargo rather than guessing.
function defaultBinary() {
  const metadata = JSON.parse(execFileSync('cargo', [
    'metadata', '--manifest-path', 'src-tauri/Cargo.toml', '--format-version', '1', '--no-deps',
  ], { encoding: 'utf8', maxBuffer: 32 * 1024 * 1024 }));
  return join(metadata.target_directory, 'debug', 'minutiae');
}

// Never the release app: this build talks to a synthetic sidecar and refuses to
// start without an isolated data directory.
const binary = process.env.MINUTIAE_TEST_BINARY ?? defaultBinary();
export const config = {
  runner: 'local', specs: ['./tests/native/*.spec.mjs'], maxInstances: 1,
  capabilities: [{ browserName: 'tauri', 'tauri:options': { application: binary } }],
  services: [['@wdio/tauri-service', { appBinaryPath: binary, driverProvider: 'embedded', captureBackendLogs: true }]],
  framework: 'mocha', reporters: ['spec'], logLevel: 'warn',
  mochaOpts: { timeout: 30000 },
  onComplete() { rmSync(root, { recursive: true, force: true }); },
};
