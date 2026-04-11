// share/playbash/render.js — terminal rendering primitives.
//
// Everything that draws to the user's terminal lives here:
//   - ANSI sanitizer (strips terminal-hostile escapes, keeps SGR/colors)
//   - COLOR palette (dark/light-bg friendly, NO_COLOR honored)
//   - buildStatusLine (shared between single-host and fan-out summaries)
//   - Rectangle (single-host live view)
//   - HostSlot + StatusBoard (multi-host fan-out live view)
//
// No I/O side effects beyond writing to process.stdout / process.stderr.
// No domain logic. The runner imports from here.

// --- ANSI utilities ---

const ANSI_RE = /\x1b\[[0-9;?]*[a-zA-Z]/g;

export function visibleLength(s) {
  return s.replace(ANSI_RE, '').length;
}

// Strip escape sequences that would interfere with the rectangle's cursor
// management. Keeps SGR (color) so the rectangle is still pretty. The full
// uncut byte stream still goes to the log file unchanged.
//
// Chunk boundaries can split an escape sequence; we accept the rare case
// of a partial sequence leaking through. Tools tend to emit escape
// sequences in single writes, so this is rare in practice.
export function sanitizeForRect(input) {
  const text = typeof input === 'string' ? input : input.toString('utf8');
  return text
    // OSC: ESC ] ... BEL or ESC \
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, '')
    // DCS / SOS / PM / APC: ESC [PX^_] ... ESC \
    .replace(/\x1b[PX^_][\s\S]*?\x1b\\/g, '')
    // CSI sequences whose final byte is NOT 'm' (SGR is 'm', drop the rest)
    .replace(/\x1b\[[0-9;?<>!]*[A-Za-ln-z]/g, '')
    // Two-char ESC sequences (ESC c reset, ESC =/> keypad, ESC 7/8 save/restore, etc.)
    .replace(/\x1b[=>cDEHMNOZ()78]/g, '');
}

// Truncate to `width` visible columns, copying ANSI codes through
// verbatim (they take zero columns). Always closes with a reset to
// avoid bleeding colors past the rectangle edge.
export function truncateToWidth(s, width) {
  if (visibleLength(s) <= width) return s;
  let out = '';
  let visible = 0;
  let i = 0;
  while (i < s.length && visible < width) {
    if (s[i] === '\x1b' && s[i + 1] === '[') {
      let j = i + 2;
      while (j < s.length && !/[a-zA-Z]/.test(s[j])) j++;
      out += s.slice(i, j + 1);
      i = j + 1;
    } else {
      out += s[i];
      visible++;
      i++;
    }
  }
  return out + '\x1b[0m';
}

// --- Color palette ---
//
// Active only when stderr is a tty AND no NO_COLOR-style override is set.
// Falls back to empty strings otherwise so redirected, piped, or NO_COLOR
// output stays plain.
//
// The palette is chosen to be legible on both dark and light terminal
// backgrounds:
//
//   - green / red / magenta: default ANSI, work on both.
//   - orange (256-color 208) for warnings instead of yellow 33, which
//     is essentially invisible on a white background.
//   - failure glyph uses bg-color so the bg dominates either way.
//   - dim and bold are background-independent.
//
// NO_COLOR is the de facto standard (https://no-color.org); any value,
// including empty, disables colors. PLAYBASH_NO_COLOR is the local
// override for users who want colors elsewhere but not here.

const COLOR_ENABLED =
  process.stderr.isTTY &&
  !('NO_COLOR' in process.env) &&
  !('PLAYBASH_NO_COLOR' in process.env);

export const COLOR = COLOR_ENABLED
  ? {
      reset:   '\x1b[0m',
      bold:    '\x1b[1m',
      dim:     '\x1b[2m',
      green:   '\x1b[32m',
      red:     '\x1b[31m',
      orange:  '\x1b[38;5;208m',
      magenta: '\x1b[35m',
      // Failure marker: bold bright-white on red background. One glyph
      // wide so column 1 stays aligned with successful runs.
      fail:    '\x1b[1;97;41m',
    }
  : Object.fromEntries(
      ['reset', 'bold', 'dim', 'green', 'red', 'orange', 'magenta', 'fail'].map(k => [k, '']),
    );

// --- Status line builder (shared between single-host and fan-out) ---

// Short error / status messages shown after a ✗ glyph on a one-line row.
// 60 chars is the widest we'll render before truncating; long stack-trace-y
// error messages get cut off with an ellipsis so the reader can see at a
// glance that the tail was elided rather than suspecting it's the whole
// message. Callers use `truncateStatus` rather than hand-rolling the slice.
export const STATUS_WORD_MAX_LEN = 60;

export function truncateStatus(msg) {
  if (msg.length <= STATUS_WORD_MAX_LEN) return msg;
  return msg.slice(0, STATUS_WORD_MAX_LEN - 1) + '…';
}

export function buildStatusLine({ok, hostName, playbook, label, status, elapsed}) {
  const glyph = ok
    ? `${COLOR.green}✓${COLOR.reset}`
    : `${COLOR.fail}✗${COLOR.reset}`;
  const host = `${COLOR.bold}${hostName}${COLOR.reset}`;
  const tail = ok
    ? `${COLOR.dim}in ${elapsed}s${COLOR.reset}`
    : `${COLOR.bold}${COLOR.red}${status}${COLOR.reset} ${COLOR.dim}in ${elapsed}s${COLOR.reset}`;
  const localTag = label ? ` ${COLOR.dim}${label}${COLOR.reset}` : '';
  return `${glyph} ${host} ${playbook} ${tail}${localTag}`;
}

// --- Rectangle (single-host live view) ---

export class Rectangle {
  constructor(height) {
    this.height = height;
    this.committed = [];
    this.current = '';
    // Set when we see CR; cleared on the next byte. Allows us to treat
    // CRLF as a single line ending and a lone CR as a progress-bar
    // line-reset, even when the CR and the following byte arrive in
    // different chunks.
    this.pendingCR = false;
    this.active = process.stdout.isTTY && height > 0;
  }
  start() {
    if (!this.active) return;
    process.stdout.write('\n'.repeat(this.height));
  }
  feed(chunk) {
    const text = typeof chunk === 'string' ? chunk : chunk.toString('utf8');
    for (let i = 0; i < text.length; i++) {
      const ch = text[i];
      if (this.pendingCR) {
        this.pendingCR = false;
        if (ch === '\n') {
          // CRLF — line ending. Commit and continue.
          this.commit();
          continue;
        }
        // Lone CR — progress-bar style line reset. Fall through to
        // process the current byte as a fresh line.
        this.current = '';
      }
      if (ch === '\r') {
        this.pendingCR = true;
      } else if (ch === '\n') {
        this.commit();
      } else {
        this.current += ch;
      }
    }
    this.redraw();
  }
  commit() {
    this.committed.push(this.current);
    if (this.committed.length > this.height - 1) this.committed.shift();
    this.current = '';
  }
  redraw() {
    if (!this.active) return;
    const width = process.stdout.columns || 80;
    let out = `\x1b[${this.height}A`;
    for (let i = 0; i < this.height - 1; i++) {
      const line = this.committed[i] || '';
      out += '\r\x1b[2K' + truncateToWidth(line, width) + '\n';
    }
    out += '\r\x1b[2K' + truncateToWidth(this.current, width) + '\n';
    process.stdout.write(out);
  }
  finish() {
    if (!this.active) return;
    let out = `\x1b[${this.height}A`;
    for (let i = 0; i < this.height; i++) out += '\r\x1b[2K\n';
    out += `\x1b[${this.height}A`;
    process.stdout.write(out);
  }
}

// --- HostSlot + StatusBoard (multi-host fan-out live view) ---

// One host's slot in the StatusBoard. Each holds its own ring buffer
// (committed lines + in-progress current) so when focus shifts to it the
// rectangle can show its recent state without backfill from the log.
export class HostSlot {
  constructor(name, address, rectHeight) {
    this.name = name;
    this.address = address;
    this.state = 'pending';   // pending | running | ok | failed
    this.startedAt = 0;
    this.finishedAt = 0;
    this.lastActivityAt = 0;
    this.rectHeight = rectHeight;
    // Per-host ring buffer mirroring Rectangle's state.
    this.committed = [];
    this.current = '';
    this.pendingCR = false;
    this.statusWord = '';     // 'exit N' or 'signal X' once finished
    this.events = [];
    this.logPath = '';
    this.elapsedMs = 0;
    this.tail = [];           // last few non-blank output lines (failure context)
    this.capturedOutput = ''; // full sanitized output (for exec post-run display)
  }

  feed(text) {
    this.lastActivityAt = Date.now();
    for (let i = 0; i < text.length; i++) {
      const ch = text[i];
      if (this.pendingCR) {
        this.pendingCR = false;
        if (ch === '\n') {
          this.commit();
          continue;
        }
        this.current = '';
      }
      if (ch === '\r') {
        this.pendingCR = true;
      } else if (ch === '\n') {
        this.commit();
      } else {
        this.current += ch;
      }
    }
  }

  commit() {
    this.committed.push(this.current);
    if (this.committed.length > this.rectHeight - 1) this.committed.shift();
    this.current = '';
  }
}

// StatusBoard: in-place renderer for the multi-host fan-out view.
// Layout (top-down):
//
//   running daily on N hosts
//
//   <finished hosts, descending host name>
//   <running hosts, descending host name>
//     ▶ <focused running host>
//     <focused host's rect lines>
//
// Focus is the most-recently-active running host, sticky with a 500ms
// idle threshold to avoid thrashing when two hosts produce simultaneously.
export class StatusBoard {
  constructor(slots, {playbook, rectHeight}) {
    this.slots = slots;                                // input order, never reordered
    this.byName = new Map(slots.map(s => [s.name, s])); // name → slot
    this.playbook = playbook;
    this.rectHeight = rectHeight;
    this.active = process.stderr.isTTY;
    this.nameWidth = Math.max(...slots.map(s => s.name.length));
    this.headerLine = `running ${COLOR.bold}${playbook}${COLOR.reset} on ${slots.length} hosts`;
    this.focusName = null;
    // We reserve `slots.length + 1 (header) + 1 (blank) + rectHeight`
    // rows up front. Number stays fixed for the whole run; we just
    // re-render the same rows in place.
    this.totalRows = 1 + 1 + slots.length + (this.rectHeight > 0 ? 1 + this.rectHeight : 0);
    this.elapsedTimer = null;
  }

  start() {
    if (!this.active) {
      // Non-tty: just print the header once and let chunks fall on the floor.
      process.stderr.write(this.headerLine + '\n\n');
      return;
    }
    // Reserve total rows. Cursor ends one line below the reserved area,
    // which is our anchor.
    process.stderr.write('\n'.repeat(this.totalRows));
    this.draw();
    // Re-render once a second so elapsed times advance even when no
    // chunks arrive.
    this.elapsedTimer = setInterval(() => this.draw(), 1000);
  }

  hostStarted(name) {
    const slot = this.byName.get(name);
    slot.state = 'running';
    slot.startedAt = Date.now();
    slot.lastActivityAt = slot.startedAt;
    if (this.focusName === null) this.focusName = name;
    if (this.active) this.draw();
  }

  hostChunk(name, chunk) {
    const slot = this.byName.get(name);
    slot.feed(chunk);
    // Sticky focus: shift only if the current focus host has been idle
    // for more than 500ms.
    if (this.focusName !== name) {
      const focus = this.byName.get(this.focusName);
      const focusIdle = !focus || focus.state !== 'running' ||
        (Date.now() - focus.lastActivityAt) > 500;
      if (focusIdle) this.focusName = name;
    }
    if (this.active) this.draw();
  }

  hostFinished(name, summary) {
    const slot = this.byName.get(name);
    slot.state = summary.ok ? 'ok' : 'failed';
    slot.finishedAt = Date.now();
    slot.statusWord = summary.statusWord;
    slot.events = summary.events;
    slot.logPath = summary.logPath;
    slot.elapsedMs = summary.elapsedMs;
    slot.tail = summary.tail || [];
    slot.capturedOutput = summary.capturedOutput || '';
    // If focused host just finished, pass focus to whichever running
    // host has been most recently active.
    if (this.focusName === name) {
      const running = this.slots.filter(s => s.state === 'running');
      if (running.length > 0) {
        running.sort((a, b) => b.lastActivityAt - a.lastActivityAt);
        this.focusName = running[0].name;
      } else {
        this.focusName = null;
      }
    }
    if (this.active) this.draw();
  }

  // Sort: finished first, then running. Within each group, descending
  // host name. The user said "descending"; alphabetically that means z→a.
  // Among finished, finished-ok and finished-failed are interleaved.
  sortedSlots() {
    const finished = this.slots
      .filter(s => s.state === 'ok' || s.state === 'failed')
      .slice()
      .sort((a, b) => b.name.localeCompare(a.name));
    const running = this.slots
      .filter(s => s.state === 'running' || s.state === 'pending')
      .slice()
      .sort((a, b) => b.name.localeCompare(a.name));
    return [...finished, ...running];
  }

  // Format one slot row (no leading spaces; aligned host name).
  slotRow(slot, isFocus) {
    let glyph;
    if (slot.state === 'ok') {
      glyph = `${COLOR.green}✓${COLOR.reset}`;
    } else if (slot.state === 'failed') {
      glyph = `${COLOR.fail}✗${COLOR.reset}`;
    } else if (slot.state === 'pending') {
      glyph = `${COLOR.dim}·${COLOR.reset}`;
    } else if (isFocus) {
      glyph = `${COLOR.magenta}▶${COLOR.reset}`;
    } else {
      glyph = `${COLOR.dim}·${COLOR.reset}`;
    }
    const name = `${COLOR.bold}${slot.name.padEnd(this.nameWidth)}${COLOR.reset}`;
    let tail;
    if (slot.state === 'ok') {
      tail = `${COLOR.dim}in ${(slot.elapsedMs / 1000).toFixed(1)}s${COLOR.reset}`;
    } else if (slot.state === 'failed') {
      tail = `${COLOR.bold}${COLOR.red}${slot.statusWord}${COLOR.reset} ${COLOR.dim}in ${(slot.elapsedMs / 1000).toFixed(1)}s${COLOR.reset}`;
    } else if (slot.state === 'running') {
      const sec = ((Date.now() - slot.startedAt) / 1000).toFixed(0);
      tail = `${COLOR.dim}running ${sec}s${COLOR.reset}`;
    } else {
      tail = `${COLOR.dim}pending${COLOR.reset}`;
    }
    return `${glyph} ${name} ${tail}`;
  }

  draw() {
    if (!this.active) return;
    const sorted = this.sortedSlots();
    let out = `\x1b[${this.totalRows}A`; // up to top of reserved area
    // Header line.
    out += `\r\x1b[2K${this.headerLine}\n`;
    // Blank separator.
    out += '\r\x1b[2K\n';
    // Slot rows.
    for (const slot of sorted) {
      const isFocus = slot.name === this.focusName;
      out += '\r\x1b[2K' + this.slotRow(slot, isFocus) + '\n';
    }
    // Separator + focused rectangle (1 + rectHeight rows). The focused
    // slot's ring buffer fills the area; non-focused or no-focus shows blanks.
    if (this.rectHeight > 0) {
      out += '\r\x1b[2K' + COLOR.dim + '─'.repeat(Math.min(process.stdout.columns || 80, 40)) + COLOR.reset + '\n';
      const focus = this.focusName ? this.byName.get(this.focusName) : null;
      const width = (process.stdout.columns || 80) - 2; // 2-space indent
      for (let i = 0; i < this.rectHeight; i++) {
        let line = '';
        if (focus) {
          if (i < this.rectHeight - 1) {
            line = focus.committed[i] || '';
          } else {
            line = focus.current;
          }
        }
        out += '\r\x1b[2K  ' + truncateToWidth(line, width) + '\n';
      }
    }
    process.stderr.write(out);
  }

  finish() {
    if (this.elapsedTimer) {
      clearInterval(this.elapsedTimer);
      this.elapsedTimer = null;
    }
    if (!this.active) return;
    // Erase the reserved area and park the cursor at its top, so the
    // post-run summary prints exactly where the board was.
    let out = `\x1b[${this.totalRows}A`;
    for (let i = 0; i < this.totalRows; i++) out += '\r\x1b[2K\n';
    out += `\x1b[${this.totalRows}A`;
    process.stderr.write(out);
  }
}
