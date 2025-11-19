## Quick orientation for AI code assistants

This repository is a collection of Proxmox LXC/VM helper scripts (shell) plus a small Go API. Below are focused, actionable facts an AI agent needs to be productive here.

1) Big picture / components
- `ct/` — the canonical installers/configurers. Each `ct/<app>.sh` is a self-contained installer with a small common contract: they `source` shared functions and then call `start` / `build_container` / `install_script` etc. Example: `ct/adguard.sh` sources `misc/build.func`.
- `misc/*.func` — shared function libraries. Scripts typically `source <(curl -fsSL https://raw.githubusercontent.com/the-guong/Proxmox/main/misc/<file>.func)` at runtime. Key files: `misc/build.func`, `misc/api.func`, `misc/core.func`, `misc/install.func`.
- `api/` — a small Go HTTP server (see `api/main.go`) that writes/reads to MongoDB. It expects environment variables: `MONGO_USER`, `MONGO_PASSWORD`, `MONGO_IP`, `MONGO_PORT`, `MONGO_DATABASE`.
- `/.devcontainer` — lightweight devcontainer for shell script development (includes `shellcheck`, `shfmt`, `jq`, basic CLI tools). Note: the container is intentionally not Go-focused.

2) Why things are structured this way
- The `ct/` scripts target Proxmox nodes (arm64) and rely on a set of shared remote helper functions to keep each installer small. This means many behaviors are implemented by shared remote code; changes must consider the remote contract.
- The repo is a fork tailored for arm64 boards and backward compatibility; build checks and environment validations (e.g. `pve_check`) are enforced in `misc/build.func`.

3) Important conventions and patterns (concrete, discoverable)
- Shell is bash-first. Scripts check for `bash` and set `set -Eeo pipefail` in `catch_errors()` (see `misc/build.func`). Prefer bash-compatible edits.
- Variable naming: scripts use `var_*` for defaults and then populate runtime variables via `variables()` and `base_settings()` (see `misc/build.func`). Example: `var_os`, `var_version`, `var_cpu`, `var_ram`.
- Main lifecycle functions to expect in `ct/<app>.sh`: `header_info`, `variables`, `color`, `catch_errors`, `start`, `build_container`, `install_script`, `description`.
- Scripts often print color codes and interpolate placeholders like `${IP}`, `${CL}`. When extracting strings (URLs, ports) you may see embedded placeholders — expand only when a config is present or use safe sanitization.
- Remote sourcing: many core behaviors are loaded at runtime from raw GitHub URLs. Avoid blindly inlining or removing those calls — treat remote `misc/*.func` as part of the runtime contract.

4) Developer workflows & commands (how humans run and test things)
- Static editing / linting: open in the provided devcontainer (recommended). The container includes `shellcheck` and `shfmt` for formatting and linting.
  - Reopen in container: VS Code: Remote-Containers → Reopen in Container.
  - Lint: `shellcheck ct/<script>.sh`
  - Format: `shfmt -w ct/<script>.sh`
- Running a CT script: these scripts are intended to run on a Proxmox node (they call `pveversion`, `pct`, `pct exec`, etc.). On a dev machine, avoid executing LXC creation steps. For safe testing, inspect the functions and run only non-destructive parts (e.g., `variables`, `header_info`).
- New test helper: `tests/test_adguard_urls.sh` — script that extracts HTTP/S URLs from `ct/adguard.sh`, attempts DNS resolution and small GETs. Use it as an example for writing repository-level validators.
- API (Go): to run locally for development, set the Mongo env vars and run:
  - `go run ./api` or `cd api && go run main.go`
  - Or build: `go build -o bin/api ./api && MONGO_USER=... MONGO_PASSWORD=... ./bin/api`

5) Integration points & external dependencies
- Remote raw GitHub resources: most `ct/` scripts rely on `https://raw.githubusercontent.com/the-guong/Proxmox/main/misc/*.func` (and other raw files). When changing a script, ensure you preserve the expected function names and exports.
- Proxmox tooling: `pvesh`, `pct`, `pct exec`, `pveversion` are used heavily — many flows only work when executed on a Proxmox host.
- Diagnostics/API: scripts call `post_to_api()` (see `misc/api.func`) that posts JSON to `http://api.community-scripts.org/upload`. That behavior is gated by `DIAGNOSTICS` and `RANDOM_UUID`.

6) Typical modification patterns an agent will be asked to do
- Update/extend a single `ct/<app>.sh` installer: read `misc/build.func` first to understand lifecycle hooks and variable defaults, then update the script logic preserving calls to `header_info`, `variables`, and `start`.
- Add repository-level checks: place small helper scripts in `tests/` (see `tests/test_adguard_urls.sh`) and wire them into CI (if requested).
- API changes: modify `api/main.go` and update README dev notes; ensure Mongo env vars are documented in `.env` or CI secrets.

7) Files to check first for context
- `misc/build.func` — master shared behavior and runtime checks (PVE version, arch, network checks).
- `ct/<example>.sh` (e.g., `ct/adguard.sh`) — typical installer entrypoint to mirror for new scripts.
- `api/main.go` — small Go API that writes to Mongo; check for env var expectations and endpoints.
- `.devcontainer/README.md` — how the devcontainer is set up for shell linting.

## Do / Don't checklist

Do
- Read `misc/build.func` before editing any `ct/` script — it defines lifecycle hooks, error handling, platform checks (`pve_check`, `arch_check`) and the `post_to_api` contract.
- Preserve calls to the shared lifecycle functions used by `ct/*` scripts: `header_info`, `variables`, `catch_errors`, `start`, `build_container`, `install_script`, `description`.
- Use the devcontainer for shell edits and linting: run `shellcheck ct/<script>.sh` and `shfmt -w ct/<script>.sh` before committing.
- When adding tests or validators, place them under `tests/` (see `tests/test_adguard_urls.sh`) and make them non-destructive by default (print URLs, dry-run mode, or skip container creation).

Don't
- Don't inline or remove remotely-sourced `misc/*.func` logic without understanding the runtime contract — many scripts rely on exported functions from those remote files.
- Don't run `build_container` or `install_script` locally unless you're on a Proxmox host and understand the side-effects (LXC creation, network changes, reboot prompts).
- Don't use unsafe `eval` to expand placeholders from scripts — prefer `envsubst` or explicit variable expansion after sourcing a trusted config file.

## Remote sourcing — important note

- The repository frequently sources helper libraries from the raw GitHub path:

  `https://raw.githubusercontent.com/the-guong/Proxmox/main`

  This is the canonical remote; many `ct/` scripts run `source <(curl -fsSL https://raw.githubusercontent.com/the-guong/Proxmox/main/misc/<file>.func)` at runtime. When editing, remember:
  - Locally the scripts reference files in the repository root (e.g., `ct/adguard.sh` uses `source <(curl -fsSL https://raw.githubusercontent.com/the-guong/Proxmox/main/misc/build.func)`) — treat the remote files as part of the runtime contract.
  - If you need to change a shared behaviour, either update the remote `misc/*.func` upstream or mirror the change and keep function names/arguments compatible.

If anything above is unclear or you want me to expand a section (for example, generate a CI job that runs `tests/test_adguard_urls.sh`, or add machine-readable outputs for the test script), tell me which area to expand and I'll iterate. 
