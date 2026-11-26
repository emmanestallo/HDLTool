'use strict';
const { contextBridge, ipcRenderer, webUtils } = require('electron');

contextBridge.exposeInMainWorld('host', {
  getLaunch: () => ipcRenderer.invoke('get-launch'),
  openDialog: () => ipcRenderer.invoke('open-dialog'),
  readFile: (p) => ipcRenderer.invoke('read-file', p),
  fileExists: (p) => ipcRenderer.invoke('file-exists', p),
  watch: (p, mtime) => ipcRenderer.invoke('watch', p, mtime),
  setMtime: (p, mtime) => ipcRenderer.invoke('set-mtime', p, mtime),
  unwatch: (p) => ipcRenderer.invoke('unwatch', p),
  setTheme: (t) => ipcRenderer.invoke('set-theme', t),
  setTitle: (t) => ipcRenderer.invoke('set-title', t),
  popupMenu: (items, pos) => ipcRenderer.invoke('popup-menu', items, pos),
  pathForFile: (file) => webUtils.getPathForFile(file),
  onOpenFiles: (cb) => ipcRenderer.on('open-files', (_e, files) => cb(files)),
  onFileChanged: (cb) => ipcRenderer.on('file-changed', (_e, p) => cb(p)),
});
