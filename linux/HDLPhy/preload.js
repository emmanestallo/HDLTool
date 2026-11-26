'use strict';
// Bridge between the page and the system (window.host): files, the flow, dialogs, menus.
const { contextBridge, ipcRenderer, webUtils, clipboard } = require('electron');
const fs = require('fs');
const path = require('path');

function stat(p) {
  try { const s = fs.statSync(p); return { isDir: s.isDirectory(), isFile: s.isFile(), mtime: s.mtimeMs, size: s.size }; } catch { return null; }
}

const fsApi = {
  exists: (p) => { try { fs.accessSync(p); return true; } catch { return false; } },
  stat,
  readText(p) { try { return fs.readFileSync(p, 'utf8'); } catch { return null; } },
  writeText(p, text) {
    try {
      fs.mkdirSync(path.dirname(p), { recursive: true });
      const tmp = p + '.tmp-' + process.pid;
      fs.writeFileSync(tmp, text, 'utf8');
      fs.renameSync(tmp, p);
      return null;
    } catch (e) { return e.message || String(e); }
  },
  list(dir) {
    try { return fs.readdirSync(dir, { withFileTypes: true }).map((e) => ({ name: e.name, isDir: e.isDirectory() })); } catch { return []; }
  },
  mkdir(p) { try { fs.mkdirSync(p, { recursive: true }); return null; } catch (e) { return e.message; } },
  // HDL files under root (skipping hidden folders, run folders and node_modules), up to `limit`.
  hdlFiles(root, limit = 500) {
    const out = [];
    const skip = new Set(['node_modules', 'hdlphy_run', 'sim_out', 'build', 'dist']);
    const stack = [root];
    while (stack.length && out.length < limit) {
      const d = stack.pop();
      let entries;
      try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch { continue; }
      for (const e of entries) {
        if (e.name.startsWith('.')) continue;
        const p = path.join(d, e.name);
        if (e.isDirectory()) { if (!skip.has(e.name)) stack.push(p); } else if (/\.(v|sv|vh|svh)$/i.test(e.name)) out.push(p);
      }
    }
    return out.sort();
  },
  writeBinary(p, uint8) {
    try { fs.writeFileSync(p, Buffer.from(uint8)); return null; } catch (e) { return e.message; }
  },
};

const pathApi = {
  join: (...a) => path.join(...a), dirname: (p) => path.dirname(p), basename: (p, ext) => path.basename(p, ext),
  extname: (p) => path.extname(p), resolve: (...a) => path.resolve(...a), relative: (a, b) => path.relative(a, b),
  isAbsolute: (p) => path.isAbsolute(p), sep: path.sep,
};

const launch = ipcRenderer.sendSync('get-launch-sync');

contextBridge.exposeInMainWorld('host', {
  platform: process.platform,
  launch,
  fs: fsApi,
  path: pathApi,
  clipboard: { write: (s) => clipboard.writeText(String(s)) },
  openDialog: (opts) => ipcRenderer.invoke('open-dialog', opts),
  saveDialog: (opts) => ipcRenderer.invoke('save-dialog', opts),
  messageBox: (opts) => ipcRenderer.sendSync('message-box-sync', opts),
  popupMenu: (items, pos) => ipcRenderer.invoke('popup-menu', items, pos),
  setTheme: (t) => ipcRenderer.invoke('set-theme', t),
  setTitle: (t) => ipcRenderer.invoke('set-title', t),
  toggleMaximize: () => ipcRenderer.invoke('toggle-maximize'),
  toggleDevTools: () => ipcRenderer.invoke('toggle-devtools'),
  quitConfirmed: () => ipcRenderer.invoke('quit-confirmed'),
  showInFolder: (p) => ipcRenderer.invoke('show-in-folder', p),
  openPath: (p) => ipcRenderer.invoke('open-path', p),
  openExternal: (u) => ipcRenderer.invoke('open-external', u),
  pathForFile: (file) => webUtils.getPathForFile(file),
  flow: {
    start: (args) => ipcRenderer.invoke('flow-start', args),
    stop: () => ipcRenderer.invoke('flow-stop'),
    check: () => ipcRenderer.invoke('flow-check'),
    onOutput: (cb) => ipcRenderer.on('flow-output', (_e, lines) => cb(lines)),
    onExit: (cb) => ipcRenderer.on('flow-exit', (_e, r) => cb(r)),
  },
  schematic: (req) => ipcRenderer.invoke('schematic', req),
  cancelSchematic: () => ipcRenderer.invoke('schematic-cancel'),
  readLayout: (p) => ipcRenderer.invoke('read-layout', p),
  openKLayout: (gds, lyp) => ipcRenderer.invoke('open-klayout', gds, lyp),
  onOpenPaths: (cb) => ipcRenderer.on('open-paths', (_e, paths) => cb(paths)),
  onCloseRequested: (cb) => ipcRenderer.on('close-requested', () => cb()),
});
