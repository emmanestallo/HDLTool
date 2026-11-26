'use strict';
/* global Host, PathUtil, Prefs, IS_WIN, IS_MAC, Paths, newUUID */
// Finds the simulators and linters, checks files, runs simulations. Port of Toolchain.swift.

const Tools = {
  iverilog: null, vvp: null, iverilogVersion: null, verilator: null, ghdl: null, checked: false,
  listeners: [],
  onChange(fn) { this.listeners.push(fn); },
  changed() { for (const l of this.listeners) l(); },

  searchDirs() {
    const home = Host.launch.home;
    if (IS_MAC) return ['/opt/homebrew/bin', '/usr/local/bin', '/opt/local/bin', '/usr/bin', PathUtil.join(home, '.local', 'bin')];
    if (!IS_WIN) {
      // Linux: distribution packages, ~/.local, the OSS CAD Suite and the OpenSourceICD tools in ~/eda/tools.
      return ['/usr/bin', '/usr/local/bin', PathUtil.join(home, '.local', 'bin'),
        PathUtil.join(home, 'oss-cad-suite', 'bin'), '/opt/oss-cad-suite/bin',
        PathUtil.join(home, 'eda', 'tools', 'iverilog', 'bin'), PathUtil.join(home, 'eda', 'tools', 'verilator', 'bin'),
        PathUtil.join(home, 'eda', 'tools', 'ghdl', 'bin'), '/snap/bin'];
    }
    const sys = Host.env.SystemDrive || 'C:';
    const winHome = Host.env.USERPROFILE || home;
    const pf = [Host.env.ProgramFiles, Host.env.ProgramW6432, sys + '\\Program Files', sys + '\\Program Files (x86)'].filter(Boolean);
    const dirs = [
      sys + '\\iverilog\\bin', ...pf.map((p) => p + '\\iverilog\\bin'), winHome + '\\iverilog\\bin',
      sys + '\\oss-cad-suite\\bin', winHome + '\\oss-cad-suite\\bin', winHome + '\\Downloads\\oss-cad-suite\\bin',
      sys + '\\ghdl\\bin', ...pf.map((p) => p + '\\ghdl\\bin'),
      sys + '\\msys64\\ucrt64\\bin', sys + '\\msys64\\mingw64\\bin', sys + '\\msys64\\clang64\\bin', sys + '\\msys64\\usr\\bin',
      winHome + '\\scoop\\shims', sys + '\\ProgramData\\chocolatey\\bin',
    ];
    return [...new Set(dirs)];
  },

  detect() {
    const dirs = this.searchDirs();
    this.iverilog = Host.proc.find('iverilog', Prefs.get('iverilogPath'), dirs);
    if (this.iverilog) {
      const v = PathUtil.join(PathUtil.dirname(this.iverilog), IS_WIN ? 'vvp.exe' : 'vvp');
      this.vvp = Host.fs.exists(v) ? v : Host.proc.find('vvp', null, dirs);
    } else this.vvp = null;
    this.verilator = Host.proc.find('verilator', Prefs.get('verilatorPath'), dirs) || (IS_WIN ? Host.proc.find('verilator_bin', Prefs.get('verilatorPath'), dirs) : null);
    this.ghdl = Host.proc.find('ghdl', Prefs.get('ghdlPath'), dirs);
    this.iverilogVersion = null;
    this.checked = true;
    this.changed();
    if (this.iverilog) {
      const iv = this.iverilog;
      Host.proc.capture(iv, ['-V'], undefined, 5000).then((out) => {
        if (iv !== this.iverilog) return;
        const first = (out.split('\n')[0] || '');
        const m = /version (\S+)/.exec(first);
        this.iverilogVersion = m ? m[1] : '?';
        this.changed();
      });
    }
  },
  installHint() {
    return IS_WIN ? 'Install Icarus Verilog for Windows (bleyer.org/icarus) or the OSS CAD Suite, then press Detect Again in Settings.'
      : IS_MAC ? 'Install it with:  brew install icarus-verilog' : 'Install it with:  sudo apt install iverilog   (or unpack the OSS CAD Suite into ~/oss-cad-suite)';
  },
};

// ---------------------------------------------------------------- Linting

const Linter = {
  kinds: [['auto', 'Automatic'], ['iverilog', 'Icarus Verilog'], ['verilator', 'Verilator'], ['off', 'Off']],

  tempRoot() { return PathUtil.join(Host.launch.temp, 'HDLSimulator', 'lint'); },

  // job: { key, fileName, text, originalPath, language, deps, includeDirs, iverilog, verilator, ghdl, kind, standard }
  async run(job) {
    const dir = PathUtil.join(Linter.tempRoot(), newUUID());
    Host.fs.mkdir(dir);
    const tmp = PathUtil.join(dir, job.fileName);
    if (Host.fs.writeText(tmp, job.text) != null) return null;
    const map = new Map();
    const norm = (p) => { const n = PathUtil.normalize(p); return IS_WIN ? n.toLowerCase() : n; };
    map.set(norm(tmp), job.key);
    const real = Host.fs.realpath(tmp);
    if (real) map.set(norm(real), job.key);
    if (job.originalPath) map.set(norm(job.originalPath), job.key);
    const mapPath = (p) => map.get(norm(p)) || map.get(norm(PathUtil.resolve(dir, p))) || PathUtil.normalize(p);
    try {
      if (job.language === 'vhdl') {
        if (!job.ghdl || job.kind === 'off') return null;
        const out = await Host.proc.capture(job.ghdl, ['-s', '--std=08', '-fsynopsys', tmp], dir, 20000);
        return { key: job.key, diagnostics: Linter.parseGHDL(out, mapPath), tool: 'ghdl' };
      }
      let kind = job.kind;
      if (kind === 'auto') kind = job.iverilog ? 'iverilog' : (job.verilator ? 'verilator' : 'off');
      if (kind === 'verilator') {
        if (!job.verilator) return null;
        const args = ['--lint-only', '-Wall', '-Wno-DECLFILENAME', '-Wno-MULTITOP', '-Wno-EOFNEWLINE', '--timing'];
        if (job.language === 'systemVerilog' || job.fileName.endsWith('.sv')) args.push('-sv');
        for (const d of job.includeDirs) args.push('-I' + d);
        args.push(tmp, ...job.deps);
        const out = await Host.proc.capture(job.verilator, args, dir, 30000);
        return { key: job.key, diagnostics: Linter.parseVerilator(out, mapPath), tool: 'verilator' };
      }
      if (kind === 'iverilog') {
        if (!job.iverilog) return null;
        const args = [job.standard, '-Wall', '-Wno-timescale', '-Wno-implicit-dimensions', '-t', 'null'];
        for (const d of job.includeDirs) args.push('-I', d);
        args.push(tmp, ...job.deps);
        const out = await Host.proc.capture(job.iverilog, args, dir, 30000);
        return { key: job.key, diagnostics: Linter.parseIverilog(out, mapPath), tool: 'iverilog' };
      }
      return null;
    } finally {
      Host.fs.remove(tmp);
      Host.fs.remove(dir);
    }
  },

  parseIverilog(out, mapPath) {
    const diags = [];
    for (const line of out.split(/\r?\n/)) {
      const m = /^(.+?):(\d+):\s*(.*)$/.exec(line);
      if (!m) continue;
      const path = m[1];
      if (!(path.includes('/') || path.includes('\\') || path.includes('.')) || path.startsWith(' ')) continue;
      const ln = parseInt(m[2], 10) || 1;
      let msg = m[3].trim();
      let sev = 'error';
      const lower = msg.toLowerCase();
      if (lower.startsWith('error:')) msg = msg.slice(6).trim();
      else if (lower.startsWith('warning:')) { sev = 'warning'; msg = msg.slice(8).trim(); }
      else if (lower.startsWith('sorry:')) { sev = 'warning'; msg = 'Not supported by Icarus: ' + msg.slice(6).trim(); }
      else if (lower.startsWith('syntax error')) msg = 'Syntax error';
      else if (lower.startsWith(':') || !lower) { sev = 'info'; msg = msg.replace(/^[: ]+/, ''); if (!msg) continue; }
      else if (lower.includes('warning')) sev = 'warning';
      const file = mapPath(path);
      const last = diags[diags.length - 1];
      if (last && last.file === file && last.line === ln && last.message === 'Syntax error' && sev === 'error') { last.message = 'Syntax error: ' + msg; continue; }
      if (!diags.some((d) => d.file === file && d.line === ln && d.message === msg)) diags.push({ file, line: ln, column: null, severity: sev, message: msg, source: 'iverilog' });
    }
    return diags;
  },
  parseVerilator(out, mapPath) {
    const diags = [];
    for (const line of out.split(/\r?\n/)) {
      const m = /^%(Error|Warning)(-[A-Z0-9_]+)?: (.+?):(\d+):(?:(\d+):)? (.*)$/.exec(line);
      if (!m) continue;
      const code = m[2] ? m[2].slice(1) : '';
      diags.push({ file: mapPath(m[3]), line: parseInt(m[4], 10) || 1, column: m[5] ? parseInt(m[5], 10) : null,
        severity: m[1] === 'Error' ? 'error' : 'warning', message: m[6] + (code ? `  [${code}]` : ''), source: 'verilator' });
    }
    return diags;
  },
  parseGHDL(out, mapPath) {
    const diags = [];
    for (const line of out.split(/\r?\n/)) {
      const m = /^(.+?):(\d+):(\d+):\s*(?:(error|warning|note):)?\s*(.*)$/.exec(line);
      if (!m) continue;
      const kind = m[4] || 'error';
      diags.push({ file: mapPath(m[1]), line: parseInt(m[2], 10) || 1, column: parseInt(m[3], 10) || null,
        severity: kind === 'warning' ? 'warning' : kind === 'note' ? 'info' : 'error', message: m[5], source: 'ghdl' });
    }
    return diags;
  },
};

// ---------------------------------------------------------------- Running processes with line output

// Runs a tool, sending whole output lines to onLine. Returns { promise, id }.
function execLines(exe, args, cwd, onLine) {
  let carry = '';
  let id = null;
  const promise = new Promise((resolve) => {
    id = Host.proc.run(exe, args, cwd, (text) => {
      carry += text.replace(/\r\n/g, '\n');
      const lines = carry.split('\n');
      carry = lines.pop();
      for (const l of lines) onLine(l);
    }, (code) => {
      if (carry) onLine(carry);
      carry = '';
      resolve(code);
    });
  });
  return { promise, id };
}

function shellQuote(s) {
  if (/^[\p{L}\p{N}\-_./=:+,\\]+$/u.test(s)) return s;
  return IS_WIN ? '"' + s.replace(/"/g, '\\"') + '"' : "'" + s.replace(/'/g, "'\\''") + "'";
}

const Viewer = {
  path() { return Host.viewerPath(); },
  open(p) { Host.openInViewer(p); },
};

if (typeof module !== 'undefined') module.exports = { Tools, Linter, execLines, shellQuote, Viewer };
