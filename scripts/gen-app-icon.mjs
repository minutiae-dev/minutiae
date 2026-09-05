// Generates a 1024×1024 app-icon PNG from Minutiae's in-app sound-wave mark
// (the 4-bar glyph in Sidebar.svelte). Dependency-free: draws into an RGBA
// buffer with 3× supersampling for clean rounded corners and encodes a PNG
// using Node's built-in zlib. Feed the output to `tauri icon`.
//
//   node scripts/gen-app-icon.mjs app/src-tauri/icons/app-icon.png

import { deflateSync } from "node:zlib";
import { writeFileSync } from "node:fs";

const OUT = process.argv[2] ?? "app/src-tauri/icons/app-icon.png";
const SIZE = 1024;
const SS = 3; // supersample factor (anti-aliasing)

// --- palette (from app/src/styles.css) -------------------------------------
const ACCENT = [0x7c, 0x7f, 0xe0]; // bars
const TILE_TOP = [0x2c, 0x2a, 0x28]; // tile gradient (light → dark, top→bottom)
const TILE_BOT = [0x16, 0x15, 0x13];

// --- geometry --------------------------------------------------------------
// Rounded background tile, inset from the canvas edge.
const TILE_INSET = 64;
const TILE = {
  x: TILE_INSET,
  y: TILE_INSET,
  w: SIZE - TILE_INSET * 2,
  h: SIZE - TILE_INSET * 2,
  r: 200, // ≈ macOS squircle proportion
};
// The glyph lives in a padded content box, mapping the mark's 16×16 viewBox.
const PAD = 200;
const BOX = TILE.x + PAD; // content box origin (square, centered)
const SPAN = TILE.w - PAD * 2;
const U = SPAN / 16; // px per viewBox unit
const fx = (u) => BOX + u * U;
const fy = (v) => BOX + v * U;

// Bars from Sidebar.svelte: <rect x y width height rx="1" />
const BARS = [
  { x: 1, y: 6, w: 2, h: 4 },
  { x: 5, y: 2.5, w: 2, h: 11 },
  { x: 9, y: 4.5, w: 2, h: 7 },
  { x: 13, y: 6.5, w: 2, h: 3 },
].map((b) => ({
  x: fx(b.x),
  y: fy(b.y),
  w: b.w * U,
  h: b.h * U,
  r: 1 * U,
}));

// Inside-rounded-rect test (signed-distance style).
function inRoundRect(px, py, { x, y, w, h, r }) {
  if (px < x || px > x + w || py < y || py > y + h) return false;
  const dx = Math.max(x + r - px, px - (x + w - r), 0);
  const dy = Math.max(y + r - py, py - (y + h - r), 0);
  return dx * dx + dy * dy <= r * r;
}

// Colour at a continuous point: bars over gradient tile over transparency.
function sample(px, py) {
  for (const bar of BARS) {
    if (inRoundRect(px, py, bar)) return [ACCENT[0], ACCENT[1], ACCENT[2], 255];
  }
  if (inRoundRect(px, py, TILE)) {
    const t = Math.min(1, Math.max(0, (py - TILE.y) / TILE.h));
    return [
      Math.round(TILE_TOP[0] + (TILE_BOT[0] - TILE_TOP[0]) * t),
      Math.round(TILE_TOP[1] + (TILE_BOT[1] - TILE_TOP[1]) * t),
      Math.round(TILE_TOP[2] + (TILE_BOT[2] - TILE_TOP[2]) * t),
      255,
    ];
  }
  return [0, 0, 0, 0];
}

// --- rasterize with supersampling ------------------------------------------
const raw = Buffer.alloc(SIZE * (SIZE * 4 + 1)); // +1 filter byte per row
const n = SS * SS;
for (let y = 0; y < SIZE; y++) {
  const rowStart = y * (SIZE * 4 + 1);
  raw[rowStart] = 0; // filter: none
  for (let x = 0; x < SIZE; x++) {
    let r = 0, g = 0, b = 0, a = 0;
    for (let sy = 0; sy < SS; sy++) {
      for (let sx = 0; sx < SS; sx++) {
        const px = x + (sx + 0.5) / SS;
        const py = y + (sy + 0.5) / SS;
        const c = sample(px, py);
        // premultiply so transparent edges blend cleanly, then un-premultiply.
        const af = c[3] / 255;
        r += c[0] * af;
        g += c[1] * af;
        b += c[2] * af;
        a += c[3];
      }
    }
    const aAvg = a / n;
    const off = rowStart + 1 + x * 4;
    if (aAvg > 0) {
      const inv = n / a; // = 1 / (sum(af))*... → recover straight colour
      raw[off] = Math.round((r / n) * (255 / aAvg));
      raw[off + 1] = Math.round((g / n) * (255 / aAvg));
      raw[off + 2] = Math.round((b / n) * (255 / aAvg));
    }
    raw[off + 3] = Math.round(aAvg);
  }
}

// --- PNG encode (RGBA, 8-bit) ----------------------------------------------
const crcTable = (() => {
  const t = new Int32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c;
  }
  return t;
})();
function crc32(buf) {
  let c = ~0;
  for (let i = 0; i < buf.length; i++) c = crcTable[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return ~c >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length, 0);
  const typeBuf = Buffer.from(type, "ascii");
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([typeBuf, data])), 0);
  return Buffer.concat([len, typeBuf, data, crc]);
}
const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(SIZE, 0);
ihdr.writeUInt32BE(SIZE, 4);
ihdr[8] = 8; // bit depth
ihdr[9] = 6; // colour type RGBA
const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk("IHDR", ihdr),
  chunk("IDAT", deflateSync(raw, { level: 9 })),
  chunk("IEND", Buffer.alloc(0)),
]);
writeFileSync(OUT, png);
console.log(`wrote ${OUT} (${png.length} bytes, ${SIZE}×${SIZE})`);
