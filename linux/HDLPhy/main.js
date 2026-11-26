'use strict';
// HDLPhy — Electron main process. Synthesis and place-and-route on SKY130 with schematic and
// layout views. The page (src/) holds the app; this process provides the window, dialogs and menus,
// and runs the tools: the flow driver (flow/hdlphy_flow.py), the schematic worker and KLayout.
const { app, BrowserWindow, Menu, dialog, ipcMain, nativeTheme, shell, screen } = require('electron');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const isMac = process.platform === 'darwin';
let win = null;
let allowClose = false;
const pendingPaths = [];

// ---------------------------------------------------------------- Launch arguments

function parseArgs(argv) {
  const out = { paths: [], snapshot: null, theme: null, tab: null, size: null, wait: 3, actions: null, dev: false };
  const args = argv.slice(app.isPackaged ? 1 : 2);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--snapshot') out.snapshot = args[++i];
    else if (a === '--theme') out.theme = args[++i];
    else if (a === '--tab') out.tab = args[++i];
    else if (a === '--size') out.size = args[++i];
    else if (a === '--wait') out.wait = parseFloat(args[++i]);
    else if (a === '--actions') out.actions = args[++i];
    else if (a.startsWith('-')) continue;
    else if (exists(a) && path.resolve(a) !== __dirname) out.paths.push(path.resolve(a));
  }
  out.dev = !!(out.snapshot || out.actions);
  return out;
}
function exists(p) { try { fs.statSync(p); return true; } catch { return false; } }

const launch = parseArgs(process.argv);
if (launch.dev) app.setPath('userData', path.join(app.getPath('temp'), 'hdlphy-dev-' + process.pid));

if (!launch.dev && !app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', (_e, argv) => {
    const paths = parseArgs(argv).paths;
    if (win) {
      if (win.isMinimized()) win.restore();
      win.focus();
      if (paths.length) win.webContents.send('open-paths', paths);
    }
  });
}

// ---------------------------------------------------------------- Window

const OVERLAY_HEIGHT = 35;
const stateFile = () => path.join(app.getPath('userData'), 'window.json');

function loadBounds() {
  try {
    const b = JSON.parse(fs.readFileSync(stateFile(), 'utf8'));
    const area = screen.getDisplayMatching(b).workArea;
    if (b.width > 400 && b.height > 300 && b.x < area.x + area.width && b.y < area.y + area.height) return b;
  } catch { /* first run */ }
  return null;
}

function createWindow() {
  let size = null;
  if (launch.size) { const [w, h] = launch.size.split('x').map(Number); if (w && h) size = { width: w, height: h }; }
  const saved = launch.dev ? null : loadBounds();
  win = new BrowserWindow({
    width: size ? size.width : (saved ? saved.width : 1440),
    height: size ? size.height : (saved ? saved.height : 900),
    x: saved && !size ? saved.x : undefined,
    y: saved && !size ? saved.y : undefined,
    minWidth: 900,
    minHeight: 540,
    show: false,
    backgroundColor: '#1F1F1F',
    title: 'HDLPhy',
    icon: path.join(__dirname, 'build', 'icon.png'),
    titleBarStyle: 'hidden',
    ...(isMac ? { trafficLightPosition: { x: 13, y: 11 } }
      : { titleBarOverlay: { color: '#181818', symbolColor: '#CCCCCC', height: OVERLAY_HEIGHT } }),
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: false, spellcheck: false },
  });
  if (saved && saved.maximized && !launch.dev) win.maximize();
  win.loadFile(path.join(__dirname, 'src', 'index.html'));
  if (!app.isPackaged) {
    win.webContents.on('console-message', (e) => {
      if (e.level === 'error' || e.level === 'warning' || /\[test\]/.test(e.message)) console.log(`[renderer] ${e.level}: ${e.message}`);
    });
    win.webContents.on('preload-error', (_e, p, err) => console.log(`[preload] ${p}: ${err}`));
  }
  win.once('ready-to-show', () => { if (!launch.snapshot) win.show(); else win.showInactive(); });

  const saveBounds = () => {
    if (!win || launch.dev) return;
    try {
      fs.mkdirSync(path.dirname(stateFile()), { recursive: true });
      fs.writeFileSync(stateFile(), JSON.stringify({ ...win.getNormalBounds(), maximized: win.isMaximized() }));
    } catch { /* ignore */ }
  };
  win.on('close', (e) => {
    saveBounds();
    if (allowClose || launch.dev) { stopFlow(); return; }
    e.preventDefault();
    win.webContents.send('close-requested');
  });
  win.on('closed', () => { win = null; });
  win.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/.test(url)) shell.openExternal(url);
    return { action: 'deny' };
  });
  win.webContents.on('will-navigate', (e) => e.preventDefault());

  if (launch.snapshot) {
    // Development only: run a script against the page ($HDLPHY_TEST_JS), then take the snapshot when it
    // finishes (or after --wait seconds without a script).
    const snap = async () => {
      if (!win) return;
      const img = await win.webContents.capturePage();
      fs.writeFileSync(launch.snapshot, img.toPNG());
      allowClose = true;
      app.quit();
    };
    if (!app.isPackaged && process.env.HDLPHY_TEST_JS) {
      setTimeout(() => {
        win.webContents.executeJavaScript(fs.readFileSync(process.env.HDLPHY_TEST_JS, 'utf8'))
          .then((r) => console.log('[test]', typeof r === 'string' ? r : JSON.stringify(r)))
          .catch((err) => console.log('[test] error', err.message))
          .finally(() => setTimeout(snap, 600));
      }, 1500);
    } else {
      setTimeout(snap, launch.wait * 1000);
    }
  }
}

function buildMenu() {
  if (!isMac) { Menu.setApplicationMenu(null); return; }
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { role: 'appMenu' }, { role: 'editMenu' },
    { label: 'View', submenu: [{ role: 'toggleDevTools' }, { role: 'togglefullscreen' }] }, { role: 'windowMenu' },
  ]));
}

app.whenReady().then(() => {
  buildMenu();
  createWindow();
  app.on('activate', () => { if (!win) createWindow(); });
});
app.on('window-all-closed', () => app.quit());
app.on('before-quit', () => stopFlow());

// ---------------------------------------------------------------- Locations

const flowDir = () => (app.isPackaged ? path.join(process.resourcesPath, 'flow') : path.join(__dirname, 'flow'));
const examplesDir = () => (app.isPackaged ? path.join(process.resourcesPath, 'examples') : path.join(__dirname, 'examples'));
const skinPath = () => path.join(__dirname, 'src', 'skin', 'hdlphy-skin.svg');

function findOnPath(name) {
  for (const d of (process.env.PATH || '').split(path.delimiter).filter(Boolean)) {
    const p = path.join(d, name);
    try { fs.accessSync(p, fs.constants.X_OK); if (fs.statSync(p).isFile()) return p; } catch { /* next */ }
  }
  return null;
}
const python = () => process.env.HDLPHY_PYTHON || findOnPath('python3') || 'python3';

// ---------------------------------------------------------------- IPC: basics

ipcMain.on('get-launch-sync', (e) => {
  e.returnValue = {
    ...launch, paths: [...launch.paths, ...pendingPaths.splice(0)],
    platform: process.platform, version: app.getVersion(),
    home: app.getPath('home'), documents: app.getPath('documents'), temp: app.getPath('temp'),
    examples: examplesDir(), flow: flowDir(), isPackaged: app.isPackaged,
  };
});
ipcMain.handle('open-dialog', async (_e, opts) => {
  const r = await dialog.showOpenDialog(win, opts);
  return r.canceled ? [] : r.filePaths;
});
ipcMain.handle('save-dialog', async (_e, opts) => {
  const r = await dialog.showSaveDialog(win, opts);
  return r.canceled ? null : r.filePath;
});
ipcMain.on('message-box-sync', (e, opts) => { e.returnValue = dialog.showMessageBoxSync(win, { noLink: true, ...opts }); });
ipcMain.handle('set-theme', (_e, t) => {
  if (!win) return;
  nativeTheme.themeSource = t.dark ? 'dark' : 'light';
  win.setBackgroundColor(t.editor);
  if (!isMac) win.setTitleBarOverlay({ color: t.titleBar, symbolColor: t.titleFG, height: OVERLAY_HEIGHT });
});
ipcMain.handle('set-title', (_e, title) => { if (win) win.setTitle(title); });
ipcMain.handle('toggle-maximize', () => { if (win) { if (win.isMaximized()) win.unmaximize(); else win.maximize(); } });
ipcMain.handle('toggle-devtools', () => { if (win) win.webContents.toggleDevTools(); });
ipcMain.handle('quit-confirmed', () => { allowClose = true; if (win) win.close(); });
ipcMain.handle('show-in-folder', (_e, p) => shell.showItemInFolder(p));
ipcMain.handle('open-path', (_e, p) => shell.openPath(p));
ipcMain.handle('open-external', (_e, url) => { if (/^https?:/.test(url)) shell.openExternal(url); });

ipcMain.handle('popup-menu', (_e, items, pos) => new Promise((resolve) => {
  let done = false;
  const finish = (id) => { if (!done) { done = true; resolve(id); } };
  const build = (list) => list.map((it) => {
    if (it.type === 'separator') return { type: 'separator' };
    if (it.type === 'header') return { label: it.label, enabled: false };
    const item = { label: it.label, enabled: it.enabled !== false, accelerator: it.accelerator, registerAccelerator: false };
    if (it.submenu) item.submenu = build(it.submenu);
    else {
      if (it.type === 'radio' || it.type === 'checkbox') { item.type = 'checkbox'; item.checked = !!it.checked; }
      item.click = () => finish(it.id);
    }
    return item;
  });
  Menu.buildFromTemplate(build(items)).popup({
    window: win, ...(pos ? { x: Math.round(pos.x), y: Math.round(pos.y) } : {}),
    callback: () => setTimeout(() => finish(null), 50),
  });
}));

// ---------------------------------------------------------------- IPC: flow

let flowProc = null;

function stopFlow() {
  if (!flowProc) return false;
  try { process.kill(-flowProc.pid, 'SIGTERM'); } catch { try { flowProc.kill('SIGTERM'); } catch { /* gone */ } }
  const p = flowProc;
  setTimeout(() => { try { process.kill(-p.pid, 'SIGKILL'); } catch { /* gone */ } }, 3000);
  return true;
}

// Runs hdlphy_flow.py with the given arguments; output lines go to the page as 'flow-output'.
ipcMain.handle('flow-start', (_e, args) => {
  if (flowProc) return { ok: false, error: 'A run is already in progress.' };
  const script = path.join(flowDir(), 'hdlphy_flow.py');
  let child;
  try {
    child = spawn(python(), ['-u', script, ...args], { detached: true, stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, PYTHONUNBUFFERED: '1' } });
  } catch (e) {
    return { ok: false, error: e.message };
  }
  flowProc = child;
  const send = (ch, payload) => { if (win && !win.isDestroyed()) win.webContents.send(ch, payload); };
  let buf = '';
  const onData = (d) => {
    buf += d.toString('utf8');
    let i;
    const lines = [];
    while ((i = buf.indexOf('\n')) >= 0) { lines.push(buf.slice(0, i)); buf = buf.slice(i + 1); }
    if (lines.length) send('flow-output', lines);
  };
  child.stdout.on('data', onData);
  child.stderr.on('data', onData);
  child.on('error', (e) => send('flow-output', ['could not start the flow: ' + e.message]));
  child.on('close', (code, signal) => {
    if (buf) send('flow-output', [buf]);
    buf = '';
    if (flowProc === child) flowProc = null;
    send('flow-exit', { code, signal });
  });
  return { ok: true, pid: child.pid };
});
ipcMain.handle('flow-stop', () => stopFlow());
ipcMain.handle('flow-check', () => new Promise((resolve) => {
  const script = path.join(flowDir(), 'hdlphy_flow.py');
  let out = '';
  let child;
  try { child = spawn(python(), [script, 'check'], { stdio: ['ignore', 'pipe', 'pipe'] }); } catch (e) { resolve({ error: e.message }); return; }
  child.stdout.on('data', (d) => { out += d; });
  child.on('error', (e) => resolve({ error: e.message }));
  child.on('close', () => { try { resolve(JSON.parse(out)); } catch { resolve({ error: out || 'no output' }); } });
}));

// ---------------------------------------------------------------- IPC: schematic and layout

let schematicProc = null;
ipcMain.handle('schematic', (_e, req) => new Promise((resolve) => {
  if (schematicProc) { try { schematicProc.kill('SIGKILL'); } catch { /* gone */ } }
  const child = spawn(process.execPath, [path.join(__dirname, 'schematic-worker.js')],
    { env: { ...process.env, ELECTRON_RUN_AS_NODE: '1' }, stdio: ['pipe', 'pipe', 'pipe'] });
  schematicProc = child;
  let out = '';
  let err = '';
  const timer = setTimeout(() => { try { child.kill('SIGKILL'); } catch { /* gone */ } }, (req.timeoutSec || 180) * 1000);
  child.stdout.on('data', (d) => { out += d; });
  child.stderr.on('data', (d) => { err += d; });
  child.on('close', (code, signal) => {
    clearTimeout(timer);
    if (schematicProc === child) schematicProc = null;
    if (signal) { resolve({ ok: false, cancelled: true, error: 'Stopped.' }); return; }
    try { resolve(JSON.parse(out)); } catch { resolve({ ok: false, error: (err || out || 'schematic worker failed (code ' + code + ')').slice(0, 2000) }); }
  });
  child.stdin.end(JSON.stringify({ ...req, skin: skinPath() }));
}));
ipcMain.handle('schematic-cancel', () => { if (schematicProc) { schematicProc.kill('SIGKILL'); return true; } return false; });

// The layout geometry: JSON header + binary polygons (sent as an ArrayBuffer-backed Uint8Array).
ipcMain.handle('read-layout', (_e, jsonPath) => {
  try {
    const header = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
    const bin = fs.readFileSync(path.join(path.dirname(jsonPath), header.bin));
    return { ok: true, header, bin: new Uint8Array(bin.buffer, bin.byteOffset, bin.byteLength) };
  } catch (e) {
    return { ok: false, error: e.message };
  }
});

ipcMain.handle('open-klayout', (_e, gds, lyp) => {
  const exe = ['/usr/bin/klayout', findOnPath('klayout')].find((p) => p && exists(p));
  if (!exe) return { ok: false, error: 'KLayout was not found.' };
  const args = [];
  if (lyp && exists(lyp)) args.push('-l', lyp);
  args.push(gds);
  try {
    spawn(exe, args, { detached: true, stdio: 'ignore' }).unref();
    return { ok: true };
  } catch (e) {
    return { ok: false, error: e.message };
  }
});
