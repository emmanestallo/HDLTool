# HDL Viewer

A native macOS waveform viewer for VCD files (from Icarus Verilog and other simulators), styled after VS Code.

## Build

```bash
./build_app.sh            # builds build/HDL Viewer.app
./build_app.sh --install  # also copies it to ~/Applications
```

Needs only the Command Line Tools (Swift 6), not Xcode.

## Use

- Drag a `.vcd` onto the window or Dock icon, or press ⌘O. Each file opens in its own tab.
- **Explorer** (left): click a scope, then double-click or drag signals into the waveform. ⇧⌘F searches all signals.
- The waveform **reloads automatically** when the file changes, so re-running `vvp` refreshes it. Your signal list is remembered for each file.

| Action | How |
|---|---|
| Pan | Two-finger swipe sideways, Shift+wheel, or drag the ruler |
| Zoom | Pinch, ⌘/⌥+scroll, drag across the waves to zoom to that range, ⌘= / ⌘- |
| Zoom to fit | ⌘0 or `F` |
| Cursor / marker | Click / Shift-click (snaps to nearby edges); `M` puts the marker at the cursor |
| Jump to edges | ← / → (selected signals, or all signals) |
| Select / reorder | Click, ⌘-click, Shift-click; ⌥↑ / ⌥↓ or drag the names |
| Remove | ⌫ |
| Radix & color | Right-click a signal name |
| Theme | Gear icon (Dark Modern, Dark+, Light Modern) |

The status bar shows the time between the cursor and the marker, and the matching frequency.

### Analog view (macOS app)

Right-click a bus → **Display** to plot it as an analog trace with full scale = 1:

| Mode | Scaling | Range |
|---|---|---|
| Analog Unsigned | code / 2ᴺ | 0 … 1 (max code = 1 − 1 LSB) |
| Analog Signed | two's complement code / 2ᴺ⁻¹ | −1 … +1 (0x80…0 = −1 exactly, 0x7F…F = +1 − 1 LSB) |
| Analog (auto range) | the value itself, scaled to the data's min/max | also available for `real` signals |

- **Interpolation**: Step (sample & hold, like a DAC output) or Linear.
- **Row Height**: 1× to 12×. Analog rows default to 4×.
- The VALUE column shows the analog level at the cursor, with enough decimals for one LSB, plus the raw code underneath. X/Z samples break the trace and are shaded red.
- Display mode, interpolation and height are remembered per file. See `examples/analog/analog_tb.v` for a demo.

## Windows version

`windows/` holds an Electron port with the same features and look. On Windows the shortcuts use Ctrl instead of ⌘, and the ☰ button in the title bar opens the app menu.

```bash
cd windows
npm install
npm start                # run it on this Mac for testing
npm run dist:win         # builds windows/dist/HDL Viewer Setup 1.0.0.exe
```

Copy the `Setup` exe to the Windows PC and run it. It installs per-user (no admin needed), adds Start menu and desktop shortcuts, and makes `.vcd` files open in HDL Viewer. The installer is not code-signed, so SmartScreen will warn the first time: click **More info → Run anyway**.

The two apps don't share settings: signal layouts and recent files are kept separately by each.

## Example

```bash
cd examples && iverilog -o sim counter_tb.v && vvp sim   # writes counter.vcd
```
