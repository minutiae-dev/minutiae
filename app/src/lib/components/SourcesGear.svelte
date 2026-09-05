<script lang="ts">
  import { Settings } from "@lucide/svelte";
  import DevicePicker from "./DevicePicker.svelte";
  import ThemPicker from "./ThemPicker.svelte";
  import SaasMount from "../SaasMount.svelte";
  import { session } from "../stores/session.svelte";
  import type { AsrModel } from "../ipc";

  let open = $state(false);
  let root: HTMLDivElement | undefined = $state();

  function toggle() {
    open = !open;
  }

  // Close on outside click / Escape while the popover is open.
  $effect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (root && !root.contains(e.target as Node)) open = false;
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") open = false;
    };
    window.addEventListener("mousedown", onDown);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("mousedown", onDown);
      window.removeEventListener("keydown", onKey);
    };
  });
</script>

<div class="gear" bind:this={root}>
  <button
    class="trigger"
    class:on={open}
    title="Settings"
    aria-label="Settings"
    aria-expanded={open}
    onclick={toggle}
  >
    <Settings size={18} aria-hidden="true" />
  </button>

  {#if open}
    <div class="popover">
      <div class="pop-title">Audio sources</div>
      <DevicePicker />
      <ThemPicker />

      <div class="pop-title spaced">Enhancement</div>
      <label class="toggle disabled">
        <input type="checkbox" checked={false} disabled />
        <span class="toggle-text">
          <span class="toggle-title">Thinking mode</span>
          <span class="toggle-sub">Coming soon — enhancement uses instruct mode</span>
        </span>
      </label>

      <!-- Optional SaaS account + cloud sync/enrichment (gitignored module). -->
      <SaasMount />

      <!-- Hidden/advanced: on-device transcription model. Collapsed by default. -->
      <details class="advanced">
        <summary>Advanced</summary>
        <label class="field">
          <span class="field-title">Transcription model</span>
          <select
            value={session.asrModel}
            onchange={(e) =>
              session.setAsrModel(e.currentTarget.value as AsrModel)}
          >
            <option value="parakeet-tdt-v3">Parakeet TDT v3 (default)</option>
            <option value="nemotron-streaming-ml">Nemotron 3.5 (multilingual)</option>
            <option value="nemotron-streaming-en">Nemotron 3.5 (English only)</option>
          </select>
          <span class="field-sub">
            Applies to your next recording; switching may download the model once.
          </span>
        </label>
      </details>
    </div>
  {/if}
</div>

<style>
  .gear {
    position: relative;
    flex: none;
  }

  .trigger {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 32px;
    height: 32px;
    padding: 0;
    border: none;
    border-radius: 8px;
    background: transparent;
    color: var(--text-dim);
  }

  .trigger:hover,
  .trigger.on {
    background: var(--hover, rgba(127, 127, 127, 0.12));
    color: var(--text);
  }

  .popover {
    position: absolute;
    top: 38px;
    right: 0;
    z-index: 20;
    width: 240px;
    display: flex;
    flex-direction: column;
    gap: 12px;
    padding: 14px 12px;
    background: var(--sidebar, var(--bg));
    border: 1px solid var(--border);
    border-radius: 10px;
    box-shadow: 0 10px 30px rgba(0, 0, 0, 0.3);
  }

  .pop-title {
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.09em;
    color: var(--text-faint);
    padding: 0 6px;
  }

  .pop-title.spaced {
    margin-top: 4px;
    padding-top: 12px;
    border-top: 1px solid var(--border-soft);
  }

  .toggle {
    display: flex;
    align-items: flex-start;
    gap: 9px;
    padding: 0 6px;
    cursor: pointer;
  }

  .toggle.disabled {
    cursor: default;
    opacity: 0.55;
  }

  .toggle input {
    margin-top: 2px;
    flex: none;
  }

  .toggle-text {
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .toggle-title {
    font-size: 13px;
    color: var(--text);
  }

  .toggle-sub {
    font-size: 11px;
    color: var(--text-faint);
    line-height: 1.35;
  }

  .advanced {
    margin-top: 4px;
    padding-top: 12px;
    border-top: 1px solid var(--border-soft);
  }

  .advanced > summary {
    font-size: 10px;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 0.09em;
    color: var(--text-faint);
    padding: 0 6px;
    cursor: pointer;
    list-style: revert;
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 5px;
    padding: 10px 6px 0;
  }

  .field-title {
    font-size: 13px;
    color: var(--text);
  }

  .field select {
    width: 100%;
    font-size: 12px;
    padding: 4px 6px;
    border-radius: 6px;
    border: 1px solid var(--border);
    background: var(--bg);
    color: var(--text);
  }

  .field-sub {
    font-size: 11px;
    color: var(--text-faint);
    line-height: 1.35;
  }
</style>
