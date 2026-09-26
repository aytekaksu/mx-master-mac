# Logo assets

The logo places a solid mouse silhouette above an original trackpad drawing. The tick and circular badge are removed. The background and the mouse's wheel/button cutouts are transparent.

- `logo.svg` — black logo with a transparent background.
- `logo-dark.svg` — white logo with a transparent background.
- `logo.png` — 1024 × 1024 transparent PNG.
- `social-preview.svg` / `social-preview.png` — editable and exported 1280 × 640 social card.
- `icons/mouse.svg` — the mouse PNG converted to editable vector paths.
- `icons/trackpad.svg` — the original trackpad frame, as a separate vector component.

The SVG files contain actual paths and shapes, not embedded PNGs. They have no external resources, scripts, or tracking. The mouse stays upright as in the supplied reference.

## Artwork provenance

### Mouse

Traced from the PNG supplied by the repository owner. The screenshot's checkerboard background was removed, the unused canvas cropped, and the black silhouette and its wheel/button cutouts converted into vector paths. The logo scales this shape without changing its proportions.

No upstream author or license accompanied the supplied mouse image. Vector conversion does not change the underlying artwork rights; this project's MIT code license does not grant rights to third-party source artwork.

### Trackpad and composition

Original geometry created for MX Master Mac: a rounded frame and two lower click areas. Copyright (c) 2026 Aytek Aksu, MIT. The owner's Icons8 PNG was a reference for the initial concept; its traced paths are **not** included in the published logo or repository. The separate conversion of that PNG was delivered privately to the owner.

The previously used libratbag mouse and Wikimedia Magic Trackpad artwork have been replaced. Their source files and licenses are retained in Git history, not used by the current logo.

This project is independent of Logitech and Apple; the logo is not an official mark of either company.

## Editing and exporting

Change the SVG's `color` value to recolor the complete logo. The mouse is a filled path with transparent wheel and button details; there is no circle, mask, or background rectangle. `icons/mouse.svg` and `icons/trackpad.svg` can also be edited separately in a vector editor.

PNG exports can be regenerated with an SVG renderer at the dimensions above. They were exported with Sharp, using Helvetica Neue for the social card. Potrace was used only to convert the supplied mouse image. Neither tool is a dependency of MX Master Mac.
