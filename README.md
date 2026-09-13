# force-edid

Force a custom EDID onto a specific external display on Apple Silicon Macs — at
runtime, no reboot. Handy when a monitor (often one behind a KVM) reports a wrong or
generic EDID, so macOS drives it at the wrong resolution, drops HDR, or doesn't light it up at
all.

It works by injecting an EDID at runtime through a private, undocumented macOS API
(`IOAVServiceSetVirtualEDIDMode`). This isn't guaranteed by Apple and could change between
macOS versions — use at your own risk.

## Why this exists

On Intel Macs you could drop an EDID override plist under
`/Library/Displays/Contents/Resources/Overrides/…`. On Apple Silicon that's ignored — the
Display CoProcessor (DCP) handles displays and never reads those files.

The approach that *does* work is to inject an EDID at runtime and let macOS re-negotiate the
connection. That's what `force-edid` does. It also bridges the mismatch a KVM introduces: the
KVM may present the display under the wrong vendor/product ids, so rather than blindly writing
your saved EDID, `force-edid` grafts the good timing onto the identity the KVM is *currently*
reporting. Keeping that live identity is what lets macOS accept the change without tearing down
and rebuilding your display arrangement (which can knock your other monitor off).

## Requirements

- An Apple Silicon Mac (M1 or later).
- Xcode Command Line Tools (`xcode-select --install`) for `clang`.

## Build

```sh
clang -framework Foundation -framework IOKit -o force-edid force-edid.m
```

That produces a single self-contained `force-edid` binary.

## Quick start

The idea: capture a display's good EDID while it works correctly, then re-inject it later
when a KVM mangles it.

```sh
# 1. See what's connected and how each display currently identifies itself:
./force-edid list

# 2. While the display is working correctly (e.g. plugged in directly, without the KVM), it
#    reports its real name — save its EDID, matching on that name:
./force-edid dump MyPanel-good-edid.bin --name "MyPanel"

# 3. Later — behind the KVM, when it's misbehaving — the KVM may report the display under a
#    different name/ids. Run `list` to see how it shows up now, then match on THAT:
./force-edid update MyPanel-good-edid.bin --name "Generic Display" --bump

# 4. To revert (the injected EDID carries the good name), or just reboot:
./force-edid reset --name "MyPanel"
```

Note the matcher differs between steps: in step 2 you match the display's own name; in step 3
you match whatever the KVM currently reports (check `./force-edid list`). `--bump` nudges the
identity so macOS re-detects the display; see the [`update` options](#update-options) for when
to use it and for the lighter `--timing-only` variant.

Every command that changes a display takes a matcher so it acts on exactly one screen —
see [Selecting a display](#selecting-a-display).

## Commands

| Command | What it does |
|---|---|
| `list` | List external displays with their live EDID (vendor/product, name, resolution). |
| `dump <out.bin> <matcher>` | Save a display's current EDID to a file. |
| `update <src.bin> <matcher> [options]` | Build a hybrid EDID from the display's live identity + `<src.bin>`, then apply it. The high-level, one-shot command. |
| `graft <src.bin> -o <out.bin> <matcher>` | Low-level: write a timing-only hybrid EDID to a file (never applies). |
| `apply <edid.bin> <matcher>` | Inject an EDID file into one display. |
| `reset <matcher>` | Revert a display to its original EDID. |

### `update` options

- `--timing-only` — graft only the preferred resolution/timing (keeps the display's other
  descriptors; the lightest, safest change). Default grafts the source's full descriptors
  and its extension block (where things like HDR/audio live).
- `--bump [N]` — set the injected product id to the source EDID's product + N (default `+1`).
  A distinct id makes macOS treat it as a fresh display and re-detect one that's connected but
  not showing up in System Settings → Displays.
- `-o <file>` — also save the built EDID to a file.
- `--dry-run` — build (and save, with `-o`) but don't apply.

## Selecting a display

Any command that targets a display accepts a matcher. Pick whichever is most stable for your
setup:

| Matcher | Matches on |
|---|---|
| `--name <substr>` | Case-insensitive substring of the display's current EDID name |
| `--vendor 0xXXXX --product 0xYYYY` | The display's current vendor/product ids (from `list`) |
| `--location <loc>` | The display's IORegistry `Location` |

A matcher is required whenever more than one external display is connected, so the tool
never touches the wrong one. `--name` is usually the most convenient — and it's stable even
when a KVM shuffles the numeric ids on every reboot.

## How the hybrid is built

`update` and `graft` build a hybrid EDID: the matched display's live EDID supplies the
identity (vendor + basic parameters), and your source file supplies the timing (and, by
default, the extension block). Checksums are recomputed and verified before anything is applied.
Keeping the identity is what stops WindowServer from rearranging your desktop and dropping other
screens.

## Re-applying after a reboot

Runtime EDID injection is not persistent — it's lost on reboot, so you re-apply afterwards.
Once you've settled on the right source EDID and matcher, drop the invocation into a small
shell script and run it after each reboot (or wire it to a login `LaunchAgent`). Use absolute
paths, or adjust to wherever you keep the binary and your saved EDID:

```sh
#!/bin/bash
/usr/local/bin/force-edid update ~/edids/MyPanel-good-edid.bin --name "Generic Display" --bump
```

## License

MIT — see [LICENSE](LICENSE).
