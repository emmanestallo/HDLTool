'use strict';
// HDL Simulator for Windows and Linux — Electron main process.
// The window hosts two tabs (Coder and Tester). All app logic runs in the renderer; this process
// provides the window, native dialogs and menus, and file-open events.
const { app, BrowserWindow, Menu, dialog, ipcMain, nativeTheme, shell, screen } = require('electron');
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const isMac = process.platform === 'darwin';
const isWin = process.platform === 'win32';
let win = null;
let allowClose = false;
const pendingFiles = [];

// ---------------------------------------------------------------- Launch arguments

function parseArgs(argv) {
  const out = { files: [], snapshot: null, theme: null, tab: null, size: null, wait: 2.5, actions: null, select: null, panel: null, dev: false };
  const args = argv.slice(app.isPackaged ? 1 : 2);
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === '--snapshot') out.snapshot = args[++i];
    else if (a === '--theme') out.theme = args[++i];
    else if (a === '--tab') out.tab = args[++i];
    else if (a === '--size') out.size = args[++i];
    else if (a === '--wait') out.wait = parseFloat(args[++i]);
    else if (a === '--actions') out.actions = args[++i];
    else if (a === '--select') out.select = args[++i];
    else if (a === '--panel') out.panel = args[++i];
    else if (a.startsWith('-')) continue;
    else if (exists(a)) out.files.push(path.resolve(a));
  }
  out.dev = !!(out.snapshot || out.actions);
  return out;
}
function exists(p) { try { fs.statSync(p); return true; } catch { return false; } }

const launch = parseArgs(process.argv);
if (launch.dev) app.setPath('userData', path.join(app.getPath('temp'), 'hdl-simulator-dev-' + process.pid));

// ---------------------------------------------------------------- Single instance

if (!launch.dev && !app.requestSingleInstanceLock()) {
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
    minWidth: 960,
    minHeight: 540,
    show: false,
    backgroundColor: '#1F1F1F',
    title: 'HDL Simulator',
    icon: path.join(__dirname, 'build', 'icon.png'),
    titleBarStyle: 'hidden',
    ...(isMac
      ? { trafficLightPosition: { x: 13, y: 11 } }
      : { titleBarOverlay: { color: '#181818', symbolColor: '#CCCCCC', height: OVERLAY_HEIGHT } }),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      sandbox: false,
      spellcheck: false,
    },
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
      const b = win.getNormalBounds();
      fs.mkdirSync(path.dirname(stateFile()), { recursive: true });
      fs.writeFileSync(stateFile(), JSON.stringify({ ...b, maximized: win.isMaximized() }));
    } catch { /* ignore */ }
  };
  win.on('close', (e) => {
    saveBounds();
    if (allowClose || launch.dev) return;
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
    // Development only: run a script against the page before the snapshot (used for testing).
    if (!app.isPackaged && process.env.HDLS_TEST_JS) {
      setTimeout(() => {
        win.webContents.executeJavaScript(fs.readFileSync(process.env.HDLS_TEST_JS, 'utf8'))
          .then((r) => console.log('[test]', typeof r === 'string' ? r : JSON.stringify(r)))
          .catch((err) => console.log('[test] error', err.message));
      }, Math.max(500, launch.wait * 1000 - 1500));
    }
    setTimeout(async () => {
      const img = await win.webContents.capturePage();
      fs.writeFileSync(launch.snapshot, img.toPNG());
      allowClose = true;
      app.quit();
    }, launch.wait * 1000);
  }
}

function buildMenu() {
  if (!isMac) { Menu.setApplicationMenu(null); return; }
  // macOS (development only): keep Edit so copy/paste shortcuts reach text fields.
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

// ---------------------------------------------------------------- IPC

ipcMain.on('get-launch-sync', (e) => {
  e.returnValue = {
    ...launch,
    files: [...launch.files, ...pendingFiles.splice(0)],
    platform: process.platform,
    version: app.getVersion(),
    userData: app.getPath('userData'),
    documents: app.getPath('documents'),
    home: app.getPath('home'),
    temp: app.getPath('temp'),
    examples: app.isPackaged ? path.join(process.resourcesPath, 'examples') : path.join(__dirname, 'examples'),
    isPackaged: app.isPackaged,
  };
});

ipcMain.handle('open-dialog', async (_e, opts) => {
  const r = await dialog.showOpenDialog(win, opts);
  return r.canceled ? [] : r.filePaths;
});
ipcMain.on('open-dialog-sync', (e, opts) => {
  const r = dialog.showOpenDialogSync(win, opts);
  e.returnValue = r || [];
});
ipcMain.on('save-dialog-sync', (e, opts) => {
  e.returnValue = dialog.showSaveDialogSync(win, opts) || null;
});
// Message box: returns the index of the chosen button.
ipcMain.on('message-box-sync', (e, opts) => {
  e.returnValue = dialog.showMessageBoxSync(win, { noLink: true, ...opts });
});

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
ipcMain.handle('trash', async (_e, p) => { await shell.trashItem(p); return true; });

// HDL Viewer: the installed app if present, else whatever opens .vcd files.
// Returns { exe, args } (args go before the file) or null.
function onPath(name) {
  for (const d of (process.env.PATH || '').split(path.delimiter).filter(Boolean)) {
    const p = path.join(d, name);
    try { fs.accessSync(p, fs.constants.X_OK); if (fs.statSync(p).isFile()) return p; } catch { /* next */ }
  }
  return null;
}
function viewerCommand() {
  if (isWin) {
    const candidates = [];
    const local = process.env.LOCALAPPDATA || path.join(app.getPath('home'), 'AppData', 'Local');
    candidates.push(path.join(local, 'Programs', 'HDL Viewer', 'HDL Viewer.exe'));
    for (const pf of [process.env.ProgramFiles, process.env['ProgramFiles(x86)']].filter(Boolean)) {
      candidates.push(path.join(pf, 'HDL Viewer', 'HDL Viewer.exe'));
    }
    if (app.isPackaged) candidates.push(path.join(path.dirname(process.execPath), '..', 'HDL Viewer', 'HDL Viewer.exe'));
    const exe = candidates.find(exists);
    return exe ? { exe, args: [] } : null;
  }
  if (isMac) {
    const exe = ['/Applications', path.join(app.getPath('home'), 'Applications')].map((d) => path.join(d, 'HDL Viewer.app')).find(exists);
    return exe ? { exe: 'open', args: ['-a', exe], label: exe } : null;
  }
  // Linux: $HDL_VIEWER, the launcher that build_app.sh --install puts in ~/.local/bin, a .deb install
  // in /opt, the unpacked app next to this one, then (running from source) ../HDLViewer with this Electron.
  const home = app.getPath('home');
  const env = process.env.HDL_VIEWER;
  if (env && exists(env)) return { exe: env, args: [] };
  const launcher = onPath('hdl-viewer') || [path.join(home, '.local', 'bin', 'hdl-viewer')].find(exists);
  if (launcher) return { exe: launcher, args: [] };
  for (const p of ['/opt/HDL Viewer/hdl-viewer', path.join(home, '.local', 'opt', 'hdl-viewer', 'hdl-viewer')]) {
    if (exists(p)) return { exe: p, args: ['--no-sandbox'] };
  }
  if (app.isPackaged) {
    const sib = path.join(path.dirname(process.execPath), '..', 'hdl-viewer', 'hdl-viewer');
    if (exists(sib)) return { exe: sib, args: ['--no-sandbox'] };
  } else {
    const src = path.join(__dirname, '..', 'HDLViewer');
    if (exists(path.join(src, 'main.js'))) return { exe: process.execPath, args: [src, ...sandboxArgs()], label: src };
  }
  return null;
}
// Pass --no-sandbox on to a child Electron when this one runs without the sandbox.
function sandboxArgs() { return app.commandLine.hasSwitch('no-sandbox') ? ['--no-sandbox'] : []; }
function viewerExe() { const c = viewerCommand(); return c ? (c.label || c.exe) : null; }
ipcMain.on('viewer-path-sync', (e) => { e.returnValue = viewerExe(); });
ipcMain.handle('open-in-viewer', (_e, file) => {
  const c = viewerCommand();
  try {
    if (c) {
      spawn(c.exe, [...c.args, file], { detached: true, stdio: 'ignore' }).unref();
      return true;
    }
  } catch { /* fall through */ }
  shell.openPath(file);
  return !!c;
});

// HDLPhy (Linux): synthesis and place-and-route of the open design on SKY130.
function hdlphyCommand() {
  if (process.platform !== 'linux') return null;
  const home = app.getPath('home');
  const env = process.env.HDLPHY;
  if (env && exists(env)) return { exe: env, args: [] };
  const launcher = onPath('hdl-phy') || [path.join(home, '.local', 'bin', 'hdl-phy')].find(exists);
  if (launcher) return { exe: launcher, args: [] };
  for (const p of ['/opt/HDLPhy/hdl-phy', path.join(home, '.local', 'opt', 'hdl-phy', 'hdl-phy')]) {
    if (exists(p)) return { exe: p, args: ['--no-sandbox'] };
  }
  if (!app.isPackaged) {
    const src = path.join(__dirname, '..', 'HDLPhy');
    if (exists(path.join(src, 'main.js'))) return { exe: process.execPath, args: [src, ...sandboxArgs()], label: src };
  }
  return null;
}
ipcMain.on('hdlphy-path-sync', (e) => { const c = hdlphyCommand(); e.returnValue = c ? (c.label || c.exe) : null; });
ipcMain.handle('open-in-hdlphy', (_e, paths) => {
  const c = hdlphyCommand();
  if (!c) return false;
  try { spawn(c.exe, [...c.args, ...paths], { detached: true, stdio: 'ignore' }).unref(); return true; } catch { return false; }
});

// Native popup menus described by the renderer. Resolves with the chosen item id (or null).
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
  const menu = Menu.buildFromTemplate(build(items));
  menu.popup({
    window: win,
    ...(pos ? { x: Math.round(pos.x), y: Math.round(pos.y) } : {}),
    callback: () => setTimeout(() => finish(null), 50),
  });
}));
