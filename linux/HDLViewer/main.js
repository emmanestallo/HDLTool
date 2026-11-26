'use strict';
const { app, BrowserWindow, Menu, dialog, ipcMain, nativeTheme } = require('electron');
const fs = require('fs');
const path = require('path');

const isMac = process.platform === 'darwin';
let win = null;
const pendingFiles = [];

// ---------- Launch arguments ----------

function parseArgs(argv) {
  const out = { files: [], snapshot: null, cursor: null, marker: null, theme: null };
  const args = argv.slice(app.isPackaged ? 1 : 2);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--snapshot') out.snapshot = args[++i];
    else if (a === '--cursor') out.cursor = parseFloat(args[++i]);
    else if (a === '--marker') out.marker = parseFloat(args[++i]);
    else if (a === '--theme') out.theme = args[++i];
    else if (!a.startsWith('-') && isFile(a)) out.files.push(path.resolve(a));
  }
  return out;
}

function isFile(p) {
  try { return fs.statSync(p).isFile(); } catch { return false; }
}

const launch = parseArgs(process.argv);

// ---------- Single instance: open files in the existing window ----------

if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', (_e, argv) => {
    const files = parseArgs(argv).files;
    if (win) {
      if (win.isMinimized()) win.restore();
      win.focus();
      if (files.length) win.webContents.send('open-files', files);
    }
  });
}

app.on('open-file', (e, p) => { // macOS
  e.preventDefault();
  if (win) win.webContents.send('open-files', [p]); else pendingFiles.push(p);
});

// ---------- Window ----------

const OVERLAY_HEIGHT = 35;

function createWindow() {
  win = new BrowserWindow({
    width: 1400,
    height: 860,
    minWidth: 820,
    minHeight: 480,
    show: false,
    backgroundColor: '#1F1F1F',
    title: 'HDL Viewer',
    icon: path.join(__dirname, 'build', 'icon.png'),
    titleBarStyle: 'hidden',
    ...(isMac
      ? { trafficLightPosition: { x: 13, y: 11 } }
      : { titleBarOverlay: { color: '#181818', symbolColor: '#CCCCCC', height: OVERLAY_HEIGHT } }),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      sandbox: true,
      spellcheck: false,
    },
  });

  win.loadFile(path.join(__dirname, 'src', 'index.html'));
  if (!app.isPackaged) {
    win.webContents.on('console-message', (e) => console.log(`[renderer] ${e.level}: ${e.message}`));
    win.webContents.on('preload-error', (_e, p, err) => console.log(`[preload] ${p}: ${err}`));
  }
  win.once('ready-to-show', () => win.show());
  win.on('closed', () => { win = null; });

  // Keep links and new windows out of the app.
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('will-navigate', (e) => e.preventDefault());

  if (launch.snapshot) {
    // Dev-only: run a script file against the page before the snapshot (used for testing).
    if (!app.isPackaged && process.env.HDLV_TEST_JS) {
      setTimeout(() => {
        win.webContents.executeJavaScript(fs.readFileSync(process.env.HDLV_TEST_JS, 'utf8'))
          .then((r) => console.log('[test]', JSON.stringify(r)))
          .catch((err) => console.log('[test] error', err.message));
      }, 1500);
    }
    setTimeout(async () => {
      const img = await win.webContents.capturePage();
      fs.writeFileSync(launch.snapshot, img.toPNG());
      app.quit();
    }, 3500);
  }
}

function buildMenu() {
  if (!isMac) { Menu.setApplicationMenu(null); return; }
  // On macOS keep the standard menus so Edit shortcuts work in text fields.
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    { role: 'appMenu' }, { role: 'editMenu' },
    { label: 'View', submenu: [{ role: 'toggleDevTools' }, { role: 'togglefullscreen' }] },
    { role: 'windowMenu' },
  ]));
}

app.whenReady().then(() => {
  buildMenu();
  createWindow();
  app.on('activate', () => { if (!win) createWindow(); });
});

app.on('window-all-closed', () => app.quit());

// ---------- IPC ----------

ipcMain.handle('get-launch', () => ({
  ...launch,
  files: [...launch.files, ...pendingFiles.splice(0)],
  platform: process.platform,
  example: app.isPackaged
    ? path.join(process.resourcesPath, 'counter.vcd')
    : path.join(__dirname, 'examples', 'counter.vcd'),
}));

ipcMain.handle('open-dialog', async () => {
  const r = await dialog.showOpenDialog(win, {
    title: 'Open Waveform',
    properties: ['openFile', 'multiSelections'],
    filters: [{ name: 'VCD waveforms', extensions: ['vcd'] }, { name: 'All files', extensions: ['*'] }],
  });
  return r.canceled ? [] : r.filePaths;
});

ipcMain.handle('read-file', async (_e, p) => {
  const data = await fs.promises.readFile(p);
  const st = await fs.promises.stat(p);
  return { data: new Uint8Array(data.buffer, data.byteOffset, data.byteLength), mtime: st.mtimeMs };
});

ipcMain.handle('file-exists', (_e, p) => isFile(p));

// Auto-reload: poll the file once a second; notify once it has stopped changing.
const watchers = new Map();
ipcMain.handle('watch', (_e, p, mtime) => {
  if (watchers.has(p)) return;
  const w = { last: mtime, timer: null };
  w.timer = setInterval(() => {
    fs.stat(p, (err, st) => {
      if (err || !win) return;
      if (st.mtimeMs !== w.last && Date.now() - st.mtimeMs > 400) {
        w.last = st.mtimeMs;
        win.webContents.send('file-changed', p);
      }
    });
  }, 1000);
  watchers.set(p, w);
});
ipcMain.handle('set-mtime', (_e, p, mtime) => { const w = watchers.get(p); if (w) w.last = mtime; });
ipcMain.handle('unwatch', (_e, p) => {
  const w = watchers.get(p);
  if (w) { clearInterval(w.timer); watchers.delete(p); }
});

ipcMain.handle('set-theme', (_e, t) => {
  if (!win) return;
  nativeTheme.themeSource = t.dark ? 'dark' : 'light';
  win.setBackgroundColor(t.editor);
  if (!isMac) win.setTitleBarOverlay({ color: t.titleBar, symbolColor: t.titleFG, height: OVERLAY_HEIGHT });
});

ipcMain.handle('set-title', (_e, title) => { if (win) win.setTitle(title); });

// Native popup menus described by the renderer. Resolves with the chosen item id (or null).
ipcMain.handle('popup-menu', (_e, items, pos) => new Promise((resolve) => {
  let done = false;
  const finish = (id) => { if (!done) { done = true; resolve(id); } };
  const build = (list) => list.map((it) => {
    if (it.type === 'separator') return { type: 'separator' };
    const item = { label: it.label, enabled: it.enabled !== false, accelerator: it.accelerator, registerAccelerator: false };
    if (it.submenu) item.submenu = build(it.submenu);
    else {
      if (it.type === 'radio' || it.type === 'checkbox') { item.type = it.type; item.checked = !!it.checked; }
      item.click = () => finish(it.id);
    }
    return item;
  });
  const menu = Menu.buildFromTemplate(build(items));
  menu.popup({
    window: win,
    ...(pos ? { x: Math.round(pos.x), y: Math.round(pos.y) } : {}),
    callback: () => setTimeout(() => finish(null), 50),
  });
}));
