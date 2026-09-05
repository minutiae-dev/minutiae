import type { SessionDetail, Settings, AppStateSnapshot } from './ipc';

const listeners = new Map<string, Set<(payload: unknown) => void>>();
export function listenFixture(event: string, callback: (payload: unknown) => void) {
  if (!listeners.has(event)) listeners.set(event, new Set());
  listeners.get(event)!.add(callback);
  return () => { listeners.get(event)?.delete(callback); };
}
export function emit(event: string, payload: unknown) { listeners.get(event)?.forEach(cb => cb(payload)); }
const delay = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));
const settings: Settings = { schema_version: 1, vault_dir: localStorage.getItem('fixture-vault'), thinking_mode: false, asr_model: 'parakeet-tdt-v3' };
let state: AppStateSnapshot = { state: 'idle', session_id: null, t0_epoch_ms: null, models_ready: true };
const meeting = (id: string, title: string, started: string, text: string): SessionDetail => ({
  session_id: id, dir: `/fixture/sessions/${id}`, title, started_at: started, duration_s: 120,
  segments: [{ idx: 0, channel: 'me', t0: 0, t1: 3, text, confidence: 1, final: true, engine: 'fixture' }],
  scratchpad: localStorage.getItem(`fixture-notes-${id}`) ?? '', enhanced_markdown: null, enhanced_file: null,
});
// Two meetings, because "does an enhancement stay attached to its own meeting
// while you browse another" is not answerable with one.
const session = meeting('fixture-meeting', 'Design review', '2026-09-01T10:00:00Z', 'We agreed to ship the new design on Friday.');
const other = meeting('fixture-standup', 'Weekly standup', '2026-09-02T09:00:00Z', 'Nothing blocking this week.');
let sessions = [session, other];
/** The meeting the Rust core would consider focused (set by `open_session`). */
let focused = session;
let cancelled = false;

/** The gitignored SaaS fixture module, or null in an OSS build (where
 *  `import.meta.glob` resolves to `{}` and the guard is eliminated). */
interface SaasFixtures {
  invoke: (command: string, args: Record<string, unknown>) => Promise<unknown>;
  cloudEnhance?: () => Promise<string | null>;
}
let saasModule: Promise<SaasFixtures | null> | null = null;
function saasFixtures(): Promise<SaasFixtures | null> {
  if (!import.meta.env.VITE_SAAS) return Promise.resolve(null);
  const loader = import.meta.glob('./saas/fixtures.ts')['./saas/fixtures.ts'];
  saasModule ??= loader ? (loader() as Promise<SaasFixtures>) : Promise.resolve(null);
  return saasModule;
}

export async function invokeFixture(command: string, args: Record<string, unknown> = {}): Promise<unknown> {
  switch (command) {
    case 'get_settings': return { ...settings };
    case 'get_state': return { ...state };
    case 'list_devices': return { items: [{ uid: 'fixture-mic', name: 'Fixture microphone', sample_rate: 48000, is_default: true }], output: { name: 'Fixture headphones', transport: 'usb', route: 'headphones' } };
    case 'get_llm_status': return { downloaded: true, ready: true, cloud_active: false };
    case 'set_vault_dir': settings.vault_dir = String(args.dir); localStorage.setItem('fixture-vault', settings.vault_dir); return { ...settings };
    case 'set_thinking_mode': settings.thinking_mode = Boolean(args.on); return { ...settings };
    case 'set_asr_model': settings.asr_model = String(args.model); return { ...settings };
    case 'load_scratchpad': return focused.scratchpad;
    case 'save_scratchpad': focused.scratchpad = String(args.text); localStorage.setItem(`fixture-notes-${focused.session_id}`, focused.scratchpad); return;
    case 'list_sessions': return sessions.map(s => ({ ...s, has_enhanced: Boolean(s.enhanced_markdown) }));
    case 'open_session': focused = sessions.find(s => s.dir === args.dir) ?? focused; return { ...focused };
    case 'delete_session': sessions = sessions.filter(s => s.dir !== args.dir); return;
    case 'start_session':
      state = { ...state, state: 'starting', session_id: session.session_id, t0_epoch_ms: Date.now() }; emit('session:state', state);
      await delay(80); state = { ...state, state: 'recording' }; emit('session:state', state);
      emit('transcript:segment', { session_id: session.session_id, segment: session.segments[0] }); return state;
    case 'stop_session':
      state = { ...state, state: 'stopping' }; emit('session:state', state);
      await delay(80); state = { ...state, state: 'idle' }; emit('session:state', state); return state;
    case 'enhance_session':
      cancelled = false;
      // A cloud enhancement can fail before any local work starts (no quota, a
      // throttled account, a provider outage) and that failure is the SaaS
      // module's to describe, not this one's.
      const cloudFailure = await (await saasFixtures())?.cloudEnhance?.();
      if (cloudFailure) throw new Error(cloudFailure);
      // Bind the result to the meeting that was focused when it started, the
      // way the core scopes an enhancement to its session id.
      const target = focused;
      emit('llm:progress', { pct: 50, stage: 'loading' });
      await delay(800);
      if (cancelled) throw new Error('enhancement cancelled');
      target.enhanced_markdown = `## Decisions\n\n${target.segments[0].text}`;
      target.enhanced_file = `${target.session_id}.md`;
      emit('llm:token', { text: target.enhanced_markdown });
      emit('llm:done', { path: `/fixture/vault/${target.enhanced_file}`, file: target.enhanced_file, tokens_per_s: 20 }); return target.enhanced_file;
    case 'cancel_enhance': cancelled = true; return;
    case 'prepare_models': emit('model:ready', { ready: true }); return;
    case 'prepare_llm': emit('llm:model_ready', { ready: true }); return;
    case 'reveal_transcript_note': return;
    default: {
      const extension = await saasFixtures();
      if (extension) return extension.invoke(command, args);
      throw new Error(`No fixture for command: ${command}`);
    }
  }
}
