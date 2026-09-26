# Logo assets

An **MX Master inside an Apple Magic Trackpad**: two real device illustrations combined in monochrome. The mouse depicts the original MX Master, rotated 90° clockwise. The trackpad depicts the original Magic Trackpad, with its distinctive rear battery housing.

- `logo.svg` — transparent logo for light backgrounds; editable vector master.
- `logo-dark.svg` — transparent version with a lighter trackpad outline for dark backgrounds.
- `logo.png` — 1024 × 1024 transparent export for app and document mockups.
- `social-preview.svg` / `social-preview.png` — editable and exported 1280 × 640 GitHub/social card.

Use the PNG social card for consistent text rendering. The composed SVGs have no external resources, scripts, or tracking.

## Sources and licensing

### MX Master mouse — MIT

[Original SVG](https://github.com/libratbag/libratbag/blob/821e2798b9af80f932f18c0e2cbdad5c905d7f94/data/logitech-mx_master.svg) from **libratbag v0.5**, commit `821e2798b9af80f932f18c0e2cbdad5c905d7f94`. Its MIT [COPYING](https://github.com/libratbag/libratbag/blob/821e2798b9af80f932f18c0e2cbdad5c905d7f94/COPYING) notice is preserved in `sources/LIBRATBAG-LICENSE.txt` and embedded in the composed SVGs.

Changes: retain the device contours, remove label leaders, gradients, duplicate highlights and material shadows; convert to black-and-white shapes with heavier outlines; crop, scale, and rotate 90° clockwise. The unmodified upstream SVG is in `sources/logitech-mx-master.svg`.

### Magic Trackpad — CC BY 3.0

[Apple Magic Trackpad.svg](https://commons.wikimedia.org/wiki/File:Apple_Magic_Trackpad.svg), vector by **Gringer**, based on a photograph by **Micky Aldridge**, 21 August 2010. Licensed under [Creative Commons Attribution 3.0](https://creativecommons.org/licenses/by/3.0/). Source-page revision: `959937139`.

Changes: retain the two device paths, remove gradients and editor metadata, convert to monochrome, increase outline width, and scale around the mouse. The dark variant lightens the outline. The unmodified SVG and attribution details are in `sources/apple-magic-trackpad.svg` and `sources/MAGIC-TRACKPAD-LICENSE.md`.

Original composition contributions: Copyright (c) 2026 Aytek Aksu, MIT. Third-party artwork retains the licenses above; the Magic Trackpad's attribution requirements still apply. Preserve the embedded SVG notices and source credits when redistributing the logo. This project is independent of Logitech and Apple; the logo is not an official mark of either company.

## Exporting

PNG exports can be regenerated with an SVG renderer at the dimensions above. They were exported with Sharp, using Helvetica Neue for the social card. These design tools are not needed to install or run MX Master Mac.
