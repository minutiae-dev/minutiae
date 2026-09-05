<script lang="ts">
  import { Trash2 } from "@lucide/svelte";
  import { confirm } from "@tauri-apps/plugin-dialog";
  import { session } from "../stores/session.svelte";
  import { fmtWhen } from "../time";
  import type { SessionSummary } from "../ipc";

  // Can't switch sessions mid-capture (enhancement keeps running in the
  // background, scoped to its own meeting, so switching during it is fine).
  const locked = $derived(
    session.phase === "recording" ||
      session.phase === "starting" ||
      session.phase === "stopping",
  );

  async function confirmDelete(e: MouseEvent, s: SessionSummary) {
    // Don't let the click fall through to opening the row.
    e.stopPropagation();
    const ok = await confirm(
      `Delete "${s.title}"? This removes the recording, transcript, notes, and its enhanced note. This can't be undone.`,
      { title: "Delete meeting", kind: "warning", okLabel: "Delete" },
    );
    if (ok) await session.deleteSession(s);
  }
</script>

<div class="recents">
  {#if session.sessions.length === 0}
    <p class="empty">No meetings yet. Press Record to start one.</p>
  {:else}
    {#each session.sessions as s (s.session_id)}
      <div class="row-wrap">
        <button
          class="row"
          class:active={s.session_id === session.selectedSessionId}
          disabled={locked && s.session_id !== session.selectedSessionId}
          title={locked ? "Stop the recording to open another meeting" : s.title}
          onclick={() => session.openPastSession(s)}
        >
          <span class="title">{s.title}</span>
          <span class="meta">
            <span class="when">{fmtWhen(s.started_at)}</span>
            {#if s.has_enhanced}
              <span class="dot" title="Has an enhanced note">✓</span>
            {/if}
          </span>
        </button>
        {#if !locked}
          <button
            class="delete"
            title="Delete meeting"
            aria-label="Delete meeting"
            onclick={(e) => confirmDelete(e, s)}
          >
            <Trash2 size={14} aria-hidden="true" />
          </button>
        {/if}
      </div>
    {/each}
  {/if}
</div>

<style>
  .recents {
    display: flex;
    flex-direction: column;
    gap: 1px;
    overflow-y: auto;
    min-height: 0;
    flex: 1;
  }

  .empty {
    margin: 0;
    padding: 4px 8px;
    font-size: 12px;
    color: var(--text-faint);
    line-height: 1.5;
  }

  .row-wrap {
    position: relative;
  }

  .row {
    display: flex;
    flex-direction: column;
    align-items: stretch;
    gap: 2px;
    width: 100%;
    text-align: left;
    /* Right pad leaves room for the hover delete button. */
    padding: 7px 30px 7px 8px;
    border: none;
    border-radius: 7px;
    background: transparent;
    color: var(--text-dim);
    cursor: pointer;
  }

  .row:hover:not(:disabled) {
    background: var(--hover, rgba(127, 127, 127, 0.1));
  }

  .row.active {
    background: var(--active, rgba(127, 127, 127, 0.16));
    color: var(--text);
  }

  .row:disabled {
    opacity: 0.45;
    cursor: default;
  }

  .title {
    font-size: 13px;
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .meta {
    display: flex;
    align-items: center;
    gap: 6px;
    font-size: 11px;
    color: var(--text-faint);
  }

  .when {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .dot {
    margin-left: auto;
    color: var(--ok, #3a8);
    font-size: 10px;
  }

  /* Hover-revealed delete, pinned to the row's right edge. */
  .delete {
    position: absolute;
    top: 50%;
    right: 6px;
    transform: translateY(-50%);
    display: flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    padding: 0;
    border: none;
    border-radius: 6px;
    background: transparent;
    color: var(--text-faint);
    cursor: pointer;
    opacity: 0;
    transition: opacity 0.12s ease;
  }

  .row-wrap:hover .delete,
  .delete:focus-visible {
    opacity: 1;
  }

  .delete:hover {
    background: var(--hover, rgba(127, 127, 127, 0.12));
    color: var(--danger, #e5534b);
  }
</style>
