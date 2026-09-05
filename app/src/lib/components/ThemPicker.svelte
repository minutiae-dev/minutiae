<script lang="ts">
  import { session } from "../stores/session.svelte";
</script>

<div class="field">
  <label for="them-select">Them</label>
  <select
    id="them-select"
    bind:value={session.selectedThemSource}
    disabled={!session.canPickDevice}
  >
    <option value="system">System audio</option>
    {#if session.devices.length > 0}
      <optgroup label="Audio devices">
        {#each session.devices as d (d.uid)}
          <option value={d.uid}>{d.name}</option>
        {/each}
      </optgroup>
    {/if}
  </select>
</div>

<style>
  .field {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  label {
    color: var(--text-dim);
    font-size: 12px;
    padding: 0 6px;
  }

  select {
    width: 100%;
  }
</style>
