<script lang="ts">
  import { Plus } from "@lucide/svelte";
  import { session } from "../stores/session.svelte";
  import RecentsList from "./RecentsList.svelte";
  import VaultBar from "./VaultBar.svelte";
  import SaasMount from "../SaasMount.svelte";

  const locked = $derived(
    session.phase === "recording" ||
      session.phase === "starting" ||
      session.phase === "stopping",
  );
</script>

<aside class="sidebar" data-tauri-drag-region>
  <div class="brand">
    <svg class="mark" width="15" height="15" viewBox="0 0 16 16" aria-hidden="true">
      <rect x="1" y="6" width="2" height="4" rx="1" />
      <rect x="5" y="2.5" width="2" height="11" rx="1" />
      <rect x="9" y="4.5" width="2" height="7" rx="1" />
      <rect x="13" y="6.5" width="2" height="3" rx="1" />
    </svg>
    <span class="name">Minutiae</span>
  </div>

  <button
    class="new"
    disabled={locked || session.selectedSessionId === null}
    onclick={() => session.newMeeting()}
  >
    <Plus size={15} aria-hidden="true" /> New meeting
  </button>

  <div class="section recents-section">
    <div class="section-label">Recents</div>
    <RecentsList />
  </div>

  <div class="section vault-section">
    <div class="section-label">Vault</div>
    <VaultBar />
  </div>

  <!-- Optional account widget (gitignored; SaaS builds only). -->
  <SaasMount name="SidebarAccount" />
</aside>

<style>
  .sidebar {
    flex: none;
    width: 244px;
    display: flex;
    flex-direction: column;
    gap: 14px;
    background: var(--sidebar);
    border-right: 1px solid var(--border-soft);
    /* Top pad clears the macOS traffic lights under the overlay title bar. */
    padding: 38px 10px 14px;
    overflow: hidden;
  }

  .brand {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0 6px;
    user-select: none;
    -webkit-user-select: none;
  }

  .new {
    display: flex;
    align-items: center;
    gap: 8px;
    width: 100%;
    padding: 7px 10px;
    font-size: 13px;
    font-weight: 500;
    color: var(--text);
    background: transparent;
    border: 1px solid var(--border);
    border-radius: 8px;
  }

  .new:hover:not(:disabled) {
    background: var(--hover, rgba(127, 127, 127, 0.1));
  }

  .new:disabled {
    color: var(--text-faint);
    border-color: var(--border-soft);
  }

  .mark {
    flex: none;
    fill: var(--accent);
  }

  .name {
    font-family: var(--font-serif);
    font-size: 19px;
    font-weight: 500;
    color: var(--text);
  }

  .section {
    display: flex;
    flex-direction: column;
    gap: 8px;
    min-height: 0;
  }

  /* Recents takes the slack and scrolls; Vault stays pinned at the bottom. */
  .recents-section {
    flex: 1;
    min-height: 0;
  }

  .vault-section {
    flex: none;
    border-top: 1px solid var(--border-soft);
    padding-top: 12px;
  }

  .section-label {
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.09em;
    color: var(--text-faint);
    padding: 0 6px;
    user-select: none;
    -webkit-user-select: none;
  }
</style>
