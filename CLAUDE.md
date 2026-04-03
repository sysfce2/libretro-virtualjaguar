# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Virtual Jaguar libretro core — an Atari Jaguar emulator ported to the libretro API. Written in C, licensed under GPLv3. Upstream: `http://shamusworld.gotdns.org/git/virtualjaguar`.

## Build Commands

```bash
make -j$(getconf _NPROCESSORS_ONLN)          # Build (auto-detects platform)
make -j$(getconf _NPROCESSORS_ONLN) DEBUG=1  # Debug build (-O0 -g)
make clean                                    # Clean build artifacts
make platform=ios-arm64                       # Cross-compile for specific platform
```

Output binary name varies by platform:
- macOS: `virtualjaguar_libretro.dylib`
- Linux: `virtualjaguar_libretro.so`
- Windows: `virtualjaguar_libretro.dll`

There is no test suite. CI runs `make -j4` on Ubuntu (GCC) and macOS (Clang).

## Architecture

### Atari Jaguar Hardware Emulation

The Jaguar has four processors sharing a unified memory-mapped address space:

- **Motorola 68000** (13.3 MHz) — main CPU for game logic. Emulated via UAE-derived core in `src/m68000/`. The `cpuemu.c` file is machine-generated and very large (~1.8 MB).
- **GPU** (26.6 MHz RISC) — graphics coprocessor in `src/gpu.c`
- **DSP** (26.6 MHz RISC) — audio coprocessor in `src/dsp.c`, same instruction set as GPU
- **Object Processor** — sprite/bitmap rendering in `src/op.c`

Two custom chips contain these processors:
- **TOM** (`src/tom.c`) — video output, GPU, Object Processor, Blitter (`src/blitter.c`)
- **JERRY** (`src/jerry.c`) — audio DAC (`src/dac.c`), DSP, timers, EEPROM (`src/eeprom.c`)

### Execution Model

Frame execution is event-driven, not cycle-accurate. `JaguarExecuteNew()` in `src/jaguar.c` runs the main loop: the 68K executes until the next timed event, then GPU runs for the same timeslice, then event callbacks fire (half-line rendering, timer interrupts, etc.).

### Memory

Memory map defined in `src/vjag_memory.h`. The Jaguar is big-endian; `GET16/GET32/SET16/SET32` macros handle byte-swapping on little-endian hosts. Main RAM is 2 MB at 0x000000, cart ROM at 0x800000, TOM registers at 0xF00000, JERRY registers at 0xF10000.

### Libretro Integration

`libretro.c` (top-level) implements the libretro API — initialization, per-frame execution, input polling, video/audio output. Video is XRGB8888 at dynamic resolution (typically 320x240 NTSC / 320x256 PAL). Audio is 48 kHz 16-bit stereo.

Core options defined in `libretro_core_options.h` control blitter mode, BIOS usage, NTSC/PAL, DSP execution, and input mapping.

### Key Directories

- `src/` — emulator core (hardware chips, CPU, I/O, BIOS ROMs as C arrays)
- `src/m68000/` — UAE-derived 68K CPU emulation
- `libretro-common/` — shared libretro utility library (string, file, VFS)
- `docs/` — original Virtual Jaguar documentation, changelog, known issues

### Build System

`Makefile` handles 30+ platform targets with auto-detection. `Makefile.common` lists all source files. Platform is selected via `platform=` variable or auto-detected from `uname`. Key flags: `-D__LIBRETRO__`, `-DMSB_FIRST` for big-endian platforms.

### Known Limitations

- No save state support
- Blitter not fully cycle-accurate (some games need fast blitter mode)
- Bus contention between processors not emulated
- Vertical count (VC) register behavior not fully accurate
