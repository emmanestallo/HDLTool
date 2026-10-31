# HDL Simulator

**HDL Coder** and **HDL Tester** in one macOS window, as two tabs. Write Verilog in the Coder, turn a module into a wired-up testbench in the Tester with one click, and move up and down the design hierarchy between them. Waveforms still open in **HDL Viewer**, which stays a separate app so it can live on its own monitor.

The Coder and Tester tabs look and work exactly like the standalone apps (see `../HDLCoder/README.md` and `../HDLTester/README.md`). This README only covers what is new.

## Build

```bash
./build_app.sh            # builds build/HDL Simulator.app
./build_app.sh --install  # also copies it to ~/Applications
```

Needs the Command Line Tools (Swift 6) and Icarus Verilog (`brew install icarus-verilog`). Install HDL Viewer (`../HDLViewer/build_app.sh --install`) to see waveforms.

## Tabs

The **Coder** / **Tester** tabs sit at the top left of the window. Switch with a click, **⌘1** / **⌘2**, or View → HDL Coder / HDL Tester. The menus and shortcuts (⌘R, ⌘S, ⌘B…) follow the tab that is showing. The app reopens on the tab you used last.

## Coder → Tester: generate a testbench

Next to **Run** in the Coder's title bar is the test-tube button, **Generate Testbench in HDL Tester** (⌥⌘T). It takes the module at the caret (or the first module in the file) and switches to the Tester tab with:

- a new test named after the module,
- the module placed as the DUT,
- a source wired to every input: a clock for `clk`-like pins, a reset for `rst` / `rst_n` pins, a constant for the rest.

Press Run (⌘R) there to simulate; the waveform opens in HDL Viewer. If a test already uses that module, the button takes you to it instead of making another one. The file is saved first.

The text-template testbench from the standalone Coder is still there as HDL → Generate Testbench File (Template), ⇧⌘G. In the Explorer, right-click a `.v` / `.sv` file → Generate Testbench in HDL Tester.

## Descend and ascend

| Where | Descend (⌥⌘↓) | Ascend (⌥⌘↑) |
|---|---|---|
| Tester | Double-click a DUT, right-click → *Descend into …*, or the ↘ button with a DUT selected: opens its `.v` file in the Coder at the module | — |
| Coder | Caret on an instance, the ↘ button: opens the instantiated module | The ↖ button: goes back to where you descended from |

Ascend goes, in order, to: the place you descended from (the test and DUT, or the line in the parent file), else an open test that uses this module, else a file in the open folder that instantiates it. The tooltip on the ↖ button says where it will go.

Ascending saves the file, and the Tester reloads it right away, so new or renamed ports show up on the DUT box as soon as you are back on the canvas.

The Tester's “Open in HDL Coder” (right-click a file or module under Available DUTs) also opens the file in the Coder tab, and Ascend comes back to the test.

## Files and settings

- Double-clicking a `.hdltest` opens it in the Tester tab; `.v`, `.sv`, `.vhd` files and folders open in the Coder tab.
- Settings (⌘,) has the Coder's Editor and Tools tabs plus a Tester tab. The color theme and the Icarus Verilog location are shared by both tabs.
- Open files and tests come back on relaunch (kept in `~/Library/Application Support/HDL Simulator/`, separate from the standalone apps).
- The example project (“Open Example Project” / “Open Example Test”) is copied to `~/Documents/HDL Simulator/Examples`, shared by both tabs.

## How it is built

`Sources/` has four Swift modules:

| Module | What it is |
|---|---|
| `CoderKit` | HDL Coder's code, with its own app entry point removed and the hierarchy additions in `Model/Hierarchy.swift` |
| `TesterKit` | HDL Tester's code, same treatment |
| `HDLShell` | What the two share: the active tab and the descend/ascend stack |
| `HDLSimulator` | The app: window, menus, opening files |

The standalone `../HDLCoder` and `../HDLTester` projects are unchanged; fixes made there have to be copied here by hand (and the other way around).

Developer helpers: `HDLSimulator --cli coder …` / `--cli tester …` (same commands as the standalone apps), and `--snapshot out.png [--tab coder|tester] [--select u_inst] [--actions "testbench|descend|ascend|tab:coder|line:12"] [--dump-menus] files…`.
