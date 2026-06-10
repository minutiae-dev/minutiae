<script lang="ts">
  import { session } from "../stores/session.svelte";
  import TranscriptSegment from "./TranscriptSegment.svelte";

  let pane: HTMLDivElement | undefined = $state();
  // Stay pinned to the bottom unless the user scrolls up.
  let pinned = $state(true);

  function onScroll() {
    if (!pane) return;
    pinned = pane.scrollTop + pane.clientHeight >= pane.scrollHeight - 48;
  }

  $effect(() => {
    // Track segment count and the latest text so re-emitted non-final
    // segments also keep us scrolled.
    void session.segments.length;
    void session.segments.at(-1)?.text;
    if (pinned && pane) {
      pane.scrollTop = pane.scrollHeight;
    }
  });
</script>

<div class="pane" bind:this={pane} onscroll={onScroll}>
  {#if session.segments.length === 0}
    <div class="empty">
      {#if session.isRecording}
        Listening… transcript will appear here.
      {:else}
        Pick a mic and press Start to capture a meeting.
      {/if}
    </div>
  {:else}
    {#each session.segments as seg (seg.idx)}
      <TranscriptSegment segment={seg} />
    {/each}
  {/if}
</div>

<style>
  .pane {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    padding: 10px 14px;
    background: var(--bg-inset);
    border-top: 1px solid var(--border);
  }

  .empty {
    height: 100%;
    display: flex;
    align-items: center;
    justify-content: center;
    color: var(--text-dim);
    font-size: 13px;
    user-select: none;
    -webkit-user-select: none;
  }
</style>
