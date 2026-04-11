# Bash completion with rich descriptions

A reusable note on how to make bash tab-completion show `match  (description)` rows in the menu — the same way `kubectl`, `helm`, `gh`, `pet`, and every other cobra-based CLI does it. The technique works in plain bash (no third-party dependencies, no different shell), but it relies on a couple of bash quirks that aren't obvious from the man page. This doc captures the mechanism, the gotchas, and a minimal reference implementation we can copy-paste into any project in this repo.

## Why

Tab-completion in bash is fundamentally a string-replacement mechanism: whatever ends up in the `COMPREPLY` array is exactly what bash will insert into the command line. So the obvious approach — putting `"name (description)"` in `COMPREPLY` — would corrupt the inserted command.

But we *do* want descriptions in the menu, for two reasons:

1. **Disambiguation.** When multiple candidates share a prefix, a one-line annotation tells the user which one they want without forcing them to remember the difference (`croc (inventory)` vs `croc-prod (ssh-only)`).
2. **Discoverability.** When the user has typed nothing and just wants to see what's available, the menu can act like inline documentation.

The rich completion shown below is the standard answer.

## The fundamental constraint

`COMPREPLY` serves a dual purpose. When bash decides to **insert** a completion (because there's exactly one match, or because the user is cycling with menu-complete), it inserts the literal string from `COMPREPLY`. When bash decides to **display** a list (because there are multiple matches and the user pressed tab a second time), it shows each entry as a row in the menu.

So we have two states with conflicting requirements:

- **Insert state**: `COMPREPLY` must contain bare matches with no extra text.
- **Display state**: `COMPREPLY` *can* contain `match  (description)` rows because bash will only show them, not insert them.

The trick is to detect which state we're in and shape `COMPREPLY` accordingly.

## The two key insights

### 1. `COMP_TYPE` tells you the mode

Bash exports `$COMP_TYPE` to the completion function. The value is the ASCII code of the character that triggered completion:

| Value | Decimal | Meaning |
|---|---|---|
| `?` | 63 | List options on a second TAB |
| `!` | 33 | List options on first TAB if multiple matches |
| `@` | 64 | List options if any match (the menu we care about) |
| `*` | 42 | Insert all matches at once (`insert-completions`) |
| `%` | 37 | Cycle through matches (`menu-complete`) |
| (none) | 9 | Plain TAB — insert if unique, otherwise list |

For our purposes, the relevant split is:

- **`COMP_TYPE` is `9` or `63`/`64` (TAB-TAB list)** — bash will *display* the entries. Rich descriptions are safe.
- **`COMP_TYPE` is `37` (menu-complete) or `42` (insert-completions)** — bash will *insert* one or all entries. Descriptions must be stripped, otherwise they end up in the command line.

### 2. Single-match collapse

Even in the "list" mode, there's an edge case: if the prefix has narrowed down to exactly one candidate, bash will insert it instead of showing a one-row menu. So before returning from the completion function, check `${#COMPREPLY[@]}` and strip the description from a lone entry.

These two checks together cover every code path: descriptions appear in the menu when there's ambiguity, and disappear (without the user noticing) the moment a single match wins.

## The producer/consumer split

The cleanest way to plumb this is to use a **tab character** as the separator between the match and its description, and keep tab-separated entries internally until the very last step:

```text
croc<TAB>inventory
mini<TAB>inventory
work-vpn<TAB>ssh-only
```

The completion function loads entries in this format into a temporary array, filters by prefix, then formats `COMPREPLY` for display or insertion based on the two checks above. Tab is a good separator because it never appears in shell-safe identifiers (host names, file paths without escaping, command names) and it's easy to split with `${var%%$tab*}` / `${var#*$tab}` parameter expansion.

## Reference implementation

Drop this into a completion script. It's about 50 lines of bash, no external commands beyond `printf`. Replace `_myprog_emit_candidates` with whatever produces your `match\tdescription` lines.

```bash
# Helper: format COMPREPLY entries for either display or insertion.
#
# Input: COMPREPLY contains entries of the form `match<TAB>description`.
#        Already filtered by prefix against $cur.
#
# Output: COMPREPLY is rewritten in-place. In the multi-match list-display
#         case, each entry becomes `match<padding>  (description)`. In the
#         single-match insert case, the description is stripped so the
#         inserted text is clean. Menu-complete (COMP_TYPE 37/42) also
#         strips, since each TAB inserts a candidate.
__myprog_format_descriptions() {
  local tab=$'\t' i comp match desc longest=0

  # Menu-complete and insert-completions: strip every description.
  if [[ $COMP_TYPE == 37 || $COMP_TYPE == 42 ]]; then
    for i in "${!COMPREPLY[@]}"; do
      COMPREPLY[i]=${COMPREPLY[i]%%$tab*}
    done
    return
  fi

  # Single match: strip its description so the inserted text is clean.
  if (( ${#COMPREPLY[@]} == 1 )); then
    COMPREPLY[0]=${COMPREPLY[0]%%$tab*}
    return
  fi

  # Multi-match menu: pad matches to equal width, then append (description).
  for comp in "${COMPREPLY[@]}"; do
    match=${comp%%$tab*}
    (( ${#match} > longest )) && longest=${#match}
  done
  for i in "${!COMPREPLY[@]}"; do
    comp=${COMPREPLY[i]}
    match=${comp%%$tab*}
    desc=${comp#*$tab}
    if [[ $comp == *$tab* ]]; then
      printf -v 'COMPREPLY[i]' '%-*s  (%s)' "$longest" "$match" "$desc"
    fi
  done
}

# Example completion function that uses it.
_myprog() {
  local cur tab=$'\t'
  cur="${COMP_WORDS[COMP_CWORD]}"

  # Producer: emit `match<TAB>description` lines, one per candidate.
  # Filter by prefix here; the formatter doesn't re-filter.
  COMPREPLY=()
  while IFS='' read -r line; do
    [[ -z $line ]] && continue
    [[ ${line%%$tab*} == "$cur"* ]] && COMPREPLY+=("$line")
  done < <(_myprog_emit_candidates)

  __myprog_format_descriptions
}

complete -F _myprog myprog
```

## Gotchas

**Word breaks in displayed entries.** The padded `match    (description)` rows contain spaces, which bash treats as word-break characters by default when computing what to insert. The single-match collapse handles the common case (we strip the description before bash inserts), but if a user manages to land on a multi-match state where bash decides to insert a partial match anyway, the spaces would corrupt things. Cobra works around this with `compopt -o nospace` and a `__handle_special_char` helper. For most uses you can ignore the issue — but if you see weird half-inserted lines, that's where to look.

**`compopt -o filenames` is incompatible.** If you use `compopt -o filenames` to make directories tab-continue with `/`, bash will try to stat each `COMPREPLY` entry. With descriptions in there, the stat fails and the trailing-`/` magic stops working. So rich descriptions and filename completion don't mix in the same branch. Pick one per branch of your dispatcher.

**`compopt -o nosort`.** Bash sorts `COMPREPLY` alphabetically by default, which is usually fine. If you want the description groupings to stay in source order (e.g. inventory hosts first, then ssh-only), call `compopt -o nosort` early in the function. Optional.

**Description length.** Multi-match rows are padded to the longest *match*, not the longest description. Long descriptions wrap awkwardly in narrow terminals. The cobra full-fat version truncates descriptions to `$COLUMNS - longest - 4` and appends `…`. For projects where descriptions are short and predictable (one-word source tags, command verbs), the truncation isn't worth the extra code.

**Producer must filter.** The formatter does not re-filter `COMPREPLY` against `$cur` — that's the producer's job. If you forget the prefix check before pushing into `COMPREPLY`, you'll get every candidate in the menu regardless of what the user typed.

**Tab in payloads.** Tab is a poor separator if your matches or descriptions can contain literal tabs. They almost never do in practice (host names, command names, file paths), but if you find yourself wanting tab-in-payload, switch the separator to `\x1f` (ASCII unit separator) or similar.

## When *not* to use this

The minimal version is ~50 lines of bash that almost nobody will look at again until something breaks. The pattern is correct, but the maintenance asymmetry is real. Skip rich descriptions if:

- **The candidate set is small and the names are self-describing.** A handful of memorable host names doesn't benefit from `(inventory)` annotations as much as a hundred kubectl resource types does.
- **The disambiguation information lives somewhere else that's easy to reach.** If `myprog list` already shows the categorization, the user can fall back to that instead of needing it inline.
- **You don't already have an interactive use case justifying the complexity.** Don't add it speculatively.

If those conditions hold, prefer plain `compgen -W` and let users disambiguate by running a list command separately.

## When this *is* the right answer

- The candidate set is large (dozens to hundreds).
- Names alone aren't enough — users need a one-word category, type, or status to pick correctly.
- The cost of picking wrong is non-trivial (running the wrong subcommand, targeting the wrong host, etc.).
- You're already shipping a custom completion script, so the marginal cost of 50 more lines is small.

## References

- **Cobra completion v2 (Go).** The reference implementation this doc is derived from. Source: <https://github.com/spf13/cobra/blob/main/bash_completionsV2.go>. Look for `__complete`, `bashCompletionFormatDescriptions`, and the `__handle_completion_types` shell function.
- **`bash(1)` manual, "Programmable Completion".** The authoritative source on `COMPREPLY`, `COMP_TYPE`, `compgen`, `compopt`, `complete`. Worth re-reading every time you touch a completion script.
- **Real-world examples.** Pet, kubectl, helm, hugo, gh — all cobra-based CLIs that ship the same pattern. To inspect: `<tool> completion bash` prints the script. The interesting bits are usually under `__<tool>_handle_standard_completion_case` and `__<tool>_format_comp_descriptions`.
