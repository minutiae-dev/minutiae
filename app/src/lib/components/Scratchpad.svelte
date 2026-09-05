<script lang="ts">
  import { session } from "../stores/session.svelte";
</script>

<div class="scratchpad">
  <div class="head">
    <span class="label">Notes</span>
    {#if session.notesSaving}
      <span class="status">Saving…</span>
    {:else if session.notesSaved}
      <span class="status">Saved</span>
    {/if}
  </div>
  <textarea
    class="editor"
    placeholder={session.notesActive
      ? "Jot down notes — saved with this session, used to enhance it later."
      : "Start a session to take notes."}
    disabled={!session.notesActive}
    bind:value={session.scratchpadText}
    oninput={() => session.queueScratchpadSave()}
    onblur={() => session.flushScratchpadSave()}
  ></textarea>
</div>

<style>
  .scratchpad {
    flex: 1;
    min-width: 0;
    min-height: 0;
    display: flex;
    flex-direction: column;
    background: var(--bg);
  }

  .head {
    display: flex;
    align-items: baseline;
    gap: 8px;
    padding: 6px 22px 8px;
    user-select: none;
    -webkit-user-select: none;
  }

  .label {
    font-size: 11px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.09em;
    color: var(--text-faint);
  }

  .status {
    font-size: 10px;
    color: var(--text-faint);
  }

  .editor {
    flex: 1;
    min-height: 0;
    resize: none;
    border: none;
    outline: none;
    background: transparent;
    padding: 2px 22px 16px;
    color: var(--text);
    font-family: var(--font-sans);
    font-size: 14px;
    line-height: 1.6;
  }

  .editor::placeholder {
    color: var(--text-faint);
  }

  .editor:disabled {
    color: var(--text-faint);
  }
</style>
