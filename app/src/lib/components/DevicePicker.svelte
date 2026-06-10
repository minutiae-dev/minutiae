<script lang="ts">
  import { session } from "../stores/session.svelte";
</script>

<div class="device-picker">
  <label for="mic-select">Mic</label>
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

<style>
  .device-picker {
    display: flex;
    align-items: center;
    gap: 8px;
    user-select: none;
    -webkit-user-select: none;
  }

  label {
    color: var(--text-dim);
    font-size: 12px;
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  select {
    min-width: 200px;
    max-width: 280px;
  }

  .refresh {
    padding: 4px 9px;
  }
</style>
