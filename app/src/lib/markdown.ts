// Markdown → sanitized HTML for rendering enhanced notes.
// The content is local-model output (and may quote the transcript), so we still
// sanitize before injecting with {@html}.

import DOMPurify from "dompurify";
import { marked } from "marked";

marked.setOptions({ gfm: true, breaks: true });

export function renderMarkdown(src: string): string {
  if (!src) return "";
  const html = marked.parse(src, { async: false }) as string;
  return DOMPurify.sanitize(html);
}
