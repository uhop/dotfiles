# imop Implementation Plan

Based on research and `imop-ideas.md`.

## Tool selection

### Recommended tool matrix

| Format | Lossless | Lossy | Extra (slow) | brew formula |
|---|---|---|---|---|
| JPEG | `jpegoptim` (strip metadata) | `mozjpeg` (`cjpeg`) | `guetzli` | `jpegoptim`, `mozjpeg` (keg-only), `guetzli` |
| PNG | `oxipng` | `pngquant` | `zopflipng` | `oxipng`, `pngquant`, `zopfli` |
| WebP | `cwebp -lossless` | `cwebp` | — | `webp` |
| AVIF | `avifenc --lossless` | `avifenc` | — | `libavif` |

### Research findings

**JPEG:** `mozjpeg` produces 10–15% smaller files than libjpeg at the same quality. Its `cjpeg` binary is the encoder. `guetzli` compresses ~5% better than mozjpeg but is 1000x slower and only supports quality ≥ 84 — impractical for batch use. Recommendation: **mozjpeg** for lossy, **jpegoptim** for lossless re-compression (strip metadata, optimize Huffman tables).

**PNG:** `oxipng` is a maintained, multithreaded Rust rewrite of `optipng` — strictly better. `zopflipng` squeezes ~3–5% more but is 10–100x slower. `pngquant` reduces palette (lossy) and can cut file size by 50–70% with minimal visual loss. Recommendation: **oxipng** for lossless, **pngquant + oxipng** pipeline for lossy.

**WebP:** `cwebp` is the standard encoder, well-maintained. No meaningful alternatives. Keep as-is.

**AVIF:** `avifenc` (from `libavif`) is the standard encoder. Available via `brew install libavif`. AVIF typically beats WebP by 20–30% at equivalent quality. Supported by all modern browsers (Chrome, Firefox, Safari 16.4+). Worth adding.

**Dropped:** HEIC (poor browser support), JPEG-XR (dead format).

## Command structure (hybrid)

The operation is inferred from the arguments but can be made explicit with a subcommand.

```
imop [options] [command] <args...>
```

### Inference rules

| Arguments | Inferred operation |
|---|---|
| `file` | Optimize in place (same format) |
| `file output` (same ext) | Optimize to output |
| `file output` (different ext) | Convert to output format |
| `dir` | Batch in-place (re-compress or convert with `--to`) |
| `dir-in dir-out` | Batch to output dir (re-compress or convert with `--to`) |

### Explicit subcommands

| Command | Arguments | Description |
|---|---|---|
| `optimize` / `o` | `file [output]` | Re-compress in the same format (lossless by default) |
| `convert` / `c` | `file output` | Convert to format implied by output extension |
| `batch` / `b` | `dir [output-dir] [--to EXT]` | Process all images in a directory tree |

When `output` is omitted in `optimize`, the file is optimized in place.

`batch` with one directory walks its image files (recursively) and applies the single-file operation to each — either re-compress in place or convert according to options. With two directories, results are written to the output directory preserving the source tree structure.

In both cases, `--to EXT` enables conversion (e.g., `--to webp`). Without it, files are re-compressed in their original format.

### Global options

| Option | Description |
|---|---|
| `-q, --quality N` | Quality level 0–100 (default: 80). Mapped to each tool's native scale. |
| `--lossy` | Force lossy compression (default for convert) |
| `--lossless` | Force lossless compression (default for optimize) |
| `--best` | Use the slow-but-best compressor for the format (`guetzli` for JPEG, `zopflipng` for PNG) |
| `-n, --dry-run` | Show what would be done without writing files |
| `--suffix TAG` | Append tag to output names: `file.TAG.ext` (batch mode) |
| `-v, --version` | Show version |
| `-h, --help` | Show help |

## Quality mapping

Map the generic 0–100 scale to each tool's native flags:

| Tool | Flag | Mapping |
|---|---|---|
| `mozjpeg` (`cjpeg`) | `-quality N` | Direct (0–100) |
| `jpegoptim` | `-m N` | Direct (0–100) |
| `guetzli` | `--quality N` | Direct (84–100, clamped) |
| `oxipng` | `-o N` | 0–100 → levels 0–6 |
| `pngquant` | `--quality N-N` | `(q-5)-(q+5)` range |
| `zopflipng` | (no quality flag) | Lossless only; ignore quality param |
| `cwebp` | `-q N` | Direct (0–100) |
| `avifenc` | `-q N` | Direct (0–100, inverted: 0 = best) |

## Tool availability strategy

On startup, detect available tools and build a capability map. For each format:

1. If the preferred tool is found, use it.
2. If a fallback is found, use it and warn once.
3. If nothing is found, skip and print an install suggestion once.

Fallback chain (preferred → fallback). `--best` selects the slow tier when available:

| Format | Preferred | Fallback | `--best` tier |
|---|---|---|---|
| JPEG lossy | `mozjpeg` (`cjpeg`) | `jpegoptim -m` | `guetzli` (quality ≥ 84 only) |
| JPEG lossless | `jpegoptim` | — | — |
| PNG lossy | `pngquant` → `oxipng` | `pngquant` → `optipng` | `pngquant` → `zopflipng` |
| PNG lossless | `oxipng` | `optipng` | `zopflipng` |
| WebP | `cwebp` | — | — |
| AVIF | `avifenc` | — | — |

Note: `mozjpeg` is keg-only in brew. Its `cjpeg` lives at `$(brew --prefix mozjpeg)/bin/cjpeg`. The script should check this path if `cjpeg` isn't on `$PATH`.

## Output file naming

Default: **standard extension replacement** — `image.jpg` → `image.webp`.

With `--suffix TAG`: **multi-extension** — `image.jpg` → `image.jpg.TAG.webp` (or `image.jpg.TAG.jpg` for same-format optimize). Useful for server-side content negotiation with fallback.

## Implementation phases

### Phase 1 — Core single-file operations

1. Rewrite `executable_imop` with `options.bash` (source `bootstrap.sh`).
2. Implement `optimize` command (lossless re-compression, single file).
3. Implement `convert` command (format conversion, single file).
4. Tool detection with fallback chain.
5. Quality mapping.

### Phase 2 — Batch processing

1. Implement `batch` with single directory (in-place traversal via `find`).
2. Implement `batch` with two directories (preserve structure in output dir).
3. Support `--to EXT` for batch conversion.
4. Implement `--suffix` naming.
5. Implement `--dry-run`.

### Phase 3 — Polish

1. Progress reporting (file count, sizes before/after, percentage saved).
2. Parallel processing (background jobs with a concurrency limit).
3. Add to wiki documentation.

## Design decisions (resolved)

- **PNG modes:** both lossy (`pngquant` → `oxipng` pipeline) and lossless (`oxipng`). Default to lossless; `--lossy` enables pngquant.
- **Output naming:** standard extension replacement by default. `--suffix TAG` opts into multi-extension naming.
- **Command structure:** hybrid — infer from arguments, explicit subcommands available for clarity.
- **Slow compressors:** `guetzli` (JPEG) and `zopflipng` (PNG) are supported as non-primary compressors, activated via `--best`. They fall back to the preferred tool if unavailable.
- **Batch single-dir:** `batch dir` walks image files recursively and applies the single-file operation to each (in-place re-compress or convert per options). Equivalent to running `imop` on each file individually.
