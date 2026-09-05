<script lang="ts">
  import { session } from "../stores/session.svelte";
  import TranscriptPane from "./TranscriptPane.svelte";
  import EnhancePanel from "./EnhancePanel.svelte";

  const hasEnhanced = $derived(
    session.viewEnhancedText.length > 0 || session.viewEnhanceState !== "idle",
  );
</script>

<div class="tabs">
  <div class="tabbar" role="tablist">
    <button
      class="tab"
      class:active={session.activeTab === "transcript"}
      role="tab"
      aria-selected={session.activeTab === "transcript"}
      onclick={() => (session.activeTab = "transcript")}
    >
      Transcript
    </button>
    <button
      class="tab"
      class:active={session.activeTab === "enhanced"}
      role="tab"
      aria-selected={session.activeTab === "enhanced"}
      onclick={() => (session.activeTab = "enhanced")}
    >
      Enhanced
      {#if session.viewEnhancing}
        <span class="badge live" aria-label="enhancing">●</span>
      {:else if hasEnhanced}
        <span class="badge" aria-label="has enhanced note">✓</span>
      {/if}
    </button>

    {#if session.activeTab === "transcript" && session.viewedDir}
      <button
        class="reveal"
        title="Show the transcript's Markdown file in Finder"
        onclick={() => session.revealTranscript()}
      >
        <svg width="13" height="13" viewBox="0 0 16 16" fill="none" aria-hidden="true">
          <path
            d="M2 4.5A1.5 1.5 0 0 1 3.5 3h2.4a1 1 0 0 1 .8.4l.6.8h5.2A1.5 1.5 0 0 1 14 5.7v5.8A1.5 1.5 0 0 1 12.5 13h-9A1.5 1.5 0 0 1 2 11.5v-7Z"
            stroke="currentColor"
            stroke-width="1.3"
            stroke-linejoin="round"
          />
        </svg>
        Reveal
      </button>
    {/if}
  </div>

  <div class="body">
    {#if session.activeTab === "transcript"}
      <TranscriptPane />
    {:else}
      <EnhancePanel />
    {/if}
  </div>
</div>

<style>
  .tabs {
    flex: 1;
    min-width: 0;
    min-height: 0;
    display: flex;
    flex-direction: column;
  }

  .tabbar {
    display: flex;
    gap: 2px;
    padding: 4px 14px 0;
    flex: none;
  }

  .tab {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 12px;
    font-size: 12px;
    font-weight: 600;
    color: var(--text-faint);
    background: transparent;
    border: none;
    border-bottom: 2px solid transparent;
    border-radius: 0;
  }

  .tab:hover {
    color: var(--text-dim);
  }

  .tab.active {
    color: var(--text);
    border-bottom-color: var(--accent);
  }

  /* Trailing action, pushed to the far end of the tab bar. */
  .reveal {
    display: flex;
    align-items: center;
    gap: 5px;
    margin-left: auto;
    align-self: center;
    padding: 4px 9px;
    font-size: 11px;
    font-weight: 500;
    color: var(--text-faint);
    background: transparent;
    border: none;
  }

  .reveal:hover {
    color: var(--text);
  }

  .badge {
    font-size: 9px;
    color: var(--ok, #3a8);
  }

  .badge.live {
    color: var(--accent);
    animation: pulse 1.2s ease-in-out infinite;
  }

  @keyframes pulse {
    50% {
      opacity: 0.3;
    }
  }

  .body {
    flex: 1;
    min-height: 0;
    display: flex;
    flex-direction: column;
    border-top: 1px solid var(--border-soft);
  }
</style>
