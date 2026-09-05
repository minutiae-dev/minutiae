<script lang="ts">
  import { session } from "../stores/session.svelte";
  import { fmtClock } from "../time";
</script>

<div class="capture">
  <div class="row">
    {#if session.phase === "recording" || session.phase === "stopping"}
      <button class="rec stop" onclick={() => session.stop()} disabled={!session.canStop}>
        <span class="dot stop-dot"></span>
        {session.phase === "stopping" ? "Stopping…" : "Stop"}
      </button>
      <span class="elapsed" class:live={session.isRecording}>
        {fmtClock(session.elapsed)}
      </span>
    {:else}
      <button class="rec start" onclick={() => session.start()} disabled={!session.canStart}>
        <span class="dot"></span>
        {session.phase === "starting" ? "Starting…" : "Record"}
      </button>
    {/if}
  </div>

  {#if session.modelProgress}
    <div class="status">
      <span class="spinner" aria-hidden="true"></span>
      <span class="status-text">
        {session.modelProgress.stage === "compiling" ? "Compiling" : "Downloading"} transcription
        model… {Math.round(session.modelProgress.pct)}% <span class="faint">· one-time</span>
      </span>
    </div>
  {:else if session.modelError}
    <div class="status error">
      <span class="status-text">Couldn’t download the model. {session.modelError}</span>
      <button class="retry" onclick={() => session.retryPrepare()}>Retry</button>
    </div>
  {:else if session.preparingModels && !session.modelsReady}
    <div class="status">
      <span class="spinner" aria-hidden="true"></span>
      <span class="status-text">Preparing transcription model… <span class="faint">one-time setup</span></span>
    </div>
  {/if}

  {#if session.lastError}
    <div class="status error">
      <span class="status-text">
        <strong>{session.lastError.code}</strong> — {session.lastError.message}
      </span>
      <button class="dismiss" onclick={() => session.dismissError()} aria-label="Dismiss error">✕</button>
    </div>
  {/if}
</div>

<style>
  .capture {
    display: flex;
    flex-direction: column;
    gap: 7px;
    user-select: none;
    -webkit-user-select: none;
  }

  .row {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  /* The one focal control: a soft, rounded, slightly raised pill. */
  button.rec {
    display: inline-flex;
    align-items: center;
    gap: 8px;
    font-weight: 600;
    font-size: 14px;
    padding: 8px 18px;
    border-radius: 999px;
    min-width: 116px;
  }

  button.start {
    background: var(--accent);
    border-color: var(--accent);
    color: #fff;
  }

  button.start:hover:not(:disabled) {
    background: var(--accent-soft);
    border-color: var(--accent-soft);
  }

  button.stop {
    background: var(--danger);
    border-color: var(--danger);
    color: #fff;
  }

  .dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    background: #fff;
    flex: none;
  }

  .stop-dot {
    border-radius: 2px;
    animation: pulse 1.4s ease-in-out infinite;
  }

  @keyframes pulse {
    50% {
      opacity: 0.35;
    }
  }

  .elapsed {
    font-variant-numeric: tabular-nums;
    color: var(--text-dim);
    font-size: 17px;
    letter-spacing: 0.01em;
  }

  .elapsed.live {
    color: var(--text);
  }

  .status {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 11px;
    color: var(--text-dim);
    max-width: 520px;
  }

  .status.error {
    color: var(--danger);
  }

  .status-text {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .faint {
    opacity: 0.7;
  }

  button.retry {
    font-size: 11px;
    padding: 2px 10px;
  }

  .dismiss {
    border: none;
    background: transparent;
    padding: 0 4px;
    color: var(--text-dim);
  }

  .spinner {
    width: 11px;
    height: 11px;
    border: 2px solid var(--border);
    border-top-color: var(--accent);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
    flex: none;
  }

  @keyframes spin {
    to {
      transform: rotate(360deg);
    }
  }
</style>
