# Device Capacity Report (Current Repository Snapshot)

This document summarizes the largest currently supported device classes across the architectures available in this repository snapshot, with emphasis on:

- Approximate LUT scale
- Approximate site-map size (grid / tile-map scale)
- Clock-region or equivalent global/regional clocking structure

Status labels used below:

- **Measured**: extracted directly from local database/files/tool output
- **Estimated**: inferred from device naming or architecture conventions
- **Model-specific**: architecture does not expose a single FPGA-style "clock region" count

## Summary Table

| Architecture | Largest device class currently visible | Logic scale | Site-map scale | Clock-region / clock-domain view | Confidence |
|---|---|---:|---:|---|---|
| `ice40` | HX8K / LP8K class | ~8K LUT4 (estimated from family class) | `34 x 34` (~1156) | No explicit CR model; 8 global clock networks | Measured + Estimated |
| `ecp5` | `LFE5UM5G-85F` | ~85K LUT4 (family class) | `127 x 96` (~12192 unique coords) | 4 quadrants (`UL`, `UR`, `LL`, `LR`) | Measured + Estimated |
| `nexus` | `LIFCL-40` / `LFD2NX-40` | ~40K-class logic (family class) | `88 x 57` (~5016 unique coords) | No single explicit CR count exposed in this flow | Measured + Estimated |
| `machxo2/xo3` | `LCMXO2-7000` / `LCMXO3-6900` | ~6.9K to 7K-class logic | `41 x 26` bbox, ~1018 unique coords | Global/spine model; no stable public CR count | Measured + Estimated |
| `mistral` (Cyclone V) | `gt300f` / `gx300f` / `e300*` | **227,120 ALUT** (113,560 ALM) | `122 x 116` (~14152) | 16 global clocks + up to 88 regional clocks | Measured |
| `himbaechel-ng-ultra` | `NG-ULTRA` | ~384 LUT + 24 XLUT counted from local BEL DB | Raw grid `97 x 53`; generated placement grid `388 x 212` | Non-classic CR model; ring/tube + 20-to-20 GCK structures | Measured |
| `himbaechel-gatemate` | `CCGM1A4` | ~82K-class logic (device-class estimate) | `332 x 268` (~88976) | Multi-die domain model (4-die for A4) | Measured + Estimated |
| `himbaechel-gowin` | `GW5AST-138C` (largest in configured list) | ~138K-class logic (device-class estimate) | ~`182 x 109` (code-inferred bounds) | Top/bottom split + quadrant-like segmentation (about 8 segments) | Inferred |
| `generic` | User-defined | No fixed limit | No fixed limit | No fixed limit | N/A |

## Per-Architecture Notes

### ice40

- Largest local iCE40 DB entry is `8k`, with `.device 8k 34 34 ...`.
- The iCE40 import path keeps `glbinfo` sized to 8 entries, matching 8 global clock networks.

### ecp5

- Local Trellis DB for `LFE5UM5G-85F` yields the largest ECP5 map in this setup.
- ECP5 global routing code explicitly uses 4 quadrants (`UL`, `UR`, `LL`, `LR`).

### nexus

- Local Oxide DB exposes `LIFCL-40`, `LFD2NX-40`, and `LIFCL-17`.
- `LIFCL-40` / `LFD2NX-40` share the largest parsed tilegrid envelope in this local dataset.

### machxo2/xo3

- `LCMXO2-7000` is the largest MachXO2-class part in current local Trellis DB.
- Logic count is reported as class estimate from device naming; exact effective LUT-style capacity varies by family and vendor reporting style.

### mistral (Cyclone V backend)

- Largest local variant entries are `gt300f`/`gx300f`/`e300*`, each with `alut:227120`.
- Local die description for `gt300f` reports tile size `122 x 116`.
- Clocking documentation in Mistral states 16 global clocks and up to 88 regional clocks.

### himbaechel-ng-ultra

- `devices.json` gives `max_col=96`, `max_row=52`.
- NG-Ultra arch generator scales this to placement grid width/height by `*4`.
- Local BEL DB count includes `LUT=384`, `XLUT=24`.
- Clocking is exposed as ring/tube/GCK structures rather than a classic CR integer.

### himbaechel-gatemate

- Device set includes `CCGM1A1`, `CCGM1A2`, `CCGM1A4`.
- `CCGM1A4` is the largest (2x2 die composition), giving max grid `332 x 268`.
- Clocking behavior is modeled with multi-die strategies (`mirror`, `clk1`, `full`), so die domains are more meaningful than a single CR number.

### himbaechel-gowin

- Current configured device list includes up to `GW5AST-138C`.
- In this local setup, an exact generated chip DB was not available for direct row/col dumping.
- Code-level indicators in Apycula/Gowin flow show GW5AST segmented top/bottom clock structures and bounds reaching rows near 109 and columns near 182; values are therefore marked inferred.

## Method and Scope

This report uses only local files and locally built tools in the current workspace:

- `nextpnr-* --help` / `--list-devices` outputs where available
- Local dependency databases under `_deps/` and `_deps/_install/`
- Architecture import/generator source code for fields that are not directly printable via CLI

It is a **repository snapshot report**, not a vendor datasheet replacement. For procurement-grade exact capacities, check official vendor collateral for the exact package/speedgrade part number.

## Primary Sources (Local Paths)

- `ice40`: `_deps/icestorm/icebox/chipdb-8k.txt`, `ice40/chipdb.py`
- `ecp5`: `_deps/_install/trellis/share/trellis/database/ECP5/LFE5UM5G-85F/tilegrid.json`, `ecp5/trellis_import.py`
- `nexus`: `_deps/prjoxide/database/LIFCL/LIFCL-40/tilegrid.json`
- `machxo2`: `_deps/_install/trellis/share/trellis/database/MachXO2/LCMXO2-7000/tilegrid.json`
- `mistral`: `_deps/mistral/data/models.txt`, `_deps/mistral/libmistral/cvd-gt300f.cc`, `_deps/mistral/docs/cyclonev_fpga.rst`
- `ng-ultra`: `_deps/prjbeyond-db/devices.json`, `_deps/prjbeyond-db/NG-ULTRA/tilegrid.json`, `_deps/prjbeyond-db/NG-ULTRA/bels.json`, `himbaechel/uarch/ng-ultra/gen/arch_gen.py`
- `gatemate`: `_deps/prjpeppercorn/gatemate/chip.py`, `_deps/prjpeppercorn/gatemate/die.py`, `himbaechel/uarch/gatemate/pack.cc`
- `gowin`: `_deps/apicula/apycula/chipdb.py`, `himbaechel/uarch/gowin/gowin_arch_gen.py`
