# HDLTool for Linux

Three Electron apps with the same VS Code look as the macOS and Windows versions:

| App | Command | What it does |
|---|---|---|
| **HDL Simulator** | `hdl-simulator` | Verilog/SystemVerilog/VHDL editor (**Coder**) and visual testbench builder (**Tester**); simulates with Icarus Verilog. |
| **HDL Viewer** | `hdl-viewer` | VCD waveform viewer (digital and analog display). |
| **HDLPhy** | `hdl-phy` | Synthesis and place-and-route of a Verilog design on **SKY130** (`sky130_fd_sc_hd`), with a **Schematic** tab (after synthesis) and a **Layout** tab (after place and route). |

HDL Simulator and HDL Viewer are the Windows apps' sources (Electron 44.7.0), adapted for Linux: Ctrl shortcuts, Linux tool locations, *Show in File Manager*, and HDL Viewer discovery (`hdl-viewer` on PATH, `~/.local/opt`, `/opt`, or `../HDLViewer` when running from source).

## Requirements

- **Node.js** (npm) to build or run from source. `setup/install-eda-tools.sh digital` in OpenSourceICD unpacks it into `~/eda/tools/node`, or use `sudo apt install nodejs npm`. The scripts below use `~/eda/tools/node` when it exists.
- **HDL Simulator:** Icarus Verilog (`sudo apt install iverilog`). Verilator and GHDL are optional.
- **HDLPhy:** yosys, OpenROAD and KLayout, plus the sky130A PDK in `~/eda/pdks` (or `$PDK_ROOT`).
  - `setup/install-eda-tools.sh digital` builds yosys and OpenROAD into `~/eda/tools`, without root.
  - KLayout comes from apt.
  - HDLPhy also finds the tools in the OSS CAD Suite or on PATH.

## Install

```bash
cd HDLTool/linux
./build_apps.sh --install          # all three apps; or e.g. ./build_apps.sh --install hdl-phy
```

This builds each app with electron-builder (`<app>/dist/linux-unpacked`) and installs it for the current user:

- the app goes in `~/.local/opt/<app>`;
- a launcher goes in `~/.local/bin/<app>`;
- a menu entry and icon go in `~/.local/share`.

`--package` also writes `.deb` and `.tar.gz` packages to `<app>/dist`. `--uninstall` removes the installed files.

To run from source without building, use `./run.sh hdl-simulator`, `./run.sh hdl-viewer file.vcd` or `./run.sh hdl-phy path/to/design`.

**Sandbox.** Ubuntu 24.04 and later restrict the user-namespace sandbox. Chromium's fallback, `chrome-sandbox`, must be owned by root with mode 4755. Until that is set up, the launchers start the apps with `--no-sandbox`. The apps only load their own local pages. To keep the sandbox on:

```bash
sudo chown root:root ~/.local/opt/<app>/chrome-sandbox && sudo chmod 4755 ~/.local/opt/<app>/chrome-sandbox
```

## HDLPhy

Open a folder of Verilog files: **Open Folder**, drag it onto the window, or run `hdl-phy <folder>`. Then:

1. In the Design view, tick the source files, pick the top module and the clock port and period. Adjust the floorplan if needed: utilization, aspect ratio, core margin and placement density. Under **Pins**, choose the die edge for the inputs, the outputs and the clock (left, right, top, bottom, or any edge). Left/right pins are on met3, top/bottom pins on met2, and the die grows if an edge is too short for its pins. **Bus order** keeps the bits of each bus together and in index order along the edge: bit 0 at the bottom (left/right edges) or on the left (top/bottom edges), or the reverse.
2. Press **Run Flow**, or F5. The Flow view shows the stages, and the Output panel streams the tool output:

   | Stage | Tool | Result |
   |---|---|---|
   | Synthesis | yosys | RTL view (`rtl.json`), gate-level netlist (`netlist.v`, `gate.json`), area report |
   | Floorplan | OpenROAD | die and core sized from the cell area, rows, tracks, tap/end-cap cells, power grid (met1 rails, met4/met5 stripes) |
   | Placement | OpenROAD | global placement, I/O pins (met2/met3, on the chosen edges), electrical repair, detailed placement |
   | Clock Tree | OpenROAD | CTS with `clkbuf_4/8/16`, setup/hold repair (skipped without a clock) |
   | Routing | OpenROAD | global and detailed routing on met1–met5, decap/fill cells, power-grid check, timing/power/area reports |
   | GDS | KLayout | `final.gds` (DEF + cell GDS) and the geometry the Layout tab draws |

3. Switch between the two title-bar tabs (Ctrl+1 / Ctrl+2):
   - **Schematic.** The netlist drawn with gate symbols: either **RTL** (elaborated, before mapping) or **Gate level (SKY130)**. Click a cell to see its pins and nets, click a wire to highlight its net, and double-click a submodule to open it.
   - **Layout.** The routed layout in the PDK's layer colors. It has a layer list (click to toggle, Alt+click for only that layer), cell outlines and names, pin labels, and the coordinates and instance under the cursor. Use **Show** to switch to the floorplan, placement or clock-tree result, and **KLayout** to open the GDS.
   - Cross-probing: *Find in Layout* from a schematic cell, *Show in Schematic* from a layout cell.

Settings are kept in `<folder>/hdlphy.json`, and results in `<folder>/hdlphy_run/<top>/`:

- `results/`: netlists, ODB/DEF per stage, `final.gds`;
- `reports/`: timing, power, area, DRC, `metrics.json`;
- `logs/`.

The flow also runs without the app:

```bash
python3 HDLPhy/flow/hdlphy_flow.py example /tmp/counter          # writes a config for examples/counter.v
python3 HDLPhy/flow/hdlphy_flow.py run /tmp/counter/config.json  # synth .. gds
python3 HDLPhy/flow/hdlphy_flow.py run CONFIG --from place --to route
python3 HDLPhy/flow/hdlphy_flow.py check                         # which tools and PDK files it uses
```

PDK settings come from the PDK's LibreLane configuration for `sky130_fd_sc_hd`:

- `tracks.info`;
- the excluded-cell lists (`synth_excluded.cells` becomes `dont_use`);
- tap distance, end caps, CTS buffers.

The power-stripe pitch is scaled to the die, because LibreLane's 153 µm pitch is larger than small designs.

The power grid is a block (macro) grid: met1 rails along the rows, met4 vertical and met5 horizontal stripes, and VPWR/VGND pins on the met4/met5 stripes. There is no core ring and there are no power pins on the die edge. Every stage connects the VPWR/VGND/VPB/VNB pins of the cells it adds, so `final_pg.v` is complete. The routing stage checks the grid (`check_power_grid`) and counts unconnected power pins. The Reports view shows the result as **Power grid**.

In `hdlphy.json` the pin edges are `pin_input_side`, `pin_output_side` and `pin_clock_side`. Each one is `any`, `left`, `right`, `top` or `bottom`; the clock can also be `inputs`, to follow the inputs. Inout pins are always placed automatically. `pin_bus_order` is `free` (the pin placer orders the bits for the shortest wires), `ascending` (bit index rising up the left/right edges and rightwards along the top/bottom edges) or `descending`.

## Layout of this folder

| Path | What it is |
|---|---|
| `HDLSimulator/`, `HDLViewer/` | Electron sources (from the Windows build) with the Linux changes |
| `HDLPhy/main.js`, `preload.js`, `src/` | HDLPhy app: window, flow runner, Schematic (`src/schematic.js`) and Layout (`src/layout.js`) views |
| `HDLPhy/schematic-worker.js`, `src/skin/` | netlistsvg in a worker process; the skin maps SKY130 cells to gate symbols |
| `HDLPhy/flow/` | the flow: `hdlphy_flow.py` (driver), `scripts/*.tcl` (OpenROAD stages), `klayout/def2gds.py` (GDS + layout export) |
| `build_apps.sh`, `run.sh` | build/install, run from source |
