# Under the Rug

A Persian rug that lives on your Mac desktop. Shove files under it.

- **Drop files on the rug** to shove them under. They move to `~/Library/Application Support/Under the Rug/Stash` and show up as lumps in the cloth.
- **Drag the rug** to pull it around. It is a Verlet cloth: it wrinkles, lifts where you hold it and settles flat again.
- **Double-click** an end of the rug to fold it back up to that point. Your hidden files lie on the floorboards underneath: drag them out, or double-click to open. Double-click again to lay it flat.
- **Menu bar → Rug** has ten styles, from Tabriz Crimson to Acid Bazaar. Right-clicking the rug opens the same menu.
- **Menu bar → Sweep the Desktop Under the Rug…** moves everything on your Desktop under it in one go. **Pull Everything Back Out** puts every file back where it came from.

Files are only ever moved, never deleted. Desktop icons that sit beneath the rug are covered by it, because the rug window sits just above the Finder's icon layer.

## Build

Needs macOS 13+ and the Command Line Tools (no Xcode).

```bash
./build-app.sh
open "build/Under the Rug.app"
```

## Development

```bash
swift build -c release
.build/release/UnderTheRug --export-textures /tmp/rugs           # every rug style as PNG
.build/release/UnderTheRug --snapshot /tmp/rug.png --fold        # offscreen render (also --grab, --style id)
```

| File | What it does |
| --- | --- |
| `RugPattern.swift` | Procedural rug artwork: fringe, borders, field lattice, medallion; and the floor under the rug |
| `RugStyle.swift` | The colour schemes |
| `ClothSimulation.swift` | Verlet cloth with shape matching, folding, lumps and grabbing |
| `RugRenderer.swift`, `Shaders.swift` | Metal: shadow, pile and knot shading, the back of the rug |
| `RugView.swift` | Mouse, drag and drop in both directions |
| `Stash.swift` | Moves files under the rug and back |
| `AppDelegate.swift` | Window, click-through, menu bar |
