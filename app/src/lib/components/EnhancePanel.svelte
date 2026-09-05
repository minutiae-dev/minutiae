<script lang="ts">
  import { Check, CircleCheck, Download, Sparkles } from "@lucide/svelte";
  import { session } from "../stores/session.svelte";
  import Markdown from "./Markdown.svelte";
  import Soundwave from "./Soundwave.svelte";

  // Why the Enhance button is disabled, for a helpful hint.
  const hint = $derived(
    !session.vaultDir
      ? "Choose a vault folder in the sidebar first."
      : !session.notesActive
        ? "Start and finish a session to enhance it."
        : session.enhancing && !session.viewEnhancing
          ? "An enhancement is running on another meeting."
          : "",
  );

  const pct = $derived(
    session.viewEnhanceProgress
      ? Math.round(session.viewEnhanceProgress.pct)
      : 0,
  );
  const stageLabel = $derived(
    session.viewEnhanceProgress?.stage === "downloading"
      ? "Downloading model"
      : "Loading model",
  );

  // Model download/load (on-demand) progress.
  const prepPct = $derived(
    session.llmPrepProgress ? Math.round(session.llmPrepProgress.pct) : 0,
  );
  const prepStageLabel = $derived(
    session.llmPrepProgress?.stage === "downloading"
      ? "Downloading model"
      : "Loading model",
  );
</script>

<div class="enhance">
  {#if !session.llmDownloaded && !session.llmCloudActive}
    <!-- Model not on disk: explicit, one-time download (never auto-started).
         Cloud enrichment (SaaS) needs no local model, so it skips this card. -->
    <div class="model-card">
      <span class="label">Enhancement model</span>
      {#if session.llmPreparing}
        <div class="progress">
          <span class="stage">{prepStageLabel}…</span>
          <div class="track">
            <div class="fill" style="width: {prepPct}%"></div>
          </div>
          <span class="pct">{prepPct}%</span>
        </div>
        <p class="model-desc faint">One-time setup — keep the app open.</p>
      {:else}
        <p class="model-desc">
          Enhancing runs a local model (Qwen3.5-4B, ~2.9&nbsp;GB) on your Mac —
          nothing leaves your device. Download it once to turn transcripts into
          notes.
        </p>
        <button class="go" onclick={() => session.prepareLlm()}>
          <Download size={14} aria-hidden="true" /> Download model
        </button>
        {#if session.llmPrepError}
          <p class="error">{session.llmPrepError}</p>
        {/if}
      {/if}
    </div>
  {:else}
    <div class="bar">
      {#if session.viewEnhancing}
        <button class="interrupt" onclick={() => session.cancelEnhance()}>
          Interrupt
        </button>
      {:else}
        <button
          class="go"
          disabled={!session.canEnhance}
          title={hint}
          onclick={() => session.enhance()}
        >
          <Sparkles size={14} aria-hidden="true" />
          {session.viewEnhanceState === "error" ||
          session.viewEnhanceState === "done"
            ? "Enhance again"
            : "Enhance notes"}
        </button>
      {/if}

      {#if session.thinkingMode && !session.viewEnhancing}
        <span class="mode" title="Thinking mode is on (change it in ⚙)">Thinking</span>
      {/if}
      {#if !session.viewEnhancing && hint}
        <span class="hint">{hint}</span>
      {/if}

      <span class="spacer"></span>

      {#if !session.viewEnhancing && session.viewEnhanceState === "idle"}
        {#if session.llmCloudActive}
          <span class="ready" title="Enhancement runs in the cloud">
            <CircleCheck size={12} aria-hidden="true" />
            Cloud enrichment
          </span>
        {:else}
          <span class="ready" title="The enhancement model is on your Mac">
            <CircleCheck size={12} aria-hidden="true" />
            {session.llmReady ? "Model ready" : "Model downloaded"}
          </span>
        {/if}
      {/if}
      {#if session.viewEnhanceState === "done" && session.viewEnhancedFile}
        <span class="saved" title={"Saved " + session.viewEnhancedFile}>
          <Check size={13} aria-hidden="true" /> Saved
        </span>
      {/if}
    </div>

    {#if session.viewEnhancing && session.viewEnhanceProgress}
      <div class="progress">
        <span class="stage">{stageLabel}…</span>
        <div class="track"><div class="fill" style="width: {pct}%"></div></div>
        <span class="pct">{pct}%</span>
      </div>
    {/if}

    {#if session.viewEnhanceState === "error"}
      <p class="error">{session.viewEnhanceError}</p>
    {:else}
      {#if session.viewThinkingText}
        <details class="thoughts">
          <summary>{session.viewIsThinking ? "Thinking…" : "Show thinking"}</summary>
          <div class="thoughts-body">{session.viewThinkingText}</div>
        </details>
      {/if}

      {#if session.viewIsThinking}
        <Soundwave label="Thinking…" />
      {:else if session.viewEnhancing && !session.viewEnhanceProgress && !session.viewEnhancedText}
        <Soundwave label="Generating…" />
      {/if}

      {#if session.viewEnhancedText}
        <div class="output" class:streaming={session.viewEnhancing}>
          <Markdown source={session.viewEnhancedText} />
        </div>
      {/if}
    {/if}
  {/if}
</div>

<style>
  .enhance {
    flex: 1;
    display: flex;
    flex-direction: column;
    background: var(--bg);
    min-height: 0;
  }

  .bar {
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 10px 22px;
    user-select: none;
    -webkit-user-select: none;
  }

  .spacer {
    flex: 1;
  }

  .model-card {
    display: flex;
    flex-direction: column;
    align-items: flex-start;
    gap: 10px;
    padding: 14px 22px 16px;
  }

  .model-desc {
    margin: 0;
    font-size: 12.5px;
    line-height: 1.5;
    color: var(--text-dim);
    max-width: 52ch;
  }

  .model-desc.faint {
    color: var(--text-faint);
    font-size: 11px;
  }

  .model-card .progress {
    align-self: stretch;
  }

  .ready {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-size: 11px;
    color: var(--text-faint);
    white-space: nowrap;
    flex: none;
  }

  .mode {
    font-size: 10px;
    font-weight: 600;
    letter-spacing: 0.04em;
    color: var(--accent);
    border: 1px solid var(--accent);
    border-radius: 999px;
    padding: 1px 7px;
    flex: none;
  }

  .go {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    white-space: nowrap;
    flex: none;
    font-size: 12.5px;
    font-weight: 600;
    padding: 5px 14px;
    color: #fff;
    background: var(--accent);
    border: 1px solid var(--accent);
    border-radius: 8px;
  }

  .go:hover:not(:disabled) {
    filter: brightness(1.08);
  }

  .go:disabled {
    color: var(--text-faint);
    background: transparent;
    border-color: var(--border);
  }

  .interrupt {
    font-size: 12px;
    padding: 5px 12px;
    border-radius: 8px;
    white-space: nowrap;
    flex: none;
  }

  .hint {
    font-size: 11px;
    color: var(--text-faint);
  }

  .saved {
    display: inline-flex;
    align-items: center;
    gap: 4px;
    font-size: 11px;
    color: var(--ok, #3a8);
    white-space: nowrap;
    flex: none;
  }

  .progress {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 0 22px 8px;
  }

  .stage {
    font-size: 11px;
    color: var(--text-dim);
    flex: none;
  }

  .track {
    flex: 1;
    height: 4px;
    border-radius: 2px;
    background: var(--border-soft);
    overflow: hidden;
  }

  .fill {
    height: 100%;
    background: var(--accent);
    transition: width 0.2s ease;
  }

  .pct {
    font-size: 11px;
    color: var(--text-faint);
    flex: none;
    width: 34px;
    text-align: right;
  }

  .output {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    padding: 0 22px 16px;
    margin: 0;
  }

  .thoughts {
    margin: 0 22px 8px;
    font-size: 12px;
    color: var(--text-dim);
  }

  .thoughts summary {
    cursor: pointer;
    color: var(--text-faint);
    font-weight: 600;
    list-style: none;
    padding: 4px 0;
  }

  .thoughts summary::-webkit-details-marker {
    display: none;
  }

  .thoughts summary::before {
    content: "▸ ";
    color: var(--text-faint);
  }

  .thoughts[open] summary::before {
    content: "▾ ";
  }

  .thoughts-body {
    padding: 4px 0 6px;
    border-left: 2px solid var(--border-soft);
    padding-left: 12px;
    margin-bottom: 4px;
    color: var(--text-dim);
    white-space: pre-wrap;
    word-break: break-word;
    max-height: 220px;
    overflow-y: auto;
  }

  .error {
    padding: 0 22px 14px;
    margin: 0;
    font-size: 13px;
    color: var(--danger);
  }
</style>
