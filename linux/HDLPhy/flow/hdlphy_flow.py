#!/usr/bin/env python3
"""HDLPhy flow: RTL -> SKY130 gate netlist -> placed and routed layout -> GDS.

Stages (each one reads the previous stage's result from <run>/results):
  synth      yosys: RTL view (rtl.json), gate-level netlist (netlist.v, gate.json), area report
  floorplan  OpenROAD: die/core, rows, tracks, tap cells, power grid
  place      OpenROAD: global placement, I/O pins, buffering, detailed placement
  cts        OpenROAD: clock tree (skipped when the design has no clock), hold repair
  route      OpenROAD: global + detailed routing, filler cells, timing/area/power reports
  gds        KLayout: DEF + cell GDS -> final.gds, plus the geometry file the Layout tab draws

Usage:
  hdlphy_flow.py run CONFIG.json [--from STAGE] [--to STAGE]
  hdlphy_flow.py view CONFIG.json STAGE     # layout view of an intermediate stage (floorplan/place/cts/route)
  hdlphy_flow.py check [CONFIG.json]        # tools and PDK files that would be used (JSON)
  hdlphy_flow.py example OUT_DIR            # writes a config for examples/counter.v

Progress goes to stdout as lines starting with '##HDLPHY ' followed by one JSON object, so the
app can follow the run; everything else is the tools' own output.
Only the Python standard library is used.
"""
import fnmatch
import glob
import gzip
import json
import math
import os
import re
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(HERE, 'scripts')
KLAYOUT_SCRIPTS = os.path.join(HERE, 'klayout')
STAGES = ['synth', 'floorplan', 'place', 'cts', 'route', 'gds']
STAGE_TITLES = {'synth': 'Synthesis', 'floorplan': 'Floorplan', 'place': 'Placement', 'cts': 'Clock Tree',
                'route': 'Routing', 'gds': 'GDS'}
HOME = os.path.expanduser('~')

DEFAULTS = {
    'design': None, 'top': None, 'sources': [], 'include_dirs': [], 'defines': {}, 'params': {},
    'clock_port': 'clk', 'clock_period_ns': 10.0,
    'utilization': 40.0, 'aspect_ratio': 1.0, 'core_margin_um': 5.0, 'min_core_um': 30.0,
    'place_density': 0.6, 'flatten': True,
    # die edge for the I/O pins: 'any' (the pin placer chooses), 'left', 'right', 'top' or 'bottom';
    # the clock can also follow the inputs ('inputs')
    'pin_input_side': 'any', 'pin_output_side': 'any', 'pin_clock_side': 'inputs',
    # bus pins: 'free' (the pin placer orders them), 'ascending' or 'descending' (bits together, in index order)
    'pin_bus_order': 'free',
    'pdk_root': os.environ.get('PDK_ROOT') or os.path.join(HOME, 'eda', 'pdks'),
    'pdk': 'sky130A', 'scl': 'sky130_fd_sc_hd', 'corner': 'tt_025C_1v80',
    'threads': max(1, min(8, os.cpu_count() or 1)),
    'tools': {},
}


# ---------------------------------------------------------------- helpers

def emit(event, **kw):
    kw['event'] = event
    sys.stdout.write('##HDLPHY ' + json.dumps(kw) + '\n')
    sys.stdout.flush()


def die(msg):
    emit('error', message=msg)
    sys.stderr.write('hdlphy: ' + msg + '\n')
    sys.exit(2)


def find_tool(name, cfg):
    """A tool from the config, $HDLPHY_<NAME>, ~/eda/tools, the OSS CAD Suite, then PATH."""
    custom = (cfg.get('tools') or {}).get(name) or os.environ.get('HDLPHY_' + name.upper())
    cands = []
    if custom:
        cands.append(os.path.join(custom, name) if os.path.isdir(custom) else custom)
    if name == 'klayout':
        cands.append('/usr/bin/klayout')   # the plain binary; ~/.local/bin/klayout may be a PDK launcher
    cands += [os.path.join(HOME, 'eda', 'tools', name, 'bin', name),
              os.path.join(HOME, 'oss-cad-suite', 'bin', name), '/opt/oss-cad-suite/bin/' + name]
    for c in cands:
        if c and os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return shutil.which(name)


def pdk_files(cfg):
    pdk = os.path.join(os.path.expanduser(cfg['pdk_root']), cfg['pdk'])
    scl = cfg['scl']
    ref = os.path.join(pdk, 'libs.ref', scl)
    tech = os.path.join(pdk, 'libs.tech')
    f = {
        'pdk_dir': pdk,
        'tech_lef': os.path.join(ref, 'techlef', scl + '__nom.tlef'),
        'cell_lef': os.path.join(ref, 'lef', scl + '.lef'),
        'cell_gds': os.path.join(ref, 'gds', scl + '.gds'),
        'lib_gz': os.path.join(ref, 'lib', '%s__%s.lib.gz' % (scl, cfg['corner'])),
        'lib_plain': os.path.join(ref, 'lib', '%s__%s.lib' % (scl, cfg['corner'])),
        'tracks': os.path.join(tech, 'librelane', scl, 'tracks.info'),
        'synth_excluded': os.path.join(tech, 'librelane', scl, 'synth_excluded.cells'),
        'pnr_excluded': os.path.join(tech, 'librelane', scl, 'pnr_excluded.cells'),
        'latch_map': os.path.join(tech, 'librelane', scl, 'latch_map.v'),
        'tribuf_map': os.path.join(tech, 'librelane', scl, 'tribuff_map.v'),
        'lyp': os.path.join(tech, 'klayout', 'tech', cfg['pdk'] + '.lyp'),
        'lyt': os.path.join(tech, 'klayout', 'tech', cfg['pdk'] + '.lyt'),
        'layer_map': os.path.join(tech, 'klayout', 'tech', cfg['pdk'] + '.map'),
    }
    return f


def read_patterns(path):
    if not os.path.isfile(path):
        return []
    out = []
    for line in open(path):
        line = line.split('#', 1)[0].strip()
        if line:
            out.extend(line.split())
    return out


def load_config(path):
    with open(path) as fh:
        user = json.load(fh)
    cfg = json.loads(json.dumps(DEFAULTS))
    cfg.update({k: v for k, v in user.items() if v is not None})
    cfg['config_path'] = os.path.abspath(path)
    cfg['run_dir'] = os.path.abspath(cfg.get('run_dir') or os.path.dirname(os.path.abspath(path)))
    base = os.path.dirname(cfg['config_path'])
    cfg['sources'] = [os.path.normpath(os.path.join(base, os.path.expanduser(s))) for s in cfg['sources']]
    cfg['include_dirs'] = [os.path.normpath(os.path.join(base, os.path.expanduser(s))) for s in cfg['include_dirs']]
    if not cfg.get('top'):
        die('no top module in the config')
    cfg['design'] = cfg.get('design') or cfg['top']
    return cfg


def paths(cfg):
    run = cfg['run_dir']
    p = {'run': run, 'results': os.path.join(run, 'results'), 'reports': os.path.join(run, 'reports'),
         'logs': os.path.join(run, 'logs'), 'tmp': os.path.join(run, 'tmp')}
    for d in p.values():
        os.makedirs(d, exist_ok=True)
    return p


def plain_liberty(cfg, files, p):
    """OpenROAD and ABC read an uncompressed copy of the corner's liberty file."""
    if os.path.isfile(files['lib_plain']):
        return files['lib_plain']
    out = os.path.join(p['results'], os.path.basename(files['lib_plain']))
    if not os.path.isfile(out) or os.path.getmtime(out) < os.path.getmtime(files['lib_gz']):
        if not os.path.isfile(files['lib_gz']):
            die('liberty file not found: ' + files['lib_gz'])
        with gzip.open(files['lib_gz'], 'rb') as src, open(out + '.tmp', 'wb') as dst:
            shutil.copyfileobj(src, dst)
        os.replace(out + '.tmp', out)
    return out


def run_tool(stage, args, log_path, env=None, cwd=None):
    """Runs a tool, echoing its output and keeping it in the stage log. Returns the exit code."""
    with open(log_path, 'w') as log:
        log.write('$ ' + ' '.join(args) + '\n')
        log.flush()
        try:
            proc = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, cwd=cwd,
                                    bufsize=1, universal_newlines=True, errors='replace')
        except OSError as e:
            log.write(str(e) + '\n')
            emit('log', stage=stage, text='could not start %s: %s' % (args[0], e))
            return 127
        for line in proc.stdout:
            log.write(line)
            sys.stdout.write(line)
        sys.stdout.flush()
        return proc.wait()


def save_metrics(p, stage, values):
    path = os.path.join(p['reports'], 'metrics.json')
    data = {}
    if os.path.isfile(path):
        try:
            data = json.load(open(path))
        except ValueError:
            data = {}
    data.setdefault(stage, {}).update(values)
    with open(path, 'w') as fh:
        json.dump(data, fh, indent=1)
    emit('metrics', stage=stage, values=values)


# ---------------------------------------------------------------- constraints

def write_sdc(cfg, p):
    period = float(cfg['clock_period_ns'])
    clk = (cfg.get('clock_port') or '').strip()
    lines = ['# Written by HDLPhy. Clock period %.4g ns.' % period, 'set period %.6g' % period]
    if clk and cfg.get('has_clock', True):
        lines += ['create_clock -name core_clock -period $period [get_ports {%s}]' % clk,
                  'set inputs [all_inputs -no_clocks]']
    else:
        lines += ['# No clock port: a virtual clock times the input-to-output paths.',
                  'create_clock -name core_clock -period $period',
                  'set inputs [all_inputs]']
    lines += [
        'set_clock_uncertainty 0.25 [all_clocks]',
        'set_input_delay [expr {$period * 0.2}] -clock core_clock $inputs',
        'set_output_delay [expr {$period * 0.2}] -clock core_clock [all_outputs]',
        'set_driving_cell -lib_cell %s__inv_2 -pin Y $inputs' % cfg['scl'],
        'set_load 0.033442 [all_outputs]',
        'set_max_fanout 10 [current_design]',
        'set_max_transition 0.75 [current_design]',
    ]
    path = os.path.join(p['results'], 'constraints.sdc')
    with open(path, 'w') as fh:
        fh.write('\n'.join(lines) + '\n')
    return path


# ---------------------------------------------------------------- synthesis

def has_port(cfg, rtl_json, port):
    try:
        mods = json.load(open(rtl_json))['modules']
    except (OSError, ValueError, KeyError):
        return False
    m = mods.get(cfg['top'])
    return bool(m and port in m.get('ports', {}))


def stage_synth(cfg, files, p, tools):
    yosys = tools['yosys']
    if not yosys:
        die('yosys not found (expected ~/eda/tools/yosys/bin/yosys or on PATH)')
    srcs = cfg['sources']
    if not srcs:
        die('no source files')
    for s in srcs:
        if not os.path.isfile(s):
            die('source file not found: ' + s)
        if s.lower().endswith(('.vhd', '.vhdl')):
            die('VHDL needs the GHDL yosys plugin, which is not installed: ' + os.path.basename(s))
    lib = plain_liberty(cfg, files, p)
    r = p['results']
    dont_use = ' '.join('-dont_use %s' % pat for pat in read_patterns(files['synth_excluded']))
    incs = ' '.join('-I"%s"' % d for d in cfg['include_dirs'])
    defs = ' '.join('-D%s' % k if v in (None, '', True) else '-D%s=%s' % (k, v) for k, v in cfg['defines'].items())
    period_ps = int(round(float(cfg['clock_period_ns']) * 1000))
    scl = cfg['scl']
    ys = ['# Written by HDLPhy', 'read_liberty -lib -ignore_miss_dir -setattr blackbox "%s"' % lib]
    for s in srcs:
        sv = '-sv' if s.lower().endswith(('.sv', '.svh')) else ''
        ys.append('read_verilog -defer %s %s %s "%s"' % (sv, incs, defs, s))
    params = ' '.join('-set %s %s' % (k, v) for k, v in (cfg.get('params') or {}).items())
    if params:
        ys.append('chparam %s %s' % (params, cfg['top']))
    ys += [
        'hierarchy -check -top %s' % cfg['top'],
        '# RTL view: the elaborated design, before technology mapping',
        'prep -top %s' % cfg['top'],
        'write_json "%s"' % os.path.join(r, 'rtl.json'),
        '# Synthesis to SKY130 standard cells',
        'synth -top %s %s' % (cfg['top'], '-flatten' if cfg.get('flatten', True) else ''),
    ]
    if os.path.isfile(files['tribuf_map']):
        ys.append('techmap -map "%s"' % files['tribuf_map'])
    if os.path.isfile(files['latch_map']):
        ys.append('techmap -map "%s"' % files['latch_map'])
    ys += [
        'dfflibmap -liberty "%s" %s' % (lib, dont_use),
        'opt -purge',
        'abc %s -liberty "%s" %s' % ('-D %d' % period_ps if period_ps > 0 else '', lib, dont_use),
        'setundef -zero',
        'splitnets',
        'opt_clean -purge',
        'hilomap -singleton -hicell %s__conb_1 HI -locell %s__conb_1 LO' % (scl, scl),
        'insbuf -buf %s__buf_2 A X' % scl,
        'opt_clean -purge',
        'hierarchy -top %s' % cfg['top'],
        # name the internal ($...) cells and wires _N_ here, so netlist.v (what OpenROAD places) and gate.json
        # (what the schematic draws) carry the same instance names: needed for cross-probing between the tabs
        'rename -enumerate',
        'check',
        'tee -o "%s" stat -liberty "%s"' % (os.path.join(p['reports'], 'synth_stat.txt'), lib),
        'write_verilog -noattr -noexpr -nohex -nodec -defparam "%s"' % os.path.join(r, 'netlist.v'),
        'write_json "%s"' % os.path.join(r, 'gate.json'),
    ]
    script = os.path.join(r, 'synth.ys')
    with open(script, 'w') as fh:
        fh.write('\n'.join(ys) + '\n')
    rc = run_tool('synth', [yosys, '-s', script], os.path.join(p['logs'], '1_synth.log'))
    if rc != 0:
        return False
    emit('artifact', stage='synth', kind='schematic', view='rtl', path=os.path.join(r, 'rtl.json'))
    emit('artifact', stage='synth', kind='schematic', view='gate', path=os.path.join(r, 'gate.json'))
    # metrics from the stat report
    stat = open(os.path.join(p['reports'], 'synth_stat.txt')).read()
    m = {}
    a = re.findall(r'Chip area for (?:top )?module.*?:\s*([0-9.]+)', stat)
    if a:
        m['cell_area_um2'] = float(a[-1])
    n = re.findall(r'^\s*([0-9]+)\s+[0-9.E+-]*\s*cells\s*$', stat, re.M) or re.findall(r'Number of cells:\s*([0-9]+)', stat)
    if n:
        m['cells'] = int(n[-1])
    cells = {}
    for cnt, name in re.findall(r'^\s*([0-9]+)\s+(?:[0-9.E+-]+\s+)?(%s__\S+)\s*$' % re.escape(scl), stat, re.M):
        cells[name] = cells.get(name, 0) + int(cnt)
    if cells:
        m['cells_by_type'] = cells
        m['cells'] = sum(cells.values())
        m['flops'] = sum(v for k, v in cells.items() if re.search(r'__(dfx|dfr|dfs|dfb|dlx|dlr|sdf|edf)', k))  # flip-flops, latches (not dlygate)
    m['has_clock'] = has_port(cfg, os.path.join(r, 'rtl.json'), cfg.get('clock_port') or '')
    save_metrics(p, 'synth', m)
    return True


# ---------------------------------------------------------------- OpenROAD stages

EDGES = ('left', 'right', 'top', 'bottom')
# Edge length per I/O pin: the pin placer keeps pins two routing tracks apart, on met3 (0.68 um pitch) on the
# left/right edges and on met2 (0.46 um pitch) on the top/bottom edges; it also keeps ~1 um clear of each corner.
PIN_STEP_UM = {'left': 1.36, 'right': 1.36, 'top': 0.92, 'bottom': 0.92}
PIN_CORNER_UM = 1.0


def pin_sides(cfg, has_clock):
    """{'input': edge, 'output': edge, 'clock': edge}, each one of EDGES or 'any'."""
    def edge(key, default):
        v = str(cfg.get(key) or default).strip().lower()
        return v if v in EDGES else 'any'
    sides = {'input': edge('pin_input_side', 'any'), 'output': edge('pin_output_side', 'any')}
    clk = str(cfg.get('pin_clock_side') or 'inputs').strip().lower()
    sides['clock'] = sides['input'] if clk == 'inputs' else edge('pin_clock_side', 'any')
    if not has_clock:
        sides['clock'] = 'any'
    return sides


def bus_order(cfg):
    v = str(cfg.get('pin_bus_order') or 'free').strip().lower()
    return v if v in ('ascending', 'descending') else 'free'


def io_pin_counts(cfg, p, has_clock):
    """Pin (bit) counts of the top module's ports: input (without the clock), output, clock, other; and the
    buses as (group, bits) with group input, output or other."""
    n = {'input': 0, 'output': 0, 'clock': 0, 'other': 0}
    buses = []
    try:
        top = json.load(open(os.path.join(p['results'], 'gate.json')))['modules'][cfg['top']]
    except (OSError, ValueError, KeyError):
        return n, buses
    clk = (cfg.get('clock_port') or '').strip()
    for name, port in top['ports'].items():
        bits = len(port.get('bits', []))
        if has_clock and name == clk:
            n['clock'] += bits
            continue
        group = port.get('direction') if port.get('direction') in ('input', 'output') else 'other'
        n[group] += bits
        if bits > 1:
            buses.append((group, bits))
    return n, buses


def edge_um(n, e):
    """Die edge length for n pins on edge e, with 25 % headroom and the corners kept clear."""
    return n * PIN_STEP_UM[e] * 1.25 + 2 * PIN_CORNER_UM + 2.0 if n else 0.0


def floorplan_geometry(cfg, p):
    """Die and core boxes (um) from the synthesized cell area and the target utilization, grown where
    needed so every die edge has room for the I/O pins assigned to it."""
    met = json.load(open(os.path.join(p['reports'], 'metrics.json'))).get('synth', {})
    area = float(met.get('cell_area_um2') or 100.0)
    util = max(5.0, min(90.0, float(cfg['utilization']))) / 100.0
    ar = max(0.2, min(5.0, float(cfg['aspect_ratio'])))        # height / width
    core_area = area / util
    w = math.sqrt(core_area / ar)
    h = w * ar
    min_core = float(cfg.get('min_core_um') or 30.0)
    m = float(cfg['core_margin_um'])
    m = math.ceil(m / 0.46) * 0.46
    has_clock = bool(met.get('has_clock'))
    counts, buses = io_pin_counts(cfg, p, has_clock)
    n_io = sum(counts.values())
    sides = pin_sides(cfg, has_clock)
    notes = []
    if all(e == 'any' for e in sides.values()):
        # pins anywhere: about 1.5 um of edge per pin over the four sides
        min_side = max(min_core, n_io * 1.5 / 4.0)
        w, h = max(w, min_side), max(h, min_side)
    else:
        # pins per edge: the assigned groups, plus a quarter of the unassigned pins on every edge
        demand = {e: 0.0 for e in EDGES}
        loose = counts['other']
        for g in ('input', 'output', 'clock'):
            if sides[g] in EDGES:
                demand[sides[g]] += counts[g]
            else:
                loose += counts[g]
        for e in EDGES:
            demand[e] += loose / 4.0
        need_h = max(edge_um(demand['left'], 'left'), edge_um(demand['right'], 'right')) - 2 * m   # core height
        need_w = max(edge_um(demand['top'], 'top'), edge_um(demand['bottom'], 'bottom')) - 2 * m   # core width
        w0, h0 = max(w, min_core), max(h, min_core)
        w, h = max(w0, need_w), max(h0, need_h)
        if h > h0 + 1e-6:
            notes.append('core height raised to %.2f um (%s) for the left/right pins' % (math.ceil(h / 2.72) * 2.72, 'aspect ratio %.2g' % ar))
        if w > w0 + 1e-6:
            notes.append('core width raised to %.2f um (%s) for the top/bottom pins' % (math.ceil(w / 0.46) * 0.46, 'aspect ratio %.2g' % ar))
    # an ordered bus with no edge of its own needs one edge long enough for all its bits
    loose_bus = max([b for g, b in buses if sides.get(g, 'any') == 'any'] or [0]) if bus_order(cfg) != 'free' else 0
    if loose_bus:
        need_w, need_h = edge_um(loose_bus, 'top') - 2 * m, edge_um(loose_bus, 'left') - 2 * m
        if w < need_w and h < need_h:
            if (need_w - w) * h <= (need_h - h) * w:     # grow the side that costs less area
                w = need_w
                notes.append('core width raised to %.2f um for a %d-bit bus in bit order' % (math.ceil(w / 0.46) * 0.46, loose_bus))
            else:
                h = need_h
                notes.append('core height raised to %.2f um for a %d-bit bus in bit order' % (math.ceil(h / 2.72) * 2.72, loose_bus))
    site_w, row_h = 0.46, 2.72
    w = math.ceil(w / site_w) * site_w
    h = math.ceil(h / row_h) * row_h
    core = (m, m, m + w, m + h)
    die_box = (0.0, 0.0, round(core[2] + m, 2), round(core[3] + m, 2))
    core = tuple(round(v, 2) for v in core)
    return die_box, core, n_io, sides, notes


def pdn_params(core):
    """Power stripes scaled to the core: met4 vertical, met5 horizontal (1.6 um wide, LibreLane's sky130 width)."""
    cw, ch = core[2] - core[0], core[3] - core[1]
    def pitch(span):
        # two stripes (power, ground) per pitch; at least ~2 pitches across the core, at most LibreLane's 153.6 um
        return round(max(13.6, min(153.6, span / 2.0)), 2)
    pv, ph = pitch(cw), pitch(ch)
    return {'PDN_VPITCH': pv, 'PDN_VOFFSET': round(pv / 4.0, 2), 'PDN_HPITCH': ph, 'PDN_HOFFSET': round(ph / 4.0, 2),
            'PDN_WIDTH': 1.6, 'PDN_SPACING': 1.7}


def openroad_env(cfg, files, p, lib):
    env = dict(os.environ)
    env.update({
        'DESIGN': cfg['design'], 'TOP': cfg['top'],
        'RESULTS': p['results'], 'REPORTS': p['reports'], 'LOGS': p['logs'],
        'TECH_LEF': files['tech_lef'], 'CELL_LEF': files['cell_lef'], 'LIB': lib,
        'SDC': os.path.join(p['results'], 'constraints.sdc'),
        'TRACKS_INFO': files['tracks'], 'SCL': cfg['scl'],
        'DONT_USE_CELLS': ' '.join(read_patterns(files['synth_excluded'])),
        'PLACE_DENSITY': str(cfg['place_density']),
        'CLOCK_PORT': (cfg.get('clock_port') or '').strip() if cfg.get('has_clock') else '',
        'HDLPHY_SCRIPTS': SCRIPTS,
    })
    return env


def stage_openroad(stage, cfg, files, p, tools, extra_env=None):
    openroad = tools['openroad']
    if not openroad:
        die('openroad not found (expected ~/eda/tools/openroad/bin/openroad or on PATH)')
    lib = plain_liberty(cfg, files, p)
    # constraints from the current settings (clock period changes apply to any re-run stage)
    met = json.load(open(os.path.join(p['reports'], 'metrics.json'))).get('synth', {})
    cfg['has_clock'] = bool(met.get('has_clock'))
    write_sdc(cfg, p)
    env = openroad_env(cfg, files, p, lib)
    env.update({k: str(v) for k, v in (extra_env or {}).items()})
    script = os.path.join(SCRIPTS, stage + '.tcl')
    idx = STAGES.index(stage) + 1
    log = os.path.join(p['logs'], '%d_%s.log' % (idx, stage))
    rc = run_tool(stage, [openroad, '-exit', '-no_init', '-no_splash', '-threads', str(cfg['threads']), script],
                  log, env=env, cwd=p['run'])
    if rc != 0:
        return False
    out = open(log, errors='replace').read()
    m = {}
    for key, val in re.findall(r'^##HDLPHY-METRIC (\S+) (.*)$', out, re.M):
        try:
            m[key] = float(val)
        except ValueError:
            m[key] = val.strip()
    if stage == 'place':
        # PPL-0042: a pin group (ordered bus) found no place in its region and went to the placer's first-fit
        # fallback (PPL-0078 only means one section of an edge was full, and the next one is tried)
        bad = re.findall(r'^\[WARNING PPL-0*42\].*$', out, re.M)
        m['pin_group_warnings'] = len(bad)
        for line in bad[:5]:
            emit('log', stage=stage, text='pin placement: ' + line)
    if stage == 'route':
        # TritonRoute's summary after its last iteration
        v = re.findall(r'Number of violations = (\d+)', out)
        if v:
            m['drc_violations'] = int(v[-1])
        w = re.findall(r'^Total wire length = ([0-9.]+) um', out, re.M)
        if w:
            m['wirelength_um'] = float(w[-1])
        n = re.findall(r'^Total number of vias = (\d+)', out, re.M)
        if n:
            m['vias'] = int(n[-1])
    save_metrics(p, stage, m)
    return True


def stage_floorplan(cfg, files, p, tools):
    die_box, core, n_io, sides, notes = floorplan_geometry(cfg, p)
    extra = {'DIE_AREA': ' '.join('%.2f' % v for v in die_box), 'CORE_AREA': ' '.join('%.2f' % v for v in core)}
    extra.update(pdn_params(core))
    emit('log', stage='floorplan', text='die %s um, core %s um, %d I/O pins' % (extra['DIE_AREA'], extra['CORE_AREA'], n_io))
    if any(e != 'any' for e in sides.values()):
        emit('log', stage='floorplan', text='pin edges: inputs %(input)s, outputs %(output)s, clock %(clock)s' % sides)
    if bus_order(cfg) != 'free':
        emit('log', stage='floorplan', text='bus pins in %s bit order' % bus_order(cfg))
    for note in notes:
        emit('log', stage='floorplan', text=note)
    return stage_openroad('floorplan', cfg, files, p, tools, extra)


def stage_place(cfg, files, p, tools):
    met = json.load(open(os.path.join(p['reports'], 'metrics.json'))).get('synth', {})
    sides = pin_sides(cfg, bool(met.get('has_clock')))
    return stage_openroad('place', cfg, files, p, tools,
                          {'PIN_INPUT_SIDE': sides['input'], 'PIN_OUTPUT_SIDE': sides['output'],
                           'PIN_CLOCK_SIDE': sides['clock'], 'PIN_BUS_ORDER': bus_order(cfg)})


def stage_cts(cfg, files, p, tools):
    met = json.load(open(os.path.join(p['reports'], 'metrics.json'))).get('synth', {})
    has_clock = bool(met.get('has_clock')) and bool(met.get('flops', 1))
    return stage_openroad('cts', cfg, files, p, tools, {'HAS_CLOCK': '1' if has_clock else '0'})


# ---------------------------------------------------------------- GDS and the layout view

def stage_view(cfg, files, p, tools, def_name, out_prefix, write_gds):
    klayout = tools['klayout']
    if not klayout:
        die('klayout not found')
    script = os.path.join(KLAYOUT_SCRIPTS, 'def2gds.py')
    args = [klayout, '-b', '-zz', '-r', script,
            '-rd', 'def_file=' + os.path.join(p['results'], def_name),
            '-rd', 'tech_lef=' + files['tech_lef'], '-rd', 'cell_lef=' + files['cell_lef'],
            '-rd', 'cell_gds=' + files['cell_gds'], '-rd', 'layer_map=' + files['layer_map'],
            '-rd', 'lyp=' + files['lyp'], '-rd', 'top=' + cfg['top'],
            '-rd', 'view_prefix=' + os.path.join(p['results'], out_prefix)]
    if write_gds:
        args += ['-rd', 'gds_out=' + os.path.join(p['results'], 'final.gds')]
    env = dict(os.environ)
    env.pop('KLAYOUT_PATH', None)
    log = os.path.join(p['logs'], '6_gds.log' if write_gds else 'view_%s.log' % out_prefix)
    rc = run_tool('gds', args, log, env=env)
    return rc == 0


def stage_gds(cfg, files, p, tools):
    ok = stage_view(cfg, files, p, tools, 'final.def', 'layout', True)
    if ok:
        gds = os.path.join(p['results'], 'final.gds')
        emit('artifact', stage='gds', kind='gds', path=gds)
        emit('artifact', stage='gds', kind='layout', path=os.path.join(p['results'], 'layout.json'))
        save_metrics(p, 'gds', {'gds_bytes': os.path.getsize(gds)})
    return ok


# ---------------------------------------------------------------- driver

def check(cfg):
    files = pdk_files(cfg)
    tools = {t: find_tool(t, cfg) for t in ('yosys', 'openroad', 'klayout')}
    versions = {}
    for t, exe in tools.items():
        if not exe:
            continue
        try:
            arg = {'yosys': ['-V'], 'openroad': ['-version'], 'klayout': ['-v']}[t]
            out = subprocess.run([exe] + arg, capture_output=True, text=True, timeout=20).stdout.strip()
            versions[t] = out.splitlines()[0] if out else ''
        except (OSError, subprocess.SubprocessError):
            versions[t] = ''
    missing = [k for k in ('tech_lef', 'cell_lef', 'cell_gds', 'tracks', 'lyp', 'layer_map') if not os.path.isfile(files[k])]
    if not (os.path.isfile(files['lib_gz']) or os.path.isfile(files['lib_plain'])):
        missing.append('lib')
    return {'tools': tools, 'versions': versions, 'pdk': files, 'missing_pdk_files': missing,
            'python': sys.version.split()[0]}


# What each stage writes (results/ and reports/), so a re-run can drop the stale results of later stages.
STAGE_OUTPUTS = {
    'synth': ['results/rtl.json', 'results/gate.json', 'results/netlist.v', 'results/synth.ys',
              'reports/synth_stat.txt'],
    'floorplan': ['results/2_floorplan.odb', 'results/2_floorplan.def', 'results/layout_floorplan.json', 'results/layout_floorplan.bin'],
    'place': ['results/3_place.odb', 'results/3_place.def', 'results/layout_place.json', 'results/layout_place.bin'],
    'cts': ['results/4_cts.odb', 'results/4_cts.def', 'results/layout_cts.json', 'results/layout_cts.bin'],
    'route': ['results/5_route.odb', 'results/5_route.def', 'results/final.def', 'results/final.v', 'results/final_pg.v',
              'reports/drc.rpt', 'reports/timing_setup.rpt', 'reports/timing_hold.rpt', 'reports/power.rpt', 'reports/area.rpt'],
    'gds': ['results/final.gds', 'results/layout.json', 'results/layout.bin'],
}


def clean_from(p, start):
    """Removes the results and metrics of `start` and every later stage."""
    later = STAGES[STAGES.index(start):]
    for st in later:
        for rel in STAGE_OUTPUTS[st]:
            f = os.path.join(p['run'], rel)
            if os.path.isfile(f):
                os.remove(f)
    mp = os.path.join(p['reports'], 'metrics.json')
    if os.path.isfile(mp):
        try:
            data = json.load(open(mp))
        except ValueError:
            data = {}
        for st in later:
            data.pop(st, None)
        with open(mp, 'w') as fh:
            json.dump(data, fh, indent=1)


def run(cfg, start, stop):
    p = paths(cfg)
    files = pdk_files(cfg)
    tools = {t: find_tool(t, cfg) for t in ('yosys', 'openroad', 'klayout')}
    funcs = {'synth': stage_synth, 'floorplan': stage_floorplan,
             'place': stage_place,
             'cts': stage_cts, 'route': lambda c, f, pp, t: stage_openroad('route', c, f, pp, t),
             'gds': stage_gds}
    i0, i1 = STAGES.index(start), STAGES.index(stop)
    if i0 > 0:
        need = {'floorplan': 'gate.json', 'place': '2_floorplan.odb', 'cts': '3_place.odb', 'route': '4_cts.odb', 'gds': 'final.def'}[start]
        if not os.path.isfile(os.path.join(p['results'], need)):
            die('%s needs the result of the previous stage (%s); run the earlier stages first' % (STAGE_TITLES[start], need))
    clean_from(p, start)
    emit('run', stages=STAGES[i0:i1 + 1], run_dir=p['run'], tools=tools)
    for st in STAGES[i0:i1 + 1]:
        emit('stage', stage=st, title=STAGE_TITLES[st], status='start')
        t0 = time.time()
        try:
            ok = funcs[st](cfg, files, p, tools)
        except SystemExit:
            raise
        except Exception as e:  # report the failure to the app, keep the traceback in the log
            import traceback
            traceback.print_exc()
            emit('log', stage=st, text='%s: %s' % (type(e).__name__, e))
            ok = False
        dt = round(time.time() - t0, 2)
        emit('stage', stage=st, title=STAGE_TITLES[st], status='done' if ok else 'failed', seconds=dt)
        if not ok:
            emit('finished', ok=False, failed=st)
            return 1
    emit('finished', ok=True)
    return 0


def main(argv):
    if len(argv) < 2 or argv[1] in ('-h', '--help'):
        print(__doc__)
        return 0
    cmd = argv[1]
    if cmd == 'check':
        cfg = load_config(argv[2]) if len(argv) > 2 else json.loads(json.dumps(DEFAULTS))
        print(json.dumps(check(cfg), indent=1))
        return 0
    if cmd == 'example':
        out = os.path.abspath(argv[2] if len(argv) > 2 else 'hdlphy_counter')
        os.makedirs(out, exist_ok=True)
        ex = os.path.join(os.path.dirname(HERE), 'examples', 'counter.v')
        cfg = {'design': 'counter', 'top': 'counter', 'sources': [ex], 'clock_port': 'clk', 'clock_period_ns': 10}
        path = os.path.join(out, 'config.json')
        json.dump(cfg, open(path, 'w'), indent=1)
        print(path)
        return 0
    if cmd == 'run':
        cfg = load_config(argv[2])
        start, stop = 'synth', 'gds'
        rest = argv[3:]
        for i, a in enumerate(rest):
            if a == '--from':
                start = rest[i + 1]
            elif a == '--to':
                stop = rest[i + 1]
        if start not in STAGES or stop not in STAGES or STAGES.index(start) > STAGES.index(stop):
            die('bad stage range %s..%s (stages: %s)' % (start, stop, ', '.join(STAGES)))
        return run(cfg, start, stop)
    if cmd == 'view':
        cfg = load_config(argv[2])
        st = argv[3] if len(argv) > 3 else 'route'
        names = {'floorplan': '2_floorplan.def', 'place': '3_place.def', 'cts': '4_cts.def', 'route': 'final.def'}
        if st not in names:
            die('view needs one of: ' + ', '.join(names))
        p = paths(cfg)
        files = pdk_files(cfg)
        tools = {t: find_tool(t, cfg) for t in ('yosys', 'openroad', 'klayout')}
        if not os.path.isfile(os.path.join(p['results'], names[st])):
            die('no %s result yet' % st)
        ok = stage_view(cfg, files, p, tools, names[st], 'layout_' + st, False)
        if ok:
            emit('artifact', stage=st, kind='layout', path=os.path.join(p['results'], 'layout_%s.json' % st))
        return 0 if ok else 1
    die('unknown command ' + cmd)


if __name__ == '__main__':
    sys.exit(main(sys.argv))
