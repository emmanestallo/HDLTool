'use strict';
importScripts('vcd.js');

self.onmessage = (e) => {
  const { id, buffer } = e.data;
  try {
    const result = parseVCD(new Uint8Array(buffer), (p) => self.postMessage({ id, progress: p }));
    const transfer = [];
    for (const t of result.traces) {
      transfer.push(t.times.buffer);
      if (t.bits) transfer.push(t.bits.buffer);
    }
    self.postMessage({ id, result }, transfer);
  } catch (err) {
    self.postMessage({ id, error: err && err.message ? err.message : String(err) });
  }
};
