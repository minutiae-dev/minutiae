<script lang="ts">
  import { session } from "../stores/session.svelte";
</script>

<div class="vault">
  {#if session.vaultDir}
    <span class="path" title={session.vaultDir}>{session.vaultName}</span>
  {:else}
    <span class="path none">No folder chosen</span>
  {/if}
  <button class="change" onclick={() => session.pickVault()}>
    {session.vaultDir ? "Change…" : "Choose folder…"}
  </button>
</div>

<style>
  .vault {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 6px;
    padding: 0 6px;
  }

  .path {
    max-width: 100%;
    color: var(--text-dim);
    font-size: 13px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .path.none {
    color: var(--text-faint);
  }

  .change {
    font-size: 11px;
    padding: 3px 10px;
  }
</style>
