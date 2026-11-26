# HDLPhy: DEF (+ LEF + standard-cell GDS) -> GDS, and the geometry file the Layout tab draws.
# Run with:  klayout -b -zz -r def2gds.py -rd def_file=... -rd tech_lef=... -rd cell_lef=...
#            -rd cell_gds=... -rd layer_map=... -rd lyp=... -rd top=... -rd view_prefix=... [-rd gds_out=...]
#
# view_prefix.json  layers (name, GDS layer/datatype, colors from the PDK's .lyp), instances, pin labels
# view_prefix.bin   polygons as little-endian int32 (database units), per layer:
#                   for each polygon: contour count, then for each contour: point count, x0, y0, x1, y1, ...
#                   (the first contour is the hull, the others are holes)
import json
import os
import struct
import sys
import xml.etree.ElementTree as ET

import pya

g = globals()
def_file = g['def_file']
tech_lef, cell_lef, cell_gds = g['tech_lef'], g['cell_lef'], g['cell_gds']
layer_map, lyp = g['layer_map'], g['lyp']
top_name = g['top']
view_prefix = g.get('view_prefix')
gds_out = g.get('gds_out')

# Drawing order (bottom to top) and the layers shown by default.
STACK = ['nwell.drawing', 'pwell.drawing', 'diff.drawing', 'tap.drawing', 'poly.drawing', 'licon1.drawing',
         'li1.drawing', 'mcon.drawing', 'met1.drawing', 'via.drawing', 'met2.drawing', 'via2.drawing',
         'met3.drawing', 'via3.drawing', 'met4.drawing', 'via4.drawing', 'met5.drawing']
SHOWN = set(STACK) | {'prBoundary.boundary'}


def load_lyp(path):
    """(layer, datatype) -> {name, fill, frame, dither, visible} from a KLayout layer-properties file."""
    out = {}
    try:
        root = ET.parse(path).getroot()
    except (OSError, ET.ParseError):
        return out
    for props in root.iter('properties'):
        src = (props.findtext('source') or '').strip()
        if '/' not in src:
            continue
        try:
            ld = src.split('@')[0]
            layer, dt = (int(v) for v in ld.split('/'))
        except ValueError:
            continue
        name = (props.findtext('name') or '').split(' - ')[0].strip() or ld
        out[(layer, dt)] = {
            'name': name,
            'fill': props.findtext('fill-color') or '#808080',
            'frame': props.findtext('frame-color') or props.findtext('fill-color') or '#808080',
            'dither': props.findtext('dither-pattern') or 'I1',
            'visible': (props.findtext('visible') or 'true') == 'true',
        }
    return out


opt = pya.LoadLayoutOptions()
cfg = opt.lefdef_config
cfg.dbu = 0.001
cfg.map_file = layer_map
cfg.lef_files = [tech_lef, cell_lef]
cfg.read_lef_with_def = False
cfg.macro_layout_files = [cell_gds]      # real cell geometry instead of the LEF abstracts
cfg.instance_property_name = 'inst'      # keep the DEF instance names
cfg.produce_cell_outlines = False
opt.lefdef_config = cfg

ly = pya.Layout()
ly.read(def_file, opt)
top = ly.cell(top_name)
if top is None:
    tops = ly.top_cells()
    if not tops:
        sys.stderr.write('def2gds: no cells read from %s\n' % def_file)
        sys.exit(1)
    top = tops[0]
print('def2gds: read %s, top %s, %d cells, dbu %g' % (os.path.basename(def_file), top.name, ly.cells(), ly.dbu))

# ---------------------------------------------------------------- GDS
if gds_out:
    out = pya.Layout()
    out.dbu = ly.dbu
    t = out.create_cell(top.name)
    t.copy_tree(top)
    for c in out.each_cell():          # GDS properties need integer keys: drop the name properties
        for inst in c.each_inst():
            if inst.prop_id:
                inst.prop_id = 0
    save = pya.SaveLayoutOptions()
    save.format = 'GDS2'
    out.write(gds_out, save)
    print('def2gds: wrote %s (%d bytes)' % (gds_out, os.path.getsize(gds_out)))

# ---------------------------------------------------------------- view data
if view_prefix:
    props = load_lyp(lyp)
    layers = []
    data = bytearray()
    total = 0
    for li in ly.layer_indexes():
        info = ly.get_info(li)
        if info.layer < 0:
            continue
        reg = pya.Region(top.begin_shapes_rec(li))
        if reg.is_empty():
            continue
        reg.merge()
        p = props.get((info.layer, info.datatype), {})
        name = p.get('name') or info.name or '%d/%d' % (info.layer, info.datatype)
        start = len(data) // 4
        ints = []
        count = 0
        for poly in reg.each():
            contours = [list(poly.each_point_hull())] + [list(poly.each_point_hole(h)) for h in range(poly.holes())]
            ints.append(len(contours))
            for pts in contours:
                ints.append(len(pts))
                for pt in pts:
                    ints.append(pt.x)
                    ints.append(pt.y)
            count += 1
        if count == 0:          # text-only layers (labels are exported separately)
            continue
        data += struct.pack('<%di' % len(ints), *ints)
        total += count
        bb = reg.bbox()
        order = STACK.index(name) if name in STACK else -1
        layers.append({
            'name': name, 'layer': info.layer, 'datatype': info.datatype,
            'fill': p.get('fill', '#808080'), 'frame': p.get('frame', '#808080'), 'dither': p.get('dither', 'I1'),
            'visible': name in SHOWN, 'order': order,
            'offset': start, 'length': len(ints), 'count': count,
            'bbox': [bb.left, bb.bottom, bb.right, bb.top],
        })
    # bottom-to-top drawing order: other layers (implants, markers) first, then the process stack
    layers.sort(key=lambda L: (L['order'], L['layer'], L['datatype']))

    instances = []
    for inst in top.each_inst():
        cname = inst.cell.name
        if cname.startswith('VIA_'):   # DEF vias become cells (KLayout's default prefix); list only cells
            continue
        bb = inst.bbox()
        short = cname.split('__', 1)[-1]
        kind = 'logic'
        for prefix, k in (('tapvpwrvgnd', 'tap'), ('decap', 'decap'), ('fill', 'fill'), ('clkbuf', 'clock'),
                          ('clkinv', 'clock'), ('conb', 'tie')):
            if short.startswith(prefix):
                kind = k
                break
        name = inst.property('inst')
        instances.append({'name': str(name) if name is not None else '', 'cell': cname, 'kind': kind,
                          'bbox': [bb.left, bb.bottom, bb.right, bb.top]})

    labels = []
    for li in ly.layer_indexes():
        info = ly.get_info(li)
        for sh in top.shapes(li).each(pya.Shapes.STexts):
            t = sh.text
            labels.append({'text': t.string, 'x': t.x, 'y': t.y, 'layer': '%d/%d' % (info.layer, info.datatype)})

    bb = top.bbox()
    header = {
        'format': 'hdlphy-layout-1', 'top': top.name, 'dbu': ly.dbu, 'source': os.path.abspath(def_file),
        'gds': os.path.abspath(gds_out) if gds_out else None,
        'bbox': [bb.left, bb.bottom, bb.right, bb.top], 'polygons': total,
        'layers': layers, 'instances': instances, 'labels': labels,
        'bin': os.path.basename(view_prefix) + '.bin',
    }
    with open(view_prefix + '.bin', 'wb') as fh:
        fh.write(data)
    with open(view_prefix + '.json', 'w') as fh:
        json.dump(header, fh)
    print('def2gds: view %s.json — %d layers, %d polygons, %d instances' % (view_prefix, len(layers), total, len(instances)))
