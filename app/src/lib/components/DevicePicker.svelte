<script lang="ts">
  import { session } from "../stores/session.svelte";
</script>

<div class="field">
  <div class="field-head">
    <label for="mic-select">Mic</label>
    <button
      class="refresh"
      title="Refresh devices"
      aria-label="Refresh devices"
      onclick={() => session.refreshDevices()}
      disabled={!session.canPickDevice}
    >
      &#x21bb;
    </button>
  </div>
  <select
    id="mic-select"
    bind:value={session.selectedMicUid}
    disabled={!session.canPickDevice}
  >
    {#if session.devices.length === 0}
      <option value="" disabled>No input devices</option>
    {/if}
    {#each session.devices as d (d.uid)}
      <option value={d.uid}>{d.name}{d.is_default ? " (default)" : ""}</option>
    {/each}
  </select>

  {#if session.showHeadsetHint}
    <p class="hint">
      <svg width="13" height="13" viewBox="0 0 16 16" fill="none" aria-hidden="true">
        <path
          d="M3.5 10.5v-2a4.5 4.5 0 0 1 9 0v2M3.5 9.5h1a1 1 0 0 1 1 1v2a1 1 0 0 1-1 1h-1a1 1 0 0 1-1-1v-2a1 1 0 0 1 1-1Zm8 0h1a1 1 0 0 1 1 1v2a1 1 0 0 1-1 1h-1a1 1 0 0 1-1-1v-2a1 1 0 0 1 1-1Z"
          stroke="currentColor"
          stroke-width="1.2"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
      </svg>
      <span>
        You're on <strong>{session.outputDevice?.name}</strong>. Headphones give
        the cleanest recording — on speakers your mic also picks up the other
        side, and separating the two voices is imperfect.
      </span>
    </p>
  {/if}
</div>

<style>
  .field {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .field-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 6px;
  }

  label {
    color: var(--text-dim);
    font-size: 12px;
  }

  /* Advisory, not a warning: it must not read as an error the user has to fix. */
  .hint {
    display: flex;
    align-items: flex-start;
    gap: 6px;
    margin: 2px 0 0;
    padding: 0 6px;
    font-size: 11px;
    line-height: 1.45;
    color: var(--text-faint);
  }

  .hint svg {
    flex: none;
    margin-top: 2px;
  }

  .hint strong {
    font-weight: 600;
    color: var(--text-dim);
  }

  select {
    width: 100%;
  }

  .refresh {
    border: none;
    background: transparent;
    padding: 0 4px;
    font-size: 13px;
    color: var(--text-faint);
    line-height: 1;
  }

  .refresh:hover:not(:disabled) {
    background: transparent;
    color: var(--text-dim);
  }
</style>
