<script lang="ts">
  import { renderMarkdown } from "../markdown";

  let { source = "" }: { source?: string } = $props();
  const html = $derived(renderMarkdown(source));
</script>

<!-- eslint-disable-next-line svelte/no-at-html-tags — sanitized in renderMarkdown -->
<div class="md">{@html html}</div>

<style>
  .md {
    font-family: var(--font-sans);
    font-size: 13.5px;
    line-height: 1.6;
    color: var(--text);
    word-break: break-word;
  }

  .md :global(h1),
  .md :global(h2),
  .md :global(h3) {
    font-family: var(--font-serif, var(--font-sans));
    font-weight: 600;
    line-height: 1.25;
    margin: 1.1em 0 0.45em;
    color: var(--text);
  }
  .md :global(h1:first-child),
  .md :global(h2:first-child),
  .md :global(h3:first-child) {
    margin-top: 0;
  }
  .md :global(h1) {
    font-size: 1.5em;
  }
  .md :global(h2) {
    font-size: 1.22em;
  }
  .md :global(h3) {
    font-size: 1.06em;
  }

  .md :global(p) {
    margin: 0 0 0.7em;
  }

  .md :global(ul),
  .md :global(ol) {
    margin: 0 0 0.7em;
    padding-left: 1.35em;
  }
  .md :global(li) {
    margin: 0.18em 0;
  }
  .md :global(li::marker) {
    color: var(--text-faint);
  }

  .md :global(strong) {
    font-weight: 650;
    color: var(--text);
  }
  .md :global(em) {
    font-style: italic;
  }

  .md :global(a) {
    color: var(--accent);
    text-decoration: none;
  }
  .md :global(a:hover) {
    text-decoration: underline;
  }

  .md :global(code) {
    font-family: var(--font-mono, ui-monospace, monospace);
    font-size: 0.9em;
    background: var(--hover, rgba(127, 127, 127, 0.14));
    padding: 0.1em 0.35em;
    border-radius: 4px;
  }
  .md :global(pre) {
    background: var(--hover, rgba(127, 127, 127, 0.12));
    padding: 10px 12px;
    border-radius: 8px;
    overflow-x: auto;
    margin: 0 0 0.7em;
  }
  .md :global(pre code) {
    background: none;
    padding: 0;
  }

  .md :global(blockquote) {
    margin: 0 0 0.7em;
    padding-left: 12px;
    border-left: 2px solid var(--border);
    color: var(--text-dim);
  }

  .md :global(hr) {
    border: none;
    border-top: 1px solid var(--border-soft);
    margin: 1em 0;
  }

  .md :global(table) {
    border-collapse: collapse;
    margin: 0 0 0.7em;
    font-size: 0.95em;
  }
  .md :global(th),
  .md :global(td) {
    border: 1px solid var(--border-soft);
    padding: 4px 8px;
    text-align: left;
  }
</style>
