# LightScribe Studio

A GTK4 front-end, written in Julia, for `/opt/4L/4L-cli.bin` (the LaCie LightScribe Labeler for Linux).
It picks up its colours from the active Omarchy theme (Lumon by default) and switches live when you change themes.

## Run

```bash
./bin/lightscribe-studio [image]
```

The first launch precompiles packages, so it takes about 30 s. Later launches are faster.
Install the launcher entry with `cp lightscribe-studio.desktop ~/.local/share/applications/`.

## Features
- **Disc preview** drawn to scale (120 mm disc, hub, and the printable ring for each mode: full 24.3–59.5 mm,
  content 25.3–37.6 mm, title 31.8–37.6 mm). Parts of the image outside the ring show faintly ("ghost").
  You can pick a simulation tint: gold LightScribe dye, theme colours, or mono.
- **Placement:** zoom (scroll on the disc), rotate, offset (drag the disc), mirror, fill or fit, center.
- **Tone:** brightness, contrast, gamma, sharpen, invert, auto levels, threshold, Floyd–Steinberg dither.
  Double-click a slider to reset it.
- **Text:** add any number of text items. Each one has its own font (any installed font, and you can type
  to search the list), size in mm, bold/italic, and a path: straight (multi-line), along the top arc,
  or along the bottom arc (kept upright). Ink can be burn, or knock out to leave text unburned over a dark image.
  With "Drag / scroll on disc edits this text" on, dragging moves the selected text (around the ring for arcs)
  and scrolling resizes it. You can make a text-only label without loading an image.
- **Burn:** scan for drives, eject/close, media info, a **drive preview** (4L's own render of the label),
  and **burn** with a progress bar, time remaining and abort (SIGINT, as 4L-cli documents).

## How burning works
The label is rendered to a 2835×2835 BMP at 600 DPI, which is exactly 120 mm, so the preview matches the
burned disc. It is then run as:

```
pkexec env LD_LIBRARY_PATH=/usr/lib32/lightscribe /opt/4L/4L-cli.bin print -q <quality> -m <mode> -s 600 <drive> <bmp>
```

4L-cli needs root for drive I/O. Each drive command shows a polkit prompt. You can override the defaults with the
`LIGHTSCRIBE_CLI`, `LIGHTSCRIBE_LIBDIR` and `LIGHTSCRIBE_SUDO` environment variables.
Rendered files go to `~/.cache/lightscribe-studio/`.

## Label files, undo and export
- **Save / Save As** write a `.lslabel` file (plain TOML). It stores the image reference, all placement
  and tone settings, the label mode, and every text item. The image itself is **not embedded**. The file stores
  both its absolute path and its path relative to the label, so moving the label and the image together keeps
  them linked. If the image can't be found, the text and settings still open.
- **Undo / Redo** cover every change to the label: image, placement, tone, text, and mode. Edits made in quick
  succession (one slider drag, a burst of typing) count as one step. Up to 200 steps are kept.
- **Export** writes the exact burn image (2835 px, 600 dpi = 120 mm) as PNG or BMP.
- Unsaved changes show as `•` in the title. New, Open and Quit ask before throwing them away.

| Shortcut | Action |
|---|---|
| `Ctrl+Z` | Undo |
| `Ctrl+Shift+Z` / `Ctrl+Y` | Redo |
| `Ctrl+S` / `Ctrl+Shift+S` | Save / Save As |
| `Ctrl+O` | Open a label or an image |
| `Ctrl+N` | New label |
| `Ctrl+E` | Export PNG/BMP |
| `Ctrl+Q` | Quit |

## Data discs (photo archive)
The **DATA DISC** tab at the top writes files to a CD, DVD or Blu-ray as an ordinary data disc. It doesn't
engrave a label. It needs `xorriso`:

```bash
sudo pacman -S libisoburn
```

- **Add photos** (`Ctrl+O`) opens a thumbnail picker that starts in `~/Pictures`. Click photos to pick them
  (click again to unpick), Shift+click to pick a range, and use `Ctrl+A` / SELECT ALL to pick everything in a folder.
  Click a folder to open it. Picks are kept while you move between folders, and photos already on the disc are
  marked ON DISC. **Add this folder as album** adds the folder you're viewing. **Other location…** opens the
  system file dialog, where Ctrl+click and Shift+click also pick several files.
- **Add album folder** (`Ctrl+Shift+O`) adds whole folders, and each one appears on the disc as a folder with
  its sub-folders kept. You can also drag files and folders in from a file manager. Click a name to rename it
  on the disc.
- **From folders, include:** choose photos & videos (the default; it also keeps `.xmp`/`.aae` sidecars),
  photos only, or all files. Hidden files, `Thumbs.db`, `.DS_Store` and Synology `@eaDir` are always skipped.
  Files you add one by one are always included.
- **Disc ring:** shows how full the disc will be. **CHECK DISC** reads the media in the drive (type, blank or
  appendable, free space), or you can pick CD 700 MB, DVD 4.7 GB, DVD DL 8.5 GB or BD 25 GB to plan without a disc.
  WRITE DISC stays disabled until the files fit.
- **Options:**
  - *Finalize disc:* closes the disc. Turn it off to add more sessions later; old files stay visible.
    Open discs are written track-at-once (`-write_type tao`), because DVD-R written the default way (DAO) is always closed.
  - *Verify after writing:* reads every file back and checks it against the MD5 recorded while writing.
  - *Eject when done.*
  - *Erase rewritable disc first:* RW media only.
  - *Speed.*
- **Save as ISO image…** makes the same disc as an `.iso` file, to burn later or keep as a backup.
- Names use Rock Ridge (Linux/macOS) plus Joliet with long names (Windows). Abort stops xorriso safely, and
  quitting during a write asks first. The drive is used directly as your user (no root), through the
  desktop's `uaccess` ACL on `/dev/sr*`.


# Why?

## Using what I already have because I am poor
Because I have eccentric tastes and I wanted a good workflow for archiving my photos. I have myself a bunch of
lightscribe disks and an old though very nice lightscribe DVD drive. I really can't afford those Blu-ray M Disks, so 
I use what I have. 

## No time after grad school and my other life commitments
I am quite a busy grad student so it wasn't like I had the time to write this myself so I asked Claude to do it for me

## Having a "thumbnail" of the photos on a DVD data disk is pretty cool
I really like to have a little preview of what is on the disk that can't get ripped off like a inkjet label or wiped off
accidentally like the markings of the ever popular sharpie
