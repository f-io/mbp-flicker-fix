# mbp-flicker-fix

Stops the flicker on a MacBook Pro Touch Bar whose OLED panel flickers at low brightness.

## What it does

- Sets a minimum brightness for the Touch Bar (default 40%). Auto-brightness stays on and may make the bar brighter, but never darker than the minimum.
- The dim stage shows the minimum instead of macOS's 15%.
- The bar never really switches off. The panel flickers in macOS's off state too, because the display keeps refreshing while the brightness drive sits at its lowest level. tbkeep keeps the drive at the minimum instead.
- Removes the fades. macOS fades the bar in and out, and every fade passes through the flicker range. tbkeep cuts each fade, so the bar jumps straight to its level.

## Changes from upstream

This is a modified verion of [c0ldsheep/macbook-touch-bar-flicker-fix](https://github.com/c0ldsheep/macbook-touch-bar-flicker-fix)

- A minimum instead of a fixed level, so auto-brightness keeps working above it
- The dim stage stays, but at the minimum
- No real off. The bar shows black at the minimum instead
- No fade in either direction
- Event driven instead of a fixed timer. tbkeep follows CoreBrightness notifications and only watches the dimming step once input has paused for a second, until macOS has switched the bar off

## Install

```sh
./install.sh
```

Builds `tbkeep` on your Mac and starts it at every login. No admin password needed.

## Commands

If `tbkeep` is not on your PATH, call it by its full path, for example:

```bash
~/"Library/Application Support/tbkeep/tbkeep" 50
```

| Command | What it does |
|---|---|
| `tbkeep` | Show the status |
| `tbkeep 50` | Set the minimum to 50% (5 to 100). Use a higher number if it still flickers |
| `tbkeep try` | Find the lowest level with no flicker |
| `tbkeep disable` | Turn the fix off. `tbkeep <number>` turns it back on |
| `tbkeep uninstall` | Remove everything |

## License

[MIT](LICENSE)
