#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REPO="${CLI_INSTALL_REPO:-PromakerDev/promaker-cli-scripts}"
DEFAULT_REF="${CLI_INSTALL_REF:-v1.2.16}"
BRAND_SLUG="${CLI_BRAND_SLUG:-promaker}"
BIN_NAME="${CLI_BIN_NAME:-promaker}"
BRAND_NAME="${CLI_BRAND_NAME:-${BIN_NAME:-${BRAND_SLUG:-cli}}}"
CONFIG_DIR_NAME="${CLI_CONFIG_DIR_NAME:-promaker}"
PACKAGE_SCOPE_DEFAULT="${CLI_PACKAGE_SCOPE:-@promakerdev}"
PACKAGE_NAME_DEFAULT="${CLI_PACKAGE_NAME:-promaker-cli}"

SCRIPT_PATH="${BASH_SOURCE[0]:-}"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd || pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/setup-private-registry.sh"

SHELL_NAME=""
REPO_SLUG="$DEFAULT_REPO"
REF_NAME="$DEFAULT_REF"
SETUP_SCRIPT_URL=""
declare -a SETUP_ARGS=()
TMP_SETUP_SCRIPT=""

print_help() {
  cat <<'USAGE'
Install branded CLI end-to-end:
1) Configure private npm registry and install package globally
2) Configure shell autocomplete automatically
3) Run `<bin> config init`
4) Run `<bin> doctor` as final verification

Usage:
  ./scripts/install.sh [options]
  curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/<ref>/scripts/install.sh | bash

Options:
  --shell <zsh|bash>     Shell for autocomplete setup (default: detect from $SHELL)
  --repo <owner/repo>    Repo used to fetch setup script when running via curl (default: CLI_INSTALL_REPO)
  --ref <git-ref>        Git ref used to fetch setup script (default: main)
  --setup-script-url     Full URL for setup-private-registry.sh (overrides --repo/--ref)
  --scope <scope>        Forwarded to setup-private-registry.sh
  --registry <url>       Forwarded to setup-private-registry.sh
  --userconfig <path>    Forwarded to setup-private-registry.sh
  --package <name>       Forwarded to setup-private-registry.sh
  -h, --help             Show this help
USAGE
}

detect_shell() {
  if [[ -n "$SHELL_NAME" ]]; then
    echo "$SHELL_NAME"
    return
  fi

  local detected
  detected="$(basename "${SHELL:-}")"
  case "$detected" in
    zsh|bash)
      echo "$detected"
      ;;
    *)
      echo "zsh"
      ;;
  esac
}

resolve_cli_bin() {
  local bin_name="${BIN_NAME:-}"
  if [[ -z "$bin_name" ]]; then
    if [[ -n "$PACKAGE_NAME_DEFAULT" ]]; then
      bin_name="$(echo "$PACKAGE_NAME_DEFAULT" | sed -E 's#^.*/##' | sed 's/-cli$//')"
    elif [[ -n "$PACKAGE_SCOPE_DEFAULT" ]]; then
      bin_name="$(echo "$PACKAGE_SCOPE_DEFAULT" | sed 's/^@//')"
    else
      bin_name="cli"
    fi
  fi

  if command -v "$bin_name" >/dev/null 2>&1; then
    command -v "$bin_name"
    return
  fi

  local global_prefix
  global_prefix="$(npm config get prefix 2>/dev/null || true)"
  if [[ -n "$global_prefix" && -x "$global_prefix/bin/$bin_name" ]]; then
    echo "$global_prefix/bin/$bin_name"
    return
  fi

  echo "Unable to find '$bin_name' after install. Ensure your npm global bin is in PATH." >&2
  exit 1
}

cleanup() {
  if [[ -n "$TMP_SETUP_SCRIPT" && -f "$TMP_SETUP_SCRIPT" ]]; then
    rm -f "$TMP_SETUP_SCRIPT"
  fi
}

ensure_setup_script() {
  if [[ -x "$SETUP_SCRIPT" ]]; then
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to download setup-private-registry.sh when running remotely." >&2
    exit 1
  fi

  local url="$SETUP_SCRIPT_URL"
  if [[ -z "$url" ]]; then
    if [[ -z "$REPO_SLUG" ]]; then
      echo "No script source repository provided. Set --repo/--setup-script-url or CLI_INSTALL_REPO." >&2
      exit 1
    fi
    url="https://raw.githubusercontent.com/${REPO_SLUG}/${REF_NAME}/scripts/setup-private-registry.sh"
  fi

  TMP_SETUP_SCRIPT="$(mktemp -t cli-setup-private-registry.XXXXXX.sh)"
  curl -fsSL "$url" -o "$TMP_SETUP_SCRIPT"
  chmod +x "$TMP_SETUP_SCRIPT"
  SETUP_SCRIPT="$TMP_SETUP_SCRIPT"
}

setup_autocomplete() {
  local cli_bin="$1"
  local shell_name="$2"
  local rc_file=""
  local marker_bin
  marker_bin="$(basename "$cli_bin")"

  case "$shell_name" in
    zsh)
      rc_file="$HOME/.zshrc"
      ;;
    bash)
      rc_file="$HOME/.bashrc"
      ;;
    *)
      echo "Unsupported shell '$shell_name' for automatic autocomplete setup." >&2
      echo "Run manually: $cli_bin autocomplete $shell_name" >&2
      return
      ;;
  esac

  "$cli_bin" autocomplete "$shell_name" --refresh-cache >/dev/null 2>&1 || true

  local snippet
  snippet="$("$cli_bin" autocomplete script "$shell_name" | sed '/^[[:space:]]*$/d' | tail -n 1)"
  if [[ -z "$snippet" ]]; then
    echo "Could not generate autocomplete script for shell '$shell_name'." >&2
    return
  fi

  touch "$rc_file"
  if grep -Fq "# ${marker_bin} autocomplete setup" "$rc_file"; then
    echo "Autocomplete already configured in $rc_file"
  else
    printf "\n%s\n" "$snippet" >> "$rc_file"
    echo "Added autocomplete setup to $rc_file"
  fi

  echo "Open a new terminal session (or run 'source $rc_file') to load autocomplete."
}

run_config_init() {
  local cli_bin="$1"
  local config_dir="${CONFIG_DIR_NAME:-${BIN_NAME:-cli}}"
  local config_path="${HOME}/.config/${config_dir}/config.json"

  if [[ -f "$config_path" ]]; then
    if [[ -t 0 ]]; then
      local answer
      read -r -p "Global config already exists at $config_path. Overwrite with --force? [y/N] " answer
      if [[ "$answer" =~ ^[Yy]$ ]]; then
        "$cli_bin" config init --force
      else
        echo "Skipping '$cli_bin config init'."
      fi
      return
    fi

    echo "Skipping '$cli_bin config init' because config already exists at $config_path."
    return
  fi

  "$cli_bin" config init
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell)
      SHELL_NAME="$2"
      shift 2
      ;;
    --repo)
      REPO_SLUG="$2"
      shift 2
      ;;
    --ref)
      REF_NAME="$2"
      shift 2
      ;;
    --setup-script-url)
      SETUP_SCRIPT_URL="$2"
      shift 2
      ;;
    --scope|--registry|--userconfig|--package)
      SETUP_ARGS+=("$1" "$2")
      shift 2
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      print_help
      exit 1
      ;;
  esac
done

trap cleanup EXIT
ensure_setup_script

echo "Step 1/4: configuring private npm registry and installing ${BRAND_NAME} CLI package..."
if [[ ${#SETUP_ARGS[@]} -gt 0 ]]; then
  "$SETUP_SCRIPT" "${SETUP_ARGS[@]}" --install
else
  "$SETUP_SCRIPT" --install
fi

CLI_BIN="$(resolve_cli_bin)"
SELECTED_SHELL="$(detect_shell)"

echo "Step 2/4: configuring autocomplete for $SELECTED_SHELL..."
setup_autocomplete "$CLI_BIN" "$SELECTED_SHELL"

echo "Step 3/4: running '$CLI_BIN config init'..."
run_config_init "$CLI_BIN"

echo "Step 4/4: running '$CLI_BIN doctor'..."
"$CLI_BIN" doctor

echo "Installation completed."
echo "To uninstall later, run scripts/uninstall.sh (or the published uninstall.sh from your scripts repo)."
