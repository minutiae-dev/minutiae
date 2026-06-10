<script lang="ts">
  import { onMount } from "svelte";
  import { session } from "./lib/stores/session.svelte";
  import DevicePicker from "./lib/components/DevicePicker.svelte";
  import CaptureControls from "./lib/components/CaptureControls.svelte";
  import LevelMeter from "./lib/components/LevelMeter.svelte";
  import TranscriptPane from "./lib/components/TranscriptPane.svelte";

  onMount(() => {
    session.init();
    return () => session.destroy();
  });
</script>

<main>
  <header>
    <h1>Minutiae</h1>
    <span class="state-badge {session.phase}">{session.phase}</span>
  </header>

  <section class="controls-row">
    <DevicePicker />
    <div class="spacer"></div>
    <CaptureControls />
  </section>

  <section class="meters">
    <LevelMeter label="Me" db={session.levels.meDb} />
    <LevelMeter label="Them" db={session.levels.themDb} />
  </section>

  <TranscriptPane />
</main>

<style>
  main {
    height: 100vh;
    display: flex;
    flex-direction: column;
  }

  header {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 12px 14px 8px;
    user-select: none;
    -webkit-user-select: none;
  }

  h1 {
    font-size: 16px;
    font-weight: 700;
    margin: 0;
    letter-spacing: -0.01em;
  }

  .state-badge {
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.08em;
    padding: 2px 8px;
    border-radius: 999px;
    border: 1px solid var(--border);
    color: var(--text-dim);
  }

  .state-badge.recording {
    color: #fff;
    background: var(--danger);
    border-color: var(--danger);
  }

  .state-badge.starting,
  .state-badge.stopping {
    color: var(--warn);
    border-color: var(--warn);
  }

  .state-badge.error {
    color: var(--danger);
    border-color: var(--danger);
  }

  .controls-row {
    display: flex;
    align-items: flex-start;
    gap: 12px;
    padding: 4px 14px 10px;
    user-select: none;
    -webkit-user-select: none;
  }

  .spacer {
    flex: 1;
  }

  .meters {
    display: flex;
    gap: 24px;
    padding: 0 14px 10px;
  }
</style>
