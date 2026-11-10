// OrunDocs exam scanner core. Independent implementation; runs entirely on the device.
// All functions take/return RGBA "image" objects: {width, height, data: Uint8ClampedArray}.
// Pipeline: detectDocument -> warpPerspective -> normalizeIllumination -> removeHandwriting -> finishOutput.

export const MAX_SIDE = 2400;
const clamp = (v, lo, hi) => (v < lo ? lo : v > hi ? hi : v);

export function makeImage(width, height, fill = 255) {
  const data = new Uint8ClampedArray(width * height * 4);
  data.fill(fill);
  return { width, height, data };
}

export function cloneImage(img) {
  return { width: img.width, height: img.height, data: new Uint8ClampedArray(img.data) };
}

/** Area-average downscale so that the long side is at most `maxSide`. */
export function downscale(img, maxSide) {
  const scale = Math.min(1, maxSide / Math.max(img.width, img.height));
  if (scale >= 1) return { image: img, scale: 1 };
  const w = Math.max(1, Math.round(img.width * scale)), h = Math.max(1, Math.round(img.height * scale));
  const out = makeImage(w, h, 0), src = img.data, dst = out.data;
  const fx = img.width / w, fy = img.height / h;
  for (let y = 0; y < h; y++) {
    const y0 = Math.floor(y * fy), y1 = Math.max(y0 + 1, Math.floor((y + 1) * fy));
    for (let x = 0; x < w; x++) {
      const x0 = Math.floor(x * fx), x1 = Math.max(x0 + 1, Math.floor((x + 1) * fx));
      let r = 0, g = 0, b = 0, n = 0;
      for (let yy = y0; yy < y1 && yy < img.height; yy++) {
        let i = (yy * img.width + x0) * 4;
        for (let xx = x0; xx < x1 && xx < img.width; xx++, i += 4) { r += src[i]; g += src[i + 1]; b += src[i + 2]; n++; }
      }
      const o = (y * w + x) * 4;
      dst[o] = r / n; dst[o + 1] = g / n; dst[o + 2] = b / n; dst[o + 3] = 255;
    }
  }
  return { image: out, scale: w / img.width };
}

function otsu(values, count) {
  const hist = new Float64Array(256);
  for (let i = 0; i < count; i++) hist[values[i]]++;
  let sum = 0;
  for (let t = 0; t < 256; t++) sum += t * hist[t];
  let wB = 0, sumB = 0, best = -1, thr = 127;
  for (let t = 0; t < 256; t++) {
    wB += hist[t]; if (!wB) continue;
    const wF = count - wB; if (!wF) break;
    sumB += t * hist[t];
    const d = sumB / wB - (sum - sumB) / wF, v = wB * wF * d * d;
    if (v > best) { best = v; thr = t; }
  }
  return thr;
}

function morph(mask, w, h, r, dilate) {
  // Separable square min/max filter on a 0/1 mask.
  const tmp = new Uint8Array(mask.length), out = new Uint8Array(mask.length);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let v = dilate ? 0 : 1;
    for (let k = -r; k <= r; k++) { const xx = x + k; if (xx < 0 || xx >= w) { if (!dilate) { v = 0; break; } continue; } const m = mask[y * w + xx]; if (dilate ? m : !m) { v = dilate ? 1 : 0; break; } }
    tmp[y * w + x] = v;
  }
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    let v = dilate ? 0 : 1;
    for (let k = -r; k <= r; k++) { const yy = y + k; if (yy < 0 || yy >= h) { if (!dilate) { v = 0; break; } continue; } const m = tmp[yy * w + x]; if (dilate ? m : !m) { v = dilate ? 1 : 0; break; } }
    out[y * w + x] = v;
  }
  return out;
}

function largestComponent(mask, w, h) {
  const label = new Int32Array(mask.length), stack = new Int32Array(mask.length);
  let best = -1, bestSize = 0, next = 1;
  for (let s = 0; s < mask.length; s++) {
    if (!mask[s] || label[s]) continue;
    let top = 0, size = 0; stack[top++] = s; label[s] = next;
    while (top) {
      const p = stack[--top]; size++;
      const x = p % w, y = (p - x) / w;
      if (x > 0 && mask[p - 1] && !label[p - 1]) { label[p - 1] = next; stack[top++] = p - 1; }
      if (x < w - 1 && mask[p + 1] && !label[p + 1]) { label[p + 1] = next; stack[top++] = p + 1; }
      if (y > 0 && mask[p - w] && !label[p - w]) { label[p - w] = next; stack[top++] = p - w; }
      if (y < h - 1 && mask[p + w] && !label[p + w]) { label[p + w] = next; stack[top++] = p + w; }
    }
    if (size > bestSize) { bestSize = size; best = next; }
    next++;
  }
  const out = new Uint8Array(mask.length);
  if (best > 0) for (let i = 0; i < mask.length; i++) out[i] = label[i] === best ? 1 : 0;
  return { mask: out, size: bestSize };
}

function cross(o, a, b) { return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]); }

function convexHull(points) {
  const p = points.slice().sort((a, b) => a[0] - b[0] || a[1] - b[1]);
  if (p.length < 3) return p;
  const lower = [], upper = [];
  for (const q of p) { while (lower.length >= 2 && cross(lower[lower.length - 2], lower[lower.length - 1], q) <= 0) lower.pop(); lower.push(q); }
  for (let i = p.length - 1; i >= 0; i--) { const q = p[i]; while (upper.length >= 2 && cross(upper[upper.length - 2], upper[upper.length - 1], q) <= 0) upper.pop(); upper.push(q); }
  upper.pop(); lower.pop();
  return lower.concat(upper);
}

function polygonArea(pts) {
  let a = 0;
  for (let i = 0; i < pts.length; i++) { const p = pts[i], q = pts[(i + 1) % pts.length]; a += p[0] * q[1] - q[0] * p[1]; }
  return Math.abs(a) / 2;
}

/** Order four points as top-left, top-right, bottom-right, bottom-left. */
export function orderCorners(pts) {
  const c = pts.reduce((s, p) => [s[0] + p[0] / 4, s[1] + p[1] / 4], [0, 0]);
  const sorted = pts.slice().sort((a, b) => Math.atan2(a[1] - c[1], a[0] - c[0]) - Math.atan2(b[1] - c[1], b[0] - c[0]));
  // atan2 order starts near -pi (left); rotate so that the point with min x+y is first.
  let start = 0;
  for (let i = 1; i < 4; i++) if (sorted[i][0] + sorted[i][1] < sorted[start][0] + sorted[start][1]) start = i;
  const r = [0, 1, 2, 3].map(i => sorted[(start + i) % 4]);
  // Ensure clockwise in screen coordinates (y down): TL -> TR -> BR -> BL.
  if (cross(r[0], r[1], r[2]) < 0) return [r[0], r[3], r[2], r[1]];
  return r;
}

function maxAreaQuad(hull) {
  // Reduce candidate count, then exhaustive search over hull-ordered 4-tuples.
  let pts = hull;
  if (pts.length > 24) { const step = pts.length / 24; pts = Array.from({ length: 24 }, (_, i) => pts[Math.floor(i * step)]); }
  const n = pts.length; let best = null, bestArea = -1;
  if (n < 4) return null;
  for (let a = 0; a < n; a++) for (let b = a + 1; b < n; b++) for (let c = b + 1; c < n; c++) for (let d = c + 1; d < n; d++) {
    const q = [pts[a], pts[b], pts[c], pts[d]], ar = polygonArea(q);
    if (ar > bestArea) { bestArea = ar; best = q; }
  }
  return best;
}

/**
 * Find the paper sheet in a photo. Returns corners in source pixel coordinates, ordered TL,TR,BR,BL,
 * plus a confidence 0..1. Falls back to the full frame when no sheet stands out from the background.
 */
export function detectDocument(img) {
  const full = [[0, 0], [img.width - 1, 0], [img.width - 1, img.height - 1], [0, img.height - 1]];
  const { image: small, scale } = downscale(img, 360);
  const w = small.width, h = small.height, n = w * h, d = small.data;
  const value = new Uint8Array(n), sat = new Float32Array(n);
  for (let i = 0, p = 0; p < n; p++, i += 4) {
    const mx = Math.max(d[i], d[i + 1], d[i + 2]), mn = Math.min(d[i], d[i + 1], d[i + 2]);
    value[p] = mx; sat[p] = mx ? (mx - mn) / mx : 0;
  }
  const thr = otsu(value, n);
  let mask = new Uint8Array(n);
  // Paper stays low-saturation even in shadow; desks/backgrounds are usually more saturated or much darker.
  const minValue = Math.min(thr, 110) * 0.5;
  for (let p = 0; p < n; p++) mask[p] = value[p] > minValue && sat[p] < 0.36 ? 1 : 0;
  mask = morph(morph(mask, w, h, 2, true), w, h, 2, false); // close text holes
  mask = morph(morph(mask, w, h, 1, false), w, h, 1, true); // open thin bridges
  const comp = largestComponent(mask, w, h);
  const coverage = comp.size / n;
  if (coverage < 0.12) return { corners: full, confidence: 0, detected: false };
  const boundary = [];
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const p = y * w + x; if (!comp.mask[p]) continue;
    if (x === 0 || y === 0 || x === w - 1 || y === h - 1 || !comp.mask[p - 1] || !comp.mask[p + 1] || !comp.mask[p - w] || !comp.mask[p + w]) boundary.push([x, y]);
  }
  const hull = convexHull(boundary);
  const quad = maxAreaQuad(hull);
  if (!quad) return { corners: full, confidence: 0, detected: false };
  const quadArea = polygonArea(quad), fill = comp.size / Math.max(1, polygonArea(hull));
  const corners = orderCorners(quad).map(([x, y]) => [clamp((x + 0.5) / scale, 0, img.width - 1), clamp((y + 0.5) / scale, 0, img.height - 1)]);
  const touchesAll = coverage > 0.97;
  const confidence = touchesAll ? 0.3 : clamp(Math.min(quadArea / comp.size, 1) * fill, 0, 1);
  return { corners: touchesAll ? full : corners, confidence, detected: !touchesAll };
}

function solve(A, b) {
  const n = b.length, M = A.map((row, i) => [...row, b[i]]);
  for (let c = 0; c < n; c++) {
    let p = c; for (let r = c + 1; r < n; r++) if (Math.abs(M[r][c]) > Math.abs(M[p][c])) p = r;
    if (Math.abs(M[p][c]) < 1e-12) throw new Error('Degenerate corners');
    [M[c], M[p]] = [M[p], M[c]];
    for (let r = 0; r < n; r++) { if (r === c) continue; const f = M[r][c] / M[c][c]; for (let k = c; k <= n; k++) M[r][k] -= f * M[c][k]; }
  }
  return M.map((row, i) => row[n] / row[i]);
}

/** Homography mapping (u,v) in `from` quad to `to` quad. Returns 3x3 row-major array. */
export function homography(from, to) {
  const A = [], b = [];
  for (let i = 0; i < 4; i++) {
    const [x, y] = from[i], [u, v] = to[i];
    A.push([x, y, 1, 0, 0, 0, -u * x, -u * y]); b.push(u);
    A.push([0, 0, 0, x, y, 1, -v * x, -v * y]); b.push(v);
  }
  const h = solve(A, b);
  return [h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7], 1];
}

const dist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1]);

export function outputSize(corners, maxSide = MAX_SIDE) {
  const [tl, tr, br, bl] = corners;
  let w = Math.max(dist(tl, tr), dist(bl, br)), h = Math.max(dist(tl, bl), dist(tr, br));
  const s = Math.min(1, maxSide / Math.max(w, h));
  return { width: Math.max(16, Math.round(w * s)), height: Math.max(16, Math.round(h * s)) };
}

/** Perspective-correct the quad `corners` (TL,TR,BR,BL) into a flat rectangle with bilinear sampling. */
export function warpPerspective(img, corners, size = outputSize(corners)) {
  const { width: W, height: H } = size;
  const H3 = homography([[0, 0], [W - 1, 0], [W - 1, H - 1], [0, H - 1]], corners);
  const out = makeImage(W, H, 255), s = img.data, o = out.data, sw = img.width, sh = img.height;
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const den = H3[6] * x + H3[7] * y + H3[8];
    const sx = (H3[0] * x + H3[1] * y + H3[2]) / den, sy = (H3[3] * x + H3[4] * y + H3[5]) / den;
    const x0 = Math.floor(sx), y0 = Math.floor(sy), fx = sx - x0, fy = sy - y0;
    const oi = (y * W + x) * 4;
    if (x0 < 0 || y0 < 0 || x0 >= sw - 1 || y0 >= sh - 1) {
      const cx = clamp(Math.round(sx), 0, sw - 1), cy = clamp(Math.round(sy), 0, sh - 1), si = (cy * sw + cx) * 4;
      o[oi] = s[si]; o[oi + 1] = s[si + 1]; o[oi + 2] = s[si + 2]; o[oi + 3] = 255; continue;
    }
    const i00 = (y0 * sw + x0) * 4, i10 = i00 + 4, i01 = i00 + sw * 4, i11 = i01 + 4;
    for (let c = 0; c < 3; c++) {
      const top = s[i00 + c] + (s[i10 + c] - s[i00 + c]) * fx, bot = s[i01 + c] + (s[i11 + c] - s[i01 + c]) * fx;
      o[oi + c] = top + (bot - top) * fy;
    }
    o[oi + 3] = 255;
  }
  return out;
}

export function rotate90(img, clockwise = true) {
  const { width: w, height: h, data: s } = img, out = makeImage(h, w, 255), o = out.data;
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const nx = clockwise ? h - 1 - y : y, ny = clockwise ? x : w - 1 - x;
    const si = (y * w + x) * 4, oi = (ny * h + nx) * 4;
    o[oi] = s[si]; o[oi + 1] = s[si + 1]; o[oi + 2] = s[si + 2]; o[oi + 3] = 255;
  }
  return out;
}

function boxBlur(ch, w, h, r) {
  const tmp = new Float32Array(ch.length), out = new Float32Array(ch.length);
  for (let y = 0; y < h; y++) {
    let acc = 0, cnt = 0;
    for (let x = -r; x < w + r; x++) {
      if (x + r < w && x + r >= 0) { acc += ch[y * w + x + r]; cnt++; }
      if (x - r - 1 >= 0 && x - r - 1 < w) { acc -= ch[y * w + x - r - 1]; cnt--; }
      if (x >= 0 && x < w) tmp[y * w + x] = acc / cnt;
    }
  }
  for (let x = 0; x < w; x++) {
    let acc = 0, cnt = 0;
    for (let y = -r; y < h + r; y++) {
      if (y + r < h && y + r >= 0) { acc += tmp[(y + r) * w + x]; cnt++; }
      if (y - r - 1 >= 0 && y - r - 1 < h) { acc -= tmp[(y - r - 1) * w + x]; cnt--; }
      if (y >= 0 && y < h) out[y * w + x] = acc / cnt;
    }
  }
  return out;
}

function maxFilter(ch, w, h, r) {
  const tmp = new Float32Array(ch.length), out = new Float32Array(ch.length);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) { let m = 0; for (let k = Math.max(0, x - r); k <= Math.min(w - 1, x + r); k++) if (ch[y * w + k] > m) m = ch[y * w + k]; tmp[y * w + x] = m; }
  for (let x = 0; x < w; x++) for (let y = 0; y < h; y++) { let m = 0; for (let k = Math.max(0, y - r); k <= Math.min(h - 1, y + r); k++) if (tmp[k * w + x] > m) m = tmp[k * w + x]; out[y * w + x] = m; }
  return out;
}

/**
 * Flatten lighting and shadows: estimate the paper colour per channel on a coarse grid
 * (max filter removes ink, blur smooths) and divide it out so that paper becomes white.
 */
export function normalizeIllumination(img) {
  const { width: w, height: h } = img;
  const step = Math.max(4, Math.round(Math.max(w, h) / 160));
  const gw = Math.ceil(w / step), gh = Math.ceil(h / step), src = img.data;
  const bg = [0, 1, 2].map(c => {
    const g = new Float32Array(gw * gh);
    for (let gy = 0; gy < gh; gy++) for (let gx = 0; gx < gw; gx++) {
      // 90th percentile-ish: maximum of the cell's samples ignores dark ink.
      let m = 0;
      for (let y = gy * step; y < Math.min(h, (gy + 1) * step); y += 2) for (let x = gx * step; x < Math.min(w, (gx + 1) * step); x += 2) { const v = src[(y * w + x) * 4 + c]; if (v > m) m = v; }
      g[gy * gw + gx] = m;
    }
    return boxBlur(maxFilter(g, gw, gh, 2), gw, gh, 3);
  });
  const out = makeImage(w, h, 255), o = out.data;
  for (let y = 0; y < h; y++) {
    const fy = Math.min(gh - 1.001, Math.max(0, y / step - 0.5)), y0 = Math.floor(fy), ty = fy - y0, y1 = Math.min(gh - 1, y0 + 1);
    for (let x = 0; x < w; x++) {
      const fx = Math.min(gw - 1.001, Math.max(0, x / step - 0.5)), x0 = Math.floor(fx), tx = fx - x0, x1 = Math.min(gw - 1, x0 + 1);
      const i = (y * w + x) * 4;
      for (let c = 0; c < 3; c++) {
        const g = bg[c];
        const b = (g[y0 * gw + x0] * (1 - tx) + g[y0 * gw + x1] * tx) * (1 - ty) + (g[y1 * gw + x0] * (1 - tx) + g[y1 * gw + x1] * tx) * ty;
        o[i + c] = clamp((src[i + c] / Math.max(40, b)) * 255, 0, 255);
      }
      o[i + 3] = 255;
    }
  }
  return out;
}

/**
 * Remove handwriting from a flattened page.
 * - Colour pens, markers and highlighters: chromatic pixels are removed (text under a highlighter is kept).
 * - Pencil / light grey strokes: connected strokes whose darkest core is clearly lighter than the printed text.
 * - Where strokes cross printed text, only the pixels away from dark print are removed.
 * Returns {image, mask} where mask marks removed pixels (1).
 */
export function removeHandwriting(img, opts = {}) {
  const removeColor = opts.removeColor !== false, removePencil = opts.removePencil !== false;
  const colorThreshold = clamp(opts.colorThreshold ?? 42, 15, 120);
  const pencilSensitivity = clamp(opts.pencilSensitivity ?? 0.5, 0, 1);
  const { width: w, height: h } = img, n = w * h, s = img.data;
  const L = new Uint8Array(n), C = new Uint8Array(n);
  for (let p = 0, i = 0; p < n; p++, i += 4) {
    const r = s[i], g = s[i + 1], b = s[i + 2];
    L[p] = (r * 54 + g * 183 + b * 19) >> 8;
    C[p] = Math.max(r, g, b) - Math.min(r, g, b);
  }
  const remove = new Uint8Array(n), keepTint = new Uint8Array(n);
  // 1) Chromatic ink. Print under a highlighter is kept: a dark pixel surrounded mostly by light
  //    highlighter colour belongs to the printed text, not to a pen stroke on white paper.
  if (removeColor) {
    const R = 4, area = (2 * R + 1) * (2 * R + 1), integ = new Uint32Array((w + 1) * (h + 1));
    for (let y = 0; y < h; y++) { let row = 0; for (let x = 0; x < w; x++) { const p = y * w + x; row += (L[p] > 165 && C[p] > 45) ? 1 : 0; integ[(y + 1) * (w + 1) + x + 1] = integ[y * (w + 1) + x + 1] + row; } }
    const density = (x, y) => { const x0 = Math.max(0, x - R), y0 = Math.max(0, y - R), x1 = Math.min(w, x + R + 1), y1 = Math.min(h, y + R + 1); return (integ[y1 * (w + 1) + x1] - integ[y0 * (w + 1) + x1] - integ[y1 * (w + 1) + x0] + integ[y0 * (w + 1) + x0]) / area; };
    for (let p = 0, i = 0; p < n; p++, i += 4) {
      const r = s[i], g = s[i + 1], b = s[i + 2];
      if (L[p] < 175 && C[p] > 12) { const x = p % w; if (density(x, (p - x) / w) > 0.35) { keepTint[p] = 1; continue; } }
      // Pen hue bias survives JPEG chroma loss: blue/violet ink (b high) and red ink (r high) even when dark.
      const blue = b - Math.max(r, g), red = r - Math.max(g, b);
      if (blue > 18 || red > 26) { remove[p] = 1; continue; }
      if (C[p] <= colorThreshold) continue;
      if (L[p] < 95 && C[p] < colorThreshold + 30) continue; // dark text under a (yellow/green) highlighter
      remove[p] = 1;
    }
    // Remove anti-aliased halos around coloured strokes (light, non-dark neighbours).
    const halo = morph(remove, w, h, 2, true);
    for (let p = 0, i = 0; p < n; p++, i += 4) {
      if (!halo[p] || remove[p] || keepTint[p]) continue;
      const tinted = s[i + 2] - Math.max(s[i], s[i + 1]) > 6 || s[i] - Math.max(s[i + 1], s[i + 2]) > 8;
      if ((L[p] > 110 && C[p] > colorThreshold * 0.3) || (L[p] > 70 && tinted)) remove[p] = 1;
    }
  }
  // 2) Grey strokes by connected component.
  if (removePencil) {
    const ink = new Uint8Array(n);
    for (let p = 0; p < n; p++) ink[p] = L[p] < 205 && !remove[p] ? 1 : 0;
    const label = new Int32Array(n), stack = new Int32Array(n);
    const comps = []; let next = 1;
    for (let st = 0; st < n; st++) {
      if (!ink[st] || label[st]) continue;
      const hist = new Uint32Array(64); let top = 0, size = 0, minX = w, maxX = 0, minY = h, maxY = 0;
      stack[top++] = st; label[st] = next;
      while (top) {
        const p = stack[--top]; size++; hist[L[p] >> 2]++;
        const x = p % w, y = (p - x) / w;
        if (x < minX) minX = x; if (x > maxX) maxX = x; if (y < minY) minY = y; if (y > maxY) maxY = y;
        for (let dy = -1; dy <= 1; dy++) {
          const yy = y + dy; if (yy < 0 || yy >= h) continue;
          for (let dx = -1; dx <= 1; dx++) {
            const xx = x + dx; if (xx < 0 || xx >= w) continue;
            const q = yy * w + xx; if (ink[q] && !label[q]) { label[q] = next; stack[top++] = q; }
          }
        }
      }
      // Darkest 3% of the stroke = its core. Printed text has a near-black core even on thin strokes.
      let acc = 0, core = 255; const target = Math.max(1, size * 0.03);
      for (let k = 0; k < 64; k++) { acc += hist[k]; if (acc >= target) { core = k * 4 + 2; break; } }
      const bw = maxX - minX + 1, bh = maxY - minY + 1, thin = Math.max(3, Math.round(Math.max(w, h) * 0.006));
      // Straight thin horizontal/vertical bars (minus, equals, fraction bars, underlines, table rules) are treated as print.
      const line = size >= 0.55 * bw * bh && ((bw >= 3 * bh && bh <= thin) || (bh >= 3 * bw && bw <= thin));
      comps.push({ size, core, line }); next++;
    }
    // Printed text darkness: median core of sizeable components.
    // Printed glyphs are the darkest sizeable strokes: take a low percentile of their cores.
    const printCores = comps.filter(c => c.size >= 60).map(c => c.core).sort((a, b) => a - b);
    const printCore = printCores.length ? printCores[Math.floor(printCores.length * 0.25)] : 40;
    // sensitivity 0 = only faint pencil, 1 = also dark pencil (may touch thin print). Default 0.5.
    const pencilCut = clamp(printCore + 58 + (0.5 - pencilSensitivity) * 56, 50, 175);
    const pencilComp = new Uint8Array(next);
    for (let k = 0; k < comps.length; k++) if (comps[k].core > pencilCut && comps[k].size >= 4 && !(comps[k].line && comps[k].core <= pencilCut + 45)) pencilComp[k + 1] = 1;
    for (let p = 0; p < n; p++) if (label[p] && pencilComp[label[p]]) remove[p] = 1;
    // Strokes crossing print: inside kept components, remove grey pixels that are not near dark print.
    const dark = new Uint8Array(n);
    for (let p = 0; p < n; p++) dark[p] = L[p] < pencilCut - 10 ? 1 : 0;
    const nearDark = morph(dark, w, h, 2, true);
    for (let p = 0; p < n; p++) if (label[p] && !pencilComp[label[p]] && comps[label[p] - 1].size > 400 && !nearDark[p] && L[p] > pencilCut) remove[p] = 1;
    // Soft graphite halo around removed strokes (pixels lighter than the ink threshold).
    const grown = morph(remove, w, h, 1, true);
    for (let p = 0; p < n; p++) if (grown[p] && !remove[p] && !nearDark[p] && L[p] > pencilCut) remove[p] = 1;
    removeHandwriting.lastStats = { printCore, pencilCut, components: comps.length };
  }
  const out = cloneImage(img), o = out.data;
  for (let p = 0, i = 0; p < n; p++, i += 4) {
    if (remove[p]) { o[i] = 255; o[i + 1] = 255; o[i + 2] = 255; }
    else if (keepTint[p]) { const v = Math.round(Math.max(o[i], o[i + 1], o[i + 2]) * 0.62); o[i] = o[i + 1] = o[i + 2] = v; }
  }
  return { image: out, mask: remove };
}

/** Final look: 'clean' (white paper, crisp text), 'gray', 'bw' (pure black/white) or 'color'. */
export function finishOutput(img, mode = 'clean') {
  const out = cloneImage(img), o = out.data, n = img.width * img.height;
  if (mode === 'color') return out;
  if (mode === 'bw') {
    const lum = new Uint8Array(n);
    for (let p = 0, i = 0; p < n; p++, i += 4) lum[p] = (o[i] * 54 + o[i + 1] * 183 + o[i + 2] * 19) >> 8;
    const t = Math.min(200, Math.max(110, otsu(lum, n) + 10));
    for (let p = 0, i = 0; p < n; p++, i += 4) { const v = lum[p] < t ? 0 : 255; o[i] = o[i + 1] = o[i + 2] = v; }
    return out;
  }
  for (let p = 0, i = 0; p < n; p++, i += 4) {
    let v = (o[i] * 54 + o[i + 1] * 183 + o[i + 2] * 19) >> 8;
    if (mode === 'clean') v = v > 212 ? 255 : clamp((v - 25) * 1.2, 0, 255); // whiten paper (incl. show-through), deepen text
    o[i] = o[i + 1] = o[i + 2] = v;
  }
  return out;
}

/** Apply a manual brush mask: mode 'erase' paints paper white, 'restore' copies pixels back from `original`. */
export function applyBrush(target, original, points, radius, mode) {
  const { width: w, height: h } = target, t = target.data, s = original.data, r2 = radius * radius;
  for (const [cx, cy] of points) {
    for (let y = Math.max(0, Math.floor(cy - radius)); y <= Math.min(h - 1, Math.ceil(cy + radius)); y++)
      for (let x = Math.max(0, Math.floor(cx - radius)); x <= Math.min(w - 1, Math.ceil(cx + radius)); x++) {
        if ((x - cx) ** 2 + (y - cy) ** 2 > r2) continue;
        const i = (y * w + x) * 4;
        if (mode === 'erase') { t[i] = t[i + 1] = t[i + 2] = 255; } else { t[i] = s[i]; t[i + 1] = s[i + 1]; t[i + 2] = s[i + 2]; }
      }
  }
  return target;
}

/** One-call page pipeline used by the UI and worker. */
export function processPage(img, { corners, rotate = 0, removeColor = true, removePencil = true, pencilSensitivity, colorThreshold, mode = 'clean', erase = true, maxSide = MAX_SIDE } = {}) {
  const c = corners || detectDocument(img).corners;
  let flat = warpPerspective(img, c, outputSize(c, maxSide));
  for (let k = 0; k < ((rotate / 90) % 4 + 4) % 4; k++) flat = rotate90(flat, true);
  const normalized = normalizeIllumination(flat);
  const cleaned = erase ? removeHandwriting(normalized, { removeColor, removePencil, pencilSensitivity, colorThreshold }) : { image: normalized, mask: new Uint8Array(normalized.width * normalized.height) };
  let removed = 0; for (const v of cleaned.mask) removed += v;
  return { before: finishOutput(normalized, mode === 'color' ? 'color' : mode), after: finishOutput(cleaned.image, mode), normalized, removedRatio: removed / cleaned.mask.length, corners: c };
}
