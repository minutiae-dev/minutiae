import { invoke as tauriInvoke } from '@tauri-apps/api/core';
import { listen as tauriListen, type EventCallback, type UnlistenFn } from '@tauri-apps/api/event';
import { open as tauriOpen } from '@tauri-apps/plugin-dialog';

// Both a development build and an explicit mode are required. Production
// bundles cannot enable fixtures through a URL or local storage setting.
export const fixtureMode = import.meta.env.DEV && import.meta.env.MODE === 'ui-fixtures';
const fixtures = fixtureMode ? import('./fixtures') : null;

export async function invoke<T>(command: string, args?: Record<string, unknown>): Promise<T> {
  if (fixtures) return (await fixtures).invokeFixture(command, args) as Promise<T>;
  return tauriInvoke<T>(command, args);
}
export async function listen<T>(event: string, callback: EventCallback<T>): Promise<UnlistenFn> {
  if (fixtures) return (await fixtures).listenFixture(event, payload => callback({ event, id: 0, payload: payload as T }));
  return tauriListen<T>(event, callback);
}
export async function open(options?: Parameters<typeof tauriOpen>[0]): Promise<string | string[] | null> {
  if (fixtures) return options?.multiple ? ['/fixture/vault'] : '/fixture/vault';
  return tauriOpen(options);
};
