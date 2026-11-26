'use strict';

// Color tokens named after VS Code's theme keys. Same palettes as the Mac app.
const DARK_PALETTE = [
  ['Teal', '#4EC9B0'], ['Blue', '#4FC1FF'], ['Green', '#89D185'], ['Yellow', '#DCDCAA'],
  ['Orange', '#CE9178'], ['Red', '#F48771'], ['Purple', '#C586C0'], ['White', '#D4D4D4'],
];

const THEMES = {
  darkModern: {
    name: 'Dark Modern', dark: true,
    titleBar: '#181818', titleFG: '#CCCCCC', activityBar: '#181818', activityFG: '#D7D7D7',
    activityInactiveFG: '#868686', activityActiveBorder: '#0078D4', sidebar: '#181818', sidebarFG: '#CCCCCC',
    editor: '#1F1F1F', fg: '#CCCCCC', dimFG: '#8B8B8B', border: '#2B2B2B', rowSeparator: 'rgba(255,255,255,0.035)',
    tabBar: '#181818', tabActive: '#1F1F1F', tabInactive: '#181818', tabActiveFG: '#FFFFFF', tabInactiveFG: '#9D9D9D',
    tabActiveBorder: '#0078D4', statusBar: '#181818', statusFG: '#CCCCCC', statusAccent: '#0078D4', statusAccentFG: '#FFFFFF',
    listSelection: '#04395E', listHover: '#2A2D2E', inputBG: '#313131', inputBorder: '#3C3C3C', focusBorder: '#0078D4',
    accent: '#0078D4', buttonBG: '#0078D4', buttonFG: '#FFFFFF', menuBG: '#1F1F1F',
    wave1: '#4EC9B0', waveBus: '#4FC1FF', waveX: '#F14C4C', waveZ: '#CCA700', waveText: '#E0E0E0', valueFG: '#B5CEA8',
    waveRowSelected: 'rgba(255,255,255,0.04)', cursor: '#3794FF', marker: '#C586C0', hoverLine: 'rgba(255,255,255,0.18)',
    grid: 'rgba(255,255,255,0.045)', rulerBG: '#181818', rulerFG: '#9D9D9D', endShade: 'rgba(0,0,0,0.18)',
    scrollbar: 'rgba(121,121,121,0.4)',
    palette: DARK_PALETTE,
  },
  darkPlus: {
    name: 'Dark+', dark: true,
    titleBar: '#3C3C3C', titleFG: '#CCCCCC', activityBar: '#333333', activityFG: '#FFFFFF',
    activityInactiveFG: '#858585', activityActiveBorder: '#FFFFFF', sidebar: '#252526', sidebarFG: '#CCCCCC',
    editor: '#1E1E1E', fg: '#D4D4D4', dimFG: '#8B8B8B', border: '#3C3C3C', rowSeparator: 'rgba(255,255,255,0.035)',
    tabBar: '#252526', tabActive: '#1E1E1E', tabInactive: '#2D2D2D', tabActiveFG: '#FFFFFF', tabInactiveFG: '#969696',
    tabActiveBorder: '#1E1E1E', statusBar: '#007ACC', statusFG: '#FFFFFF', statusAccent: '#16825D', statusAccentFG: '#FFFFFF',
    listSelection: '#094771', listHover: '#2A2D2E', inputBG: '#3C3C3C', inputBorder: '#3C3C3C', focusBorder: '#007FD4',
    accent: '#007ACC', buttonBG: '#0E639C', buttonFG: '#FFFFFF', menuBG: '#252526',
    wave1: '#6A9955', waveBus: '#569CD6', waveX: '#F44747', waveZ: '#D7BA7D', waveText: '#D4D4D4', valueFG: '#B5CEA8',
    waveRowSelected: 'rgba(255,255,255,0.04)', cursor: '#DCDCAA', marker: '#C586C0', hoverLine: 'rgba(255,255,255,0.18)',
    grid: 'rgba(255,255,255,0.045)', rulerBG: '#252526', rulerFG: '#969696', endShade: 'rgba(0,0,0,0.18)',
    scrollbar: 'rgba(121,121,121,0.4)',
    palette: DARK_PALETTE,
  },
  lightModern: {
    name: 'Light Modern', dark: false,
    titleBar: '#F8F8F8', titleFG: '#1E1E1E', activityBar: '#F8F8F8', activityFG: '#1F1F1F',
    activityInactiveFG: '#616161', activityActiveBorder: '#005FB8', sidebar: '#F8F8F8', sidebarFG: '#3B3B3B',
    editor: '#FFFFFF', fg: '#3B3B3B', dimFG: '#868686', border: '#E5E5E5', rowSeparator: 'rgba(0,0,0,0.04)',
    tabBar: '#F8F8F8', tabActive: '#FFFFFF', tabInactive: '#F8F8F8', tabActiveFG: '#3B3B3B', tabInactiveFG: '#868686',
    tabActiveBorder: '#005FB8', statusBar: '#F8F8F8', statusFG: '#3B3B3B', statusAccent: '#005FB8', statusAccentFG: '#FFFFFF',
    listSelection: '#E8E8E8', listHover: '#F2F2F2', inputBG: '#FFFFFF', inputBorder: '#CECECE', focusBorder: '#005FB8',
    accent: '#005FB8', buttonBG: '#005FB8', buttonFG: '#FFFFFF', menuBG: '#FFFFFF',
    wave1: '#16825D', waveBus: '#0451A5', waveX: '#E51400', waveZ: '#BF8803', waveText: '#1F1F1F', valueFG: '#098658',
    waveRowSelected: 'rgba(0,0,0,0.035)', cursor: '#005FB8', marker: '#AF00DB', hoverLine: 'rgba(0,0,0,0.18)',
    grid: 'rgba(0,0,0,0.05)', rulerBG: '#F8F8F8', rulerFG: '#616161', endShade: 'rgba(0,0,0,0.03)',
    scrollbar: 'rgba(100,100,100,0.4)',
    palette: [
      ['Teal', '#16825D'], ['Blue', '#0451A5'], ['Green', '#388A34'], ['Yellow', '#8A6D00'],
      ['Orange', '#C2410C'], ['Red', '#CD3131'], ['Purple', '#AF00DB'], ['Black', '#1F1F1F'],
    ],
  },
};

function scopeColor(theme, kind) {
  if (kind === 'module') return theme.dark ? '#EE9D28' : '#D67E00';
  if (kind === 'task' || kind === 'function') return theme.dark ? '#B180D7' : '#652D90';
  return theme.dark ? '#75BEFF' : '#007ACC';
}

function varColor(theme, kind) {
  if (['reg', 'logic', 'bit'].includes(kind)) return theme.dark ? '#EE9D28' : '#D67E00';
  if (['integer', 'int', 'longint', 'shortint', 'byte'].includes(kind)) return theme.dark ? '#B180D7' : '#652D90';
  if (['real', 'realtime', 'shortreal'].includes(kind)) return theme.dark ? '#D16969' : '#A31515';
  if (kind === 'parameter') return theme.dark ? '#4EC9B0' : '#267F99';
  return theme.dark ? '#75BEFF' : '#007ACC';
}

function varLetter(kind) {
  if (['wire', 'tri', 'wand', 'wor', 'supply0', 'supply1', 'tri0', 'tri1'].includes(kind)) return 'w';
  if (['reg', 'logic', 'bit'].includes(kind)) return 'r';
  if (['integer', 'int', 'longint', 'shortint', 'byte'].includes(kind)) return 'i';
  if (['real', 'realtime', 'shortreal'].includes(kind)) return 'f';
  if (kind === 'parameter') return 'p';
  if (kind === 'event') return 'e';
  if (kind === 'string') return 's';
  return kind.slice(0, 1);
}
