// Still encoding, off the thread that paints.
//
// WHY. Every photo the app seals — a dragged file, a picked one, and now every still in an
// Instagram archive — was decoded, drawn to a <canvas> and JPEG-encoded on the MAIN thread. For one
// photo that is a blink. For an archive it is the whole run: the window locks up in bursts, one
// burst per item, because `drawImage` and `toDataURL` are synchronous and nothing else can paint
// while they run.
//
// `createImageBitmap` + `OffscreenCanvas` do the identical work here instead, where blocking costs
// nothing. The main thread only posts bytes and receives a string.
//
// Loaded as a same-origin file rather than a Blob URL on purpose: the app's CSP is `script-src
// 'self'`, which permits this and forbids that.

/** Chunked so a multi-megabyte photo does not blow the argument limit of String.fromCharCode. */
function toBase64(buf) {
  const bytes = new Uint8Array(buf);
  let s = "";
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
  }
  return btoa(s);
}

async function draw(buf, type, maxDim) {
  const bitmap = await createImageBitmap(new Blob([buf], { type: type || "image/jpeg" }));
  const scale = Math.min(1, maxDim / Math.max(bitmap.width, bitmap.height));
  const w = Math.max(1, Math.round(bitmap.width * scale));
  const h = Math.max(1, Math.round(bitmap.height * scale));
  const canvas = new OffscreenCanvas(w, h);
  canvas.getContext("2d").drawImage(bitmap, 0, 0, w, h);
  bitmap.close();   // release the decoded pixels immediately — an import runs hundreds of these
  return canvas;
}

self.onmessage = async (e) => {
  const { id, buf, type, maxDim, quality, mode, maxBytes } = e.data;
  try {
    const canvas = await draw(buf, type, maxDim);
    if (mode === "thumb") {
      // Walk the quality down until it fits, exactly as the main-thread version did — a "thumb"
      // that isn't tiny is just a second copy of the photo.
      let q = quality;
      let blob = await canvas.convertToBlob({ type: "image/jpeg", quality: q });
      while (blob.size > maxBytes && q > 0.25) {
        q -= 0.15;
        blob = await canvas.convertToBlob({ type: "image/jpeg", quality: q });
      }
      if (blob.size > maxBytes * 1.5) return self.postMessage({ id, ok: false, err: "too big" });
      return self.postMessage({ id, ok: true, b64: toBase64(await blob.arrayBuffer()) });
    }
    const blob = await canvas.convertToBlob({ type: "image/jpeg", quality });
    self.postMessage({ id, ok: true, b64: toBase64(await blob.arrayBuffer()) });
  } catch (err) {
    self.postMessage({ id, ok: false, err: String(err && err.message ? err.message : err) });
  }
};
