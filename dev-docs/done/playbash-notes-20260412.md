# playbash notes

## Small tasks

- ~~`playbash push all` in Workflows-remote wiki was wrong (missing script path, wrong description). Fixed.~~

## Sudo for get/put

`get` and `put` should support `--sudo` so they can read/write system files that require elevated privileges on the remote host.

Open question: what about **local** sudo? Two cases:

- `put` needs to read a local system file that requires sudo.
- `get` needs to write to a local path that requires sudo.

These are rare and have trivial workarounds (`sudo cp` the file to a regular location first), so they may not be worth automating.

Running `sudo playbash ...` is a bad idea — session logs, staging dirs, and caches would be owned by root.

Needs a detailed plan covering `--sudo` for remote `get`/`put` and whether local sudo is worth supporting.
