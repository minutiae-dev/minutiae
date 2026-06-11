<script lang="ts">
  import { session } from "../stores/session.svelte";
  import { fmtClock } from "../time";
</script>

<div class="capture-controls">
  <div class="row">
    {#if session.phase === "recording" || session.phase === "stopping"}
      <button class="stop" onclick={() => session.stop()} disabled={!session.canStop}>
        {session.phase === "stopping" ? "Stopping…" : "Stop"}
      </button>
      <span class="elapsed" class:live={session.isRecording}>
        {fmtClock(session.elapsed)}
      </span>
    {:else}
      <button class="start" onclick={() => session.start()} disabled={!session.canStart}>
        {session.phase === "starting" ? "Starting…" : "Start"}
      </button>
    {/if}
  </div>

  {#if session.modelProgress}
    <div class="progress" role="progressbar" aria-valuenow={session.modelProgress.pct}>
      <div class="progress-track">
        <div class="progress-fill" style:width="{session.modelProgress.pct}%"></div>
      </div>
      <span class="progress-label">
        {session.modelProgress.stage === "compiling"
          ? "Compiling transcription model"
          : "Downloading transcription model"}… {Math.round(session.modelProgress.pct)}%
        <span class="once">· one-time setup</span>
      </span>
    </div>
  {:else if session.modelError}
    <div class="model-prep error">
      <span class="prep-label">Couldn’t download the transcription model. {session.modelError}</span>
      <button class="retry" onclick={() => session.retryPrepare()}>Retry</button>
    </div>
  {:else if session.preparingModels && !session.modelsReady}
    <div class="model-prep">
      <span class="spinner" aria-hidden="true"></span>
      <span class="prep-label">Preparing transcription model… <span class="once">one-time setup</span></span>
    </div>
  {/if}

  {#if session.lastError}
    <div class="error-banner" class:fatal={session.lastError.fatal}>
      <span class="error-text">
        <strong>{session.lastError.code}</strong> — {session.lastError.message}
      </span>
      <button class="dismiss" onclick={() => session.dismissError()} aria-label="Dismiss error">
        ✕
      </button>
    </div>
  {/if}
</div>

<style>
  .capture-controls {
    display: flex;
    flex-direction: column;
    gap: 6px;
    user-select: none;
    -webkit-user-select: none;
  }

  .row {
    display: flex;
    align-items: center;
    gap: 10px;
  }

  button.start {
    background: var(--accent);
    border-color: var(--accent);
    color: #fff;
    font-weight: 600;
    min-width: 88px;
  }

  button.stop {
    background: var(--danger);
    border-color: var(--danger);
    color: #fff;
    font-weight: 600;
    min-width: 88px;
  }

  .elapsed {
    font-variant-numeric: tabular-nums;
    color: var(--text-dim);
    font-size: 15px;
  }

  .elapsed.live {
    color: var(--text);
  }

  .progress {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .progress-track {
    flex: 1;
    max-width: 220px;
    height: 5px;
    border-radius: 3px;
    background: var(--bg-inset);
    border: 1px solid var(--border);
    overflow: hidden;
  }

  .progress-fill {
    height: 100%;
    background: var(--accent);
    transition: width 200ms ease;
  }

  .progress-label {
    font-size: 11px;
    color: var(--text-dim);
  }

  .once {
    opacity: 0.7;
  }

  .model-prep {
    display: flex;
    align-items: center;
    gap: 8px;
    font-size: 11px;
    color: var(--text-dim);
  }

  .model-prep.error {
    color: var(--danger);
  }

  .prep-label {
    flex: 1;
  }

  button.retry {
    font-size: 11px;
    padding: 2px 10px;
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

  .error-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 10px;
    border-radius: 6px;
    border: 1px solid var(--danger);
    background: color-mix(in srgb, var(--danger) 14%, var(--bg-raised));
    font-size: 12px;
    max-width: 480px;
  }

  .error-banner.fatal {
    background: color-mix(in srgb, var(--danger) 28%, var(--bg-raised));
  }

  .error-text {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .dismiss {
    border: none;
    background: transparent;
    padding: 0 4px;
    color: var(--text-dim);
  }
</style>
