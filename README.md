# valo-true-stretch

Play **Valorant** in a stretched resolution — with one double-click.

---

## Setup (about 30 seconds)

**1. Set your resolution.** Open **`config.txt`** and change this line:

```
resolution = 1280x1024
```

**2. Double-click `valo-stretch.cmd`.**
The first time only, Windows asks for approval once — click **Yes**.

**3. Play.**
Valorant opens in your resolution. When you quit the game, your normal display
comes back **automatically**.

That's it. Every time after that: just double-click and play — no more prompts.

---

## Quick summary

- **What it does:** switches your display to the resolution in `config.txt`,
  disables the monitor so stretched (non-native) modes work, launches Valorant,
  and restores everything the moment you quit — even if the game crashes.
- **Any GPU:** AMD, Intel, or NVIDIA. It finds your display automatically.
- **No prompt after the first run.** Approve once; it sets itself up for silent use.
- **One file to edit:** `config.txt`. Nothing else to configure.

---

## Handy commands (optional)

Double-click = play. From a terminal you can also run:

```
valo-stretch toggle          Toggle the display on/off (no game)
valo-stretch 1920x1080       One-off toggle at a specific resolution
valo-stretch setdefault WxH  Save the default resolution
valo-stretch status          Show settings and current state
valo-stretch uninstall       Undo the no-prompt setup
```

---

## Good to know

- **Windows 10 / 11.** Uses built-in PowerShell — nothing to install.
- Needs Administrator **once** (the launcher handles it; you just click **Yes**).
- Disabling the monitor does **not** black out your screen — it only removes the
  limit that blocks stretched resolutions.
- If Valorant is **already open**, it won't launch a second copy — it just applies
  the profile and waits for you to quit.
- If Valorant isn't found automatically, set `valorant = C:\...\RiotClientServices.exe`
  in `config.txt`.
- Only your resolution and monitor state change — nothing touches the game. Use
  on your own account at your discretion.

---

## License

[MIT](LICENSE) © Lex.
