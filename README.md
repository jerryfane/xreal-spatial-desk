# xreal-spatial-desk

Groundwork for a macOS app that turns **XREAL One** glasses into several virtual monitors floating around you. You create screens where you look, grab them with your head, and drop them anywhere.

Status: the app itself is not built yet. This repo has everything needed to start it:

| Path | What it is |
|---|---|
| [`index.html`](index.html) | Interactive preview of the experience at the glasses' real resolution and field of view. Open it in a browser. |
| [`BRIEF.md`](BRIEF.md) | Build brief: verified protocol facts, open questions, architecture, UX, milestones |
| [`tools/fake_glasses.py`](tools/fake_glasses.py) | Pretends to be the glasses by replaying a real recording on their TCP ports, so the app can be developed without hardware |
| [`tools/record_session.py`](tools/record_session.py) | Records a new session from real glasses (read-only, voice-guided head movements) |
| [`captures/20261110-140512/`](captures/20261110-140512) | 93 s recording from an XREAL One on firmware 1.9.1: 1000 Hz head motion, button presses, take-off/put-on events, factory calibration. Serial number redacted. |

## Quick start

```sh
# preview
open index.html

# fake glasses on localhost (Python 3.8+, standard library only)
python3 tools/fake_glasses.py captures/20261110-140512 --loop

# record your own glasses (plugged in over USB-C, worn, volume up)
python3 tools/record_session.py
```

## How the glasses talk

Over USB-C the XREAL One appears as a network adapter, and the glasses answer at `169.254.2.1`:

- TCP 52998: head-motion stream
- TCP 52999: control channel (settings, buttons, wear events)

No driver is needed. Details are in [`BRIEF.md`](BRIEF.md).

## Credits

Protocol knowledge comes from community reverse engineering:
- [georgehorrell/xreal-one-cli](https://github.com/georgehorrell/xreal-one-cli)
- [GarfDev/xreal-one-control-panel](https://github.com/GarfDev/xreal-one-control-panel)
- [kevindurb/xreal-linux](https://github.com/kevindurb/xreal-linux)
- [Skarian/one-xr](https://github.com/Skarian/one-xr)
- [0xcaff/xr-tools](https://github.com/0xcaff/xr-tools)

Not affiliated with XREAL. The tools only read from the glasses; nothing here flashes firmware.

## License

MIT
