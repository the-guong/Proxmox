Debugging and template download notes

This file documents how the template download logic works and how to debug it.

1) Purpose

- The `create_lxc.sh` script selects and downloads LXC templates for container creation.
- It uses `PCT_OSTYPE` and `PCT_OSVERSION` (exported by `build.func`) to determine the correct template variant.

2) Common variables

- `PCT_OSTYPE` — operating system family (e.g., `debian`, `alpine`).
- `PCT_OSVERSION` — OS version or codename. Numeric (12) or codename (bookworm) are accepted.
- `TEMPLATE_VARIANT` — the internal name used to select the template (e.g., `bookworm`).
- `TEMPLATE_PATH` — path on disk where the template will be stored.

3) Debugging (quick checks)

- Enable verbose debug messages by exporting `VERBOSE=yes` before running the top-level script. Debug lines are printed with `[DEBUG]` prefix.

- To test how the GitHub asset URL is resolved for Debian templates (locally):

```bash
TEMPLATE_VARIANT=bookworm
curl -s https://api.github.com/repos/the-guong/debian-ifupdown2-lxc/releases/latest \
  | grep download \
  | grep "debian-$TEMPLATE_VARIANT-arm64-rootfs.tar.xz" \
  | cut -d\" -f4
```

If this prints a URL, downloading should work. If it prints nothing, the release doesn't contain that asset.

4) Common failure modes

- "wget: missing URL" — usually the asset couldn't be found (empty URL). Run with `VERBOSE=yes` and inspect `[DEBUG] Resolved dl_url=` in `create_lxc.sh`.

- "numeric argument required" on exit — previously caused by calling `exit "message"`. The code now uses numeric exit codes (e.g., 208) and prints messages via `msg_error` before exiting.

5) Notes about versions

- The scripts accept `var_version` as either a number (e.g., `12`) or a codename (e.g., `bookworm`).
- `build.func` sanitizes leading hyphens (for accidental input like `-12`) before exporting `PCT_OSVERSION`.

6) If you still see errors

- Paste the exact error output here (with VERBOSE enabled if possible) and I will iterate further.

---
