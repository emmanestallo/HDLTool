'use strict';
// Bridge between the page and the system: files, processes, dialogs. Runs with Node access
// (sandbox off) and exposes a small API as window.host.
const { contextBridge, ipcRenderer, webUtils, clipboard } = require('electron');
const fs = require('fs');
const path = require('path');
const { spawn, execFile } = require('child_process');

const isWin = process.platform === 'win32';
const isMac = process.platform === 'darwin';
const os = require('os');

function stat(p) {
  try { const s = fs.statSync(p); return { isDir: s.isDirectory(), isFile: s.isFile(), mtime: s.mtimeMs, size: s.size }; } catch { return null; }
}

const fsApi = {
  exists: (p) => { try { fs.accessSync(p); return true; } catch { return false; } },
  stat,
  readText(p) {
    try {
      const buf = fs.readFileSync(p);
      let s = buf.toString('utf8');
      if (s.charCodeAt(0) === 0xFEFF) s = s.slice(1);
      return s;
    } catch { return null; }
  },
  // True when the start of the file contains a NUL byte (binary file).
  isBinary(p) {
    try {
      const fd = fs.openSync(p, 'r');
      const buf = Buffer.alloc(8192);
      const n = fs.readSync(fd, buf, 0, 8192, 0);
      fs.closeSync(fd);
      return buf.subarray(0, n).includes(0);
    } catch { return false; }
  },
  writeText(p, text) {
    try {
      fs.mkdirSync(path.dirname(p), { recursive: true });
      const tmp = p + '.tmp-' + process.pid;
      fs.writeFileSync(tmp, text, 'utf8');
      try { fs.renameSync(tmp, p); } catch { fs.copyFileSync(tmp, p); fs.unlinkSync(tmp); }
      return null;
    } catch (e) { return e.message || String(e); }
  },
  list(dir) {
    try { return fs.readdirSync(dir, { withFileTypes: true }).map((e) => ({ name: e.name, isDir: e.isDirectory() })); } catch { return []; }
  },
  mkdir(p) { try { fs.mkdirSync(p, { recursive: true }); return null; } catch (e) { return e.message; } },
  rename(a, b) { try { fs.renameSync(a, b); return null; } catch (e) { return e.message; } },
  copy(a, b) { try { fs.copyFileSync(a, b); return null; } catch (e) { return e.message; } },
  remove(p) { try { fs.rmSync(p, { force: true }); return null; } catch (e) { return e.message; } },
  realpath(p) { try { return fs.realpathSync.native(p); } catch { return null; } },
  // All files under root (skipping hidden entries and the given folder names), up to `limit`.
  walk(root, skipDirs, limit) {
    const out = [];
    const skip = new Set(skipDirs || []);
    const stack = [root];
    while (stack.length && out.length < limit) {
      const d = stack.pop();
      let entries;
      try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch { continue; }
      entries.sort((a, b) => (a.name < b.name ? 1 : -1));
      for (const e of entries) {
        if (e.name.startsWith('.')) continue;
        const p = path.join(d, e.name);
        if (e.isDirectory()) { if (!skip.has(e.name)) stack.push(p); }
        else { out.push(p); if (out.length >= limit) break; }
      }
    }
    return out;
  },
};

// ---------------------------------------------------------------- Processes

const procs = new Map();
let procId = 1;

function envFor(exe) {
  const env = Object.assign({}, process.env);
  const key = Object.keys(env).find((k) => k.toLowerCase() === 'path') || 'PATH';
  const home = os.homedir();
  const extra = isWin ? [] : isMac ? ['/opt/homebrew/bin', '/usr/local/bin']
    : ['/usr/local/bin', path.join(home, '.local', 'bin'), path.join(home, 'oss-cad-suite', 'bin')];
  env[key] = [path.dirname(exe), ...extra, env[key] || ''].join(path.delimiter);
  return env;
}

const procApi = {
  // Finds an executable: `custom` (a file or folder), then the given folders, then PATH.
  find(name, custom, dirs) {
    const exe = isWin && !name.toLowerCase().endsWith('.exe') ? name + '.exe' : name;
    const candidates = [];
    const c = (custom || '').trim().replace(/^"|"$/g, '');
    if (c) {
      const s = stat(c);
      if (s && s.isDir) candidates.push(path.join(c, exe));
      else candidates.push(c);
    }
    const envPath = (process.env.PATH || process.env.Path || '').split(path.delimiter).filter(Boolean);
    for (const d of [...(dirs || []), ...envPath]) candidates.push(path.join(d, exe));
    for (const p of candidates) {
      const s = stat(p);
      if (s && s.isFile) {
        if (isWin) return p;
        try { fs.accessSync(p, fs.constants.X_OK); return p; } catch { /* not executable */ }
      }
    }
    return null;
  },
  // Runs a command; output arrives through onData(text), the exit code through onExit(code).
  run(exe, args, cwd, onData, onExit) {
    const id = procId++;
    let child;
    try {
      child = spawn(exe, args, { cwd, env: envFor(exe), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) {
      setTimeout(() => { onData(`Could not start ${exe}: ${e.message}\n`); onExit(-1); }, 0);
      return id;
    }
    procs.set(id, child);
    let finished = false;
    const done = (code) => { if (finished) return; finished = true; procs.delete(id); onExit(code); };
    child.stdout.on('data', (d) => onData(d.toString('utf8')));
    child.stderr.on('data', (d) => onData(d.toString('utf8')));
    child.on('error', (e) => { onData(`Could not start ${exe}: ${e.message}\n`); done(-1); });
    child.on('close', (code, signal) => done(code == null ? (signal ? 143 : -1) : code));
    return id;
  },
  kill(id) {
    const c = procs.get(id);
    if (!c) return;
    if (isWin) {
      try { execFile('taskkill', ['/pid', String(c.pid), '/T', '/F'], { windowsHide: true }); } catch { c.kill(); }
    } else c.kill();
  },
  // Runs a command and returns all of its output (stdout + stderr).
  capture(exe, args, cwd, timeoutMs) {
    return new Promise((resolve) => {
      let out = '';
      let child;
      try { child = spawn(exe, args, { cwd, env: envFor(exe), windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] }); } catch { resolve(''); return; }
      const timer = setTimeout(() => { try { child.kill(); } catch { /* gone */ } }, timeoutMs || 30000);
      child.stdout.on('data', (d) => { out += d.toString('utf8'); });
      child.stderr.on('data', (d) => { out += d.toString('utf8'); });
      child.on('error', () => { clearTimeout(timer); resolve(out); });
      child.on('close', () => { clearTimeout(timer); resolve(out); });
    });
  },
};

const pathApi = {
  join: (...a) => path.join(...a),
  dirname: (p) => path.dirname(p),
  basename: (p, ext) => path.basename(p, ext),
  extname: (p) => path.extname(p),
  resolve: (...a) => path.resolve(...a),
  normalize: (p) => path.normalize(p),
  relative: (a, b) => path.relative(a, b),
  isAbsolute: (p) => path.isAbsolute(p),
  sep: path.sep,
  delimiter: path.delimiter,
};

const launch = ipcRenderer.sendSync('get-launch-sync');

contextBridge.exposeInMainWorld('host', {
  platform: process.platform,
  launch,
  env: { LOCALAPPDATA: process.env.LOCALAPPDATA || '', ProgramFiles: process.env.ProgramFiles || '', ProgramW6432: process.env.ProgramW6432 || '', USERPROFILE: process.env.USERPROFILE || '', SystemDrive: process.env.SystemDrive || 'C:' },
  fs: fsApi,
  proc: procApi,
  path: pathApi,
  clipboard: { write: (s) => clipboard.writeText(String(s)), read: () => clipboard.readText() },
  openDialog: (opts) => ipcRenderer.sendSync('open-dialog-sync', opts),
  saveDialog: (opts) => ipcRenderer.sendSync('save-dialog-sync', opts),
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
  trash: (p) => ipcRenderer.invoke('trash', p),
  openInViewer: (p) => ipcRenderer.invoke('open-in-viewer', p),
  viewerPath: () => ipcRenderer.sendSync('viewer-path-sync'),
  openInHDLPhy: (paths) => ipcRenderer.invoke('open-in-hdlphy', paths),
  hdlphyPath: () => ipcRenderer.sendSync('hdlphy-path-sync'),
  pathForFile: (file) => webUtils.getPathForFile(file),
  onOpenFiles: (cb) => ipcRenderer.on('open-files', (_e, files) => cb(files)),
  onCloseRequested: (cb) => ipcRenderer.on('close-requested', () => cb()),
});
