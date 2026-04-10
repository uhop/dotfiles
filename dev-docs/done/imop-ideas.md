# Image Optimization Ideas

`imop` (`private_dot_local/bin/executable_imop`) — a CLI tool for optimizing images.

Goal: prepare images for the web by reducing file size while preserving acceptable quality.

## Tools

Current:

- `jpegoptim` — JPEG
- `optipng` — PNG
- `cwebp` — WebP

Possible upgrades:

- `zopflipng` — PNG (better compression than optipng)
- `guetzli` — JPEG (better quality per byte but extremely slow)

These should be researched further. Additional web-relevant formats (AVIF, HEIC, etc.) are worth supporting if good CLI tooling is available via `brew`.

## Desired functionality

### Re-compress

Takes input and output file. Re-compresses the input using the tool selected by the **input** extension.

### Convert

Takes input and output file. Converts the input to the format implied by the **output** extension.

### Batch

Takes an input directory and an output directory. Processes all images, preserving directory structure. Supports both re-compression and conversion.

### Batch in-place

Same as batch, but writes results back to the source directory.

## Implementation details

### Tool availability

Check each tool before use. If missing: skip, use a fallback, or warn once with an install suggestion.

### Quality level

Expose a generic `-q, --quality` parameter (e.g., 0–100) and map it to each tool's native flag.

### Output file naming

When no output name is given (single-file or batch), generate one as `<input>.<tag>.<ext>`:

- `image.jpg` + webp → `image.jpg.webp`
- `image.jpg` + optimize → `image.jpg.optimize.jpg`
- `image.png` + zopfli → `image.png.zopfli.png`

This naming supports server-side content negotiation: serve the best format the client accepts, fall back to the original.

### Use options.bash

Use `options.bash` for argument parsing and rich terminal output.
