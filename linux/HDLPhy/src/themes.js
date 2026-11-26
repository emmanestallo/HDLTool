'use strict';
// Color tokens named after VS Code's theme keys — same values as the Mac apps (Coder, Tester and Viewer).

const THEMES = {
  darkModern: {
    id: 'darkModern', name: 'Dark Modern', dark: true,
    titleBar: '#181818', titleFG: '#CCCCCC', activityBar: '#181818', activityFG: '#D7D7D7',
    activityInactiveFG: '#868686', activityActiveBorder: '#0078D4', sidebar: '#181818', sidebarFG: '#CCCCCC',
    editor: '#1F1F1F', fg: '#CCCCCC', dimFG: '#8B8B8B', border: '#2B2B2B',
    tabBar: '#181818', tabActive: '#1F1F1F', tabInactive: '#181818', tabActiveFG: '#FFFFFF', tabInactiveFG: '#9D9D9D', tabActiveBorder: '#0078D4',
    statusBar: '#181818', statusFG: '#CCCCCC', statusAccent: '#0078D4', statusAccentFG: '#FFFFFF',
    listSelection: '#04395E', listHover: '#2A2D2E', inputBG: '#313131', inputBorder: '#3C3C3C', focusBorder: '#0078D4',
    accent: '#0078D4', buttonBG: '#0078D4', buttonFG: '#FFFFFF', secondaryButtonBG: '#313131', secondaryButtonFG: '#CCCCCC',
    widgetBG: '#202020', widgetBorder: '#454545',
    error: '#F14C4C', warning: '#CCA700', success: '#89D185', info: '#3794FF',
    editorFG: '#CCCCCC', selection: '#264F78', lineHighlight: 'rgba(255,255,255,0.045)', gutterFG: '#6E7681', gutterActiveFG: '#CCCCCC',
    caret: '#AEAFAD', indentGuide: 'rgba(255,255,255,0.07)',
    canvasDot: 'rgba(255,255,255,0.09)', blockBG: '#252526', blockHeader: '#2D2D30', blockBorder: '#454545', pin: '#8B8B8B',
    wave1: '#4EC9B0', waveBus: '#4FC1FF', waveX: '#F14C4C', waveZ: '#CCA700', valueFG: '#B5CEA8',
  },
  darkPlus: {
    id: 'darkPlus', name: 'Dark+', dark: true,
    titleBar: '#3C3C3C', titleFG: '#CCCCCC', activityBar: '#333333', activityFG: '#FFFFFF',
    activityInactiveFG: '#858585', activityActiveBorder: '#FFFFFF', sidebar: '#252526', sidebarFG: '#CCCCCC',
    editor: '#1E1E1E', fg: '#D4D4D4', dimFG: '#8B8B8B', border: '#3C3C3C',
    tabBar: '#252526', tabActive: '#1E1E1E', tabInactive: '#2D2D2D', tabActiveFG: '#FFFFFF', tabInactiveFG: '#969696', tabActiveBorder: '#1E1E1E',
    statusBar: '#007ACC', statusFG: '#FFFFFF', statusAccent: '#16825D', statusAccentFG: '#FFFFFF',
    listSelection: '#094771', listHover: '#2A2D2E', inputBG: '#3C3C3C', inputBorder: '#3C3C3C', focusBorder: '#007FD4',
    accent: '#007ACC', buttonBG: '#0E639C', buttonFG: '#FFFFFF', secondaryButtonBG: '#3A3D41', secondaryButtonFG: '#CCCCCC',
    widgetBG: '#252526', widgetBorder: '#454545',
    error: '#F44747', warning: '#CCA700', success: '#89D185', info: '#3794FF',
    editorFG: '#D4D4D4', selection: '#264F78', lineHighlight: 'rgba(255,255,255,0.04)', gutterFG: '#858585', gutterActiveFG: '#C6C6C6',
    caret: '#AEAFAD', indentGuide: 'rgba(255,255,255,0.08)',
    canvasDot: 'rgba(255,255,255,0.09)', blockBG: '#252526', blockHeader: '#333333', blockBorder: '#4A4A4A', pin: '#8B8B8B',
    wave1: '#6A9955', waveBus: '#569CD6', waveX: '#F44747', waveZ: '#D7BA7D', valueFG: '#B5CEA8',
  },
  lightModern: {
    id: 'lightModern', name: 'Light Modern', dark: false,
    titleBar: '#F8F8F8', titleFG: '#1E1E1E', activityBar: '#F8F8F8', activityFG: '#1F1F1F',
    activityInactiveFG: '#616161', activityActiveBorder: '#005FB8', sidebar: '#F8F8F8', sidebarFG: '#3B3B3B',
    editor: '#FFFFFF', fg: '#3B3B3B', dimFG: '#868686', border: '#E5E5E5',
    tabBar: '#F8F8F8', tabActive: '#FFFFFF', tabInactive: '#F8F8F8', tabActiveFG: '#3B3B3B', tabInactiveFG: '#868686', tabActiveBorder: '#005FB8',
    statusBar: '#F8F8F8', statusFG: '#3B3B3B', statusAccent: '#005FB8', statusAccentFG: '#FFFFFF',
    listSelection: '#E8E8E8', listHover: '#F2F2F2', inputBG: '#FFFFFF', inputBorder: '#CECECE', focusBorder: '#005FB8',
    accent: '#005FB8', buttonBG: '#005FB8', buttonFG: '#FFFFFF', secondaryButtonBG: '#E5E5E5', secondaryButtonFG: '#3B3B3B',
    widgetBG: '#F8F8F8', widgetBorder: '#C8C8C8',
    error: '#E51400', warning: '#BF8803', success: '#388A34', info: '#1A85FF',
    editorFG: '#3B3B3B', selection: '#ADD6FF', lineHighlight: 'rgba(0,0,0,0.04)', gutterFG: '#6E7681', gutterActiveFG: '#171184',
    caret: '#000000', indentGuide: 'rgba(0,0,0,0.1)',
    canvasDot: 'rgba(0,0,0,0.12)', blockBG: '#FFFFFF', blockHeader: '#F3F3F3', blockBorder: '#C8C8C8', pin: '#868686',
    wave1: '#16825D', waveBus: '#0451A5', waveX: '#E51400', waveZ: '#BF8803', valueFG: '#098658',
  },
};

const Syntax = {
  colors(t) {
    const d = t.dark;
    return {
      keyword: d ? '#569CD6' : '#0000FF', control: d ? '#C586C0' : '#AF00DB', type: d ? '#4EC9B0' : '#267F99',
      comment: d ? '#6A9955' : '#008000', number: d ? '#B5CEA8' : '#098658', string: d ? '#CE9178' : '#A31515',
      system: d ? '#DCDCAA' : '#795E26', directive: d ? '#C586C0' : '#AF00DB', ident: d ? '#9CDCFE' : '#001080',
    };
  },
};

function dirColor(t, d) {
  if (d === 'input' || d === 'in') return t.dark ? '#75BEFF' : '#007ACC';
  if (d === 'output' || d === 'out' || d === 'buffer') return t.dark ? '#EE9D28' : '#D67E00';
  return t.dark ? '#B180D7' : '#652D90';
}

function symbolColor(t, k) {
  const d = t.dark;
  switch (k) {
    case 'module': case 'entity': case 'interface': case 'program': case 'klass': case 'package': case 'architecture': case 'component':
      return d ? '#EE9D28' : '#D67E00';
    case 'function': case 'task': return d ? '#B180D7' : '#652D90';
    case 'port': case 'signal': return d ? '#75BEFF' : '#007ACC';
    case 'param': case 'constant': return d ? '#4FC1FF' : '#0070C1';
    case 'instance': case 'type': return d ? '#4EC9B0' : '#267F99';
    case 'process': return d ? '#C586C0' : '#AF00DB';
    default: return t.dimFG;
  }
}

function stimColor(t, k) {
  switch (k) {
    case 'constant': return t.dark ? '#A0A0A0' : '#6E6E6E';
    case 'clock': return t.wave1;
    case 'sequence': return t.waveBus;
    case 'bitstream': return t.dark ? '#C586C0' : '#AF00DB';
    case 'counter': return t.dark ? '#CE9178' : '#C2410C';
    default: return t.dark ? '#DCDCAA' : '#8A6D00';
  }
}

// File icon (codicon name) and color for a file name.
function fileStyle(t, name) {
  const ext = (/\.([^.\\/]+)$/.exec(name) || [])[1];
  const e = (ext || '').toLowerCase();
  const d = t.dark;
  if (['v', 'vh', 'vlog'].includes(e)) return ['code', d ? '#4FC1FF' : '#0070C1'];
  if (['sv', 'svh'].includes(e)) return ['code', d ? '#4EC9B0' : '#267F99'];
  if (['vhd', 'vhdl'].includes(e)) return ['bracket', d ? '#C586C0' : '#AF00DB'];
  if (['vcd', 'fst', 'ghw'].includes(e)) return ['pulse', d ? '#DCDCAA' : '#795E26'];
  if (e === 'hdltest') return ['beaker', d ? '#89D185' : '#388A34'];
  if (['xdc', 'sdc', 'ucf', 'pcf', 'lpf', 'qsf'].includes(e)) return ['pin', d ? '#EE9D28' : '#D67E00'];
  if (['tcl', 'sh', 'py', 'do', 'mk', 'bat', 'ps1'].includes(e)) return ['terminal', t.dimFG];
  if (['mem', 'hex', 'coe', 'mif'].includes(e)) return ['server', t.dimFG];
  if (['md', 'txt'].includes(e)) return ['file-text', t.dimFG];
  if (name === 'Makefile') return ['tools', t.dimFG];
  return ['file', t.dimFG];
}

function withAlpha(hex, a) {
  if (!hex.startsWith('#')) return hex;
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
}

if (typeof module !== 'undefined') module.exports = { THEMES, Syntax, dirColor, symbolColor, stimColor, fileStyle, withAlpha };
