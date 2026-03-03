#!/usr/bin/env bash
set -euo pipefail

REGISTRY_URL="${CLI_PACKAGE_REGISTRY:-https://npm.pkg.github.com}"
NPMRC_PATH="${NPM_CONFIG_USERCONFIG:-$HOME/.npmrc}"
BRAND_SLUG="${CLI_BRAND_SLUG:-promaker}"
BIN_NAME="${CLI_BIN_NAME:-promaker}"
CONFIG_DIR_NAME="${CLI_CONFIG_DIR_NAME:-promaker}"
DEFAULT_SCOPE="${CLI_PACKAGE_SCOPE:-@promakerdev}"
DEFAULT_PACKAGE_BASENAME="${CLI_PACKAGE_NAME:-promaker-cli}"

SCOPE=""
PACKAGE_NAME=""
TARGET_SHELL="all"
PURGE_CONFIG="false"
PURGE_REGISTRY="false"
ASSUME_YES="false"

print_help() {
  cat <<'USAGE'
Uninstall branded CLI:
1) Uninstall global npm package
2) Remove shell autocomplete snippet
3) Optionally remove global config directory
4) Optionally remove npm registry/auth entries

Usage:
  ./scripts/uninstall.sh [options]
  curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/<ref>/scripts/uninstall.sh | bash

Options:
  --scope <scope>         npm scope (example: @acme)
  --package <name>        full npm package name (example: @acme/platform-cli)
  --bin <name>            binary name to clean autocomplete marker
  --config-dir <name>     config dir inside ~/.config to remove with --purge-config
  --shell <all|zsh|bash>  shell rc file(s) to clean autocomplete (default: all)
  --registry <url>        npm registry URL used for auth token key cleanup
  --userconfig <path>     npm user config path (default: ~/.npmrc)
  --purge-config          remove ~/.config/<config-dir>
  --purge-registry        remove npm scope registry and registry auth token entries
  -y, --yes               skip interactive confirmations
  -h, --help              show this help
USAGE
}

parse_scope_from_remote() {
  local remote_url
  remote_url="$(git config --get remote.origin.url 2>/dev/null || true)"
  if [[ -z "$remote_url" ]]; then
    return 1
  fi

  local owner
  owner="$(echo "$remote_url" | sed -E 's#(git@github.com:|https://github.com/|ssh://git@github.com/)([^/]+)/.*#\2#')"
  if [[ -z "$owner" || "$owner" == "$remote_url" ]]; then
    return 1
  fi

  echo "@$(echo "$owner" | tr '[:upper:]' '[:lower:]')"
  return 0
}

normalize_scope() {
  local value="$1"
  if [[ -z "$value" ]]; then
    echo ""
    return
  fi

  if [[ "$value" != @* ]]; then
    value="@$value"
  fi

  echo "$value"
}

resolve_scope() {
  if [[ -n "$SCOPE" ]]; then
    SCOPE="$(normalize_scope "$SCOPE")"
    return
  fi

  if [[ -n "$PACKAGE_NAME" && "$PACKAGE_NAME" == @*/* ]]; then
    SCOPE="${PACKAGE_NAME%%/*}"
    return
  fi

  if [[ -n "$DEFAULT_SCOPE" ]]; then
    SCOPE="$(normalize_scope "$DEFAULT_SCOPE")"
    return
  fi

  if SCOPE="$(parse_scope_from_remote 2>/dev/null)"; then
    SCOPE="$(normalize_scope "$SCOPE")"
    return
  fi

  if [[ -n "$BRAND_SLUG" ]]; then
    SCOPE="@$BRAND_SLUG"
    return
  fi
}

resolve_package_name() {
  if [[ -n "$PACKAGE_NAME" ]]; then
    return
  fi

  local basename="$DEFAULT_PACKAGE_BASENAME"
  if [[ -z "$basename" ]]; then
    if [[ -n "$BRAND_SLUG" ]]; then
      basename="${BRAND_SLUG}-cli"
    elif [[ -n "$SCOPE" ]]; then
      basename="$(echo "$SCOPE" | sed 's/^@//')-cli"
    else
      basename="cli"
    fi
  fi

  if [[ "$basename" == @*/* ]]; then
    PACKAGE_NAME="$basename"
    return
  fi

  if [[ -n "$SCOPE" ]]; then
    PACKAGE_NAME="${SCOPE}/${basename}"
  else
    PACKAGE_NAME="$basename"
  fi
}

resolve_bin_name() {
  if [[ -n "$BIN_NAME" ]]; then
    return
  fi

  if [[ -n "$PACKAGE_NAME" ]]; then
    BIN_NAME="$(echo "$PACKAGE_NAME" | sed -E 's#^.*/##' | sed 's/-cli$//')"
  elif [[ -n "$SCOPE" ]]; then
    BIN_NAME="$(echo "$SCOPE" | sed 's/^@//')"
  else
    BIN_NAME="cli"
  fi
}

resolve_config_dir_name() {
  if [[ -n "$CONFIG_DIR_NAME" ]]; then
    return
  fi

  if [[ -n "$BIN_NAME" ]]; then
    CONFIG_DIR_NAME="$BIN_NAME"
  else
    CONFIG_DIR_NAME="cli"
  fi
}

confirm() {
  local prompt="$1"
  if [[ "$ASSUME_YES" == "true" || ! -t 0 ]]; then
    return 0
  fi

  local answer
  read -r -p "$prompt [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

remove_autocomplete_from_rc() {
  local rc_file="$1"
  local marker="# ${BIN_NAME} autocomplete setup"

  if [[ ! -f "$rc_file" ]]; then
    return
  fi

  if ! grep -Fq "$marker" "$rc_file"; then
    return
  fi

  local tmp
  tmp="$(mktemp)"
  grep -Fv "$marker" "$rc_file" > "$tmp"
  mv "$tmp" "$rc_file"
  echo "Removed autocomplete line from $rc_file"
}

cleanup_autocomplete() {
  case "$TARGET_SHELL" in
    all)
      remove_autocomplete_from_rc "$HOME/.zshrc"
      remove_autocomplete_from_rc "$HOME/.bashrc"
      ;;
    zsh)
      remove_autocomplete_from_rc "$HOME/.zshrc"
      ;;
    bash)
      remove_autocomplete_from_rc "$HOME/.bashrc"
      ;;
    *)
      echo "Unsupported shell '$TARGET_SHELL'. Use all, zsh, or bash." >&2
      exit 1
      ;;
  esac
}

uninstall_package() {
  if ! command -v npm >/dev/null 2>&1; then
    echo "npm not found in PATH. Skipping package uninstall." >&2
    return
  fi

  if npm ls -g "$PACKAGE_NAME" --depth=0 >/dev/null 2>&1; then
    npm uninstall -g "$PACKAGE_NAME"
    echo "Uninstalled $PACKAGE_NAME"
  else
    echo "Package $PACKAGE_NAME is not installed globally."
  fi
}

purge_config_directory() {
  local config_path="$HOME/.config/$CONFIG_DIR_NAME"
  if [[ ! -d "$config_path" ]]; then
    echo "Config directory not found: $config_path"
    return
  fi

  if confirm "Remove config directory '$config_path'?"; then
    rm -rf "$config_path"
    echo "Removed $config_path"
  else
    echo "Skipped config removal."
  fi
}

purge_registry_settings() {
  if ! command -v npm >/dev/null 2>&1; then
    echo "npm not found in PATH. Skipping registry cleanup." >&2
    return
  fi

  if [[ -n "$SCOPE" ]]; then
    npm config delete "$SCOPE:registry" --userconfig "$NPMRC_PATH" || true
    echo "Removed npm scope registry for $SCOPE from $NPMRC_PATH"
  else
    echo "No npm scope resolved, skipping scope registry cleanup."
  fi

  local registry_host
  registry_host="$(echo "$REGISTRY_URL" | sed -E 's#^https?://##' | cut -d'/' -f1)"
  if [[ -n "$registry_host" ]]; then
    npm config delete "//$registry_host/:_authToken" --userconfig "$NPMRC_PATH" || true
    echo "Removed npm auth token key for //$registry_host/ from $NPMRC_PATH"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      SCOPE="$2"
      shift 2
      ;;
    --package)
      PACKAGE_NAME="$2"
      shift 2
      ;;
    --bin)
      BIN_NAME="$2"
      shift 2
      ;;
    --config-dir)
      CONFIG_DIR_NAME="$2"
      shift 2
      ;;
    --shell)
      TARGET_SHELL="$2"
      shift 2
      ;;
    --registry)
      REGISTRY_URL="$2"
      shift 2
      ;;
    --userconfig)
      NPMRC_PATH="$2"
      shift 2
      ;;
    --purge-config)
      PURGE_CONFIG="true"
      shift
      ;;
    --purge-registry)
      PURGE_REGISTRY="true"
      shift
      ;;
    -y|--yes)
      ASSUME_YES="true"
      shift
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

resolve_scope
resolve_package_name
resolve_bin_name
resolve_config_dir_name

echo "Package: $PACKAGE_NAME"
echo "Binary marker: $BIN_NAME"
echo "Config directory: ~/.config/$CONFIG_DIR_NAME"
echo "Autocomplete shell target: $TARGET_SHELL"

if ! confirm "Continue with uninstall?"; then
  echo "Cancelled."
  exit 0
fi

uninstall_package
cleanup_autocomplete

if [[ "$PURGE_CONFIG" == "true" ]]; then
  purge_config_directory
fi

if [[ "$PURGE_REGISTRY" == "true" ]]; then
  purge_registry_settings
fi

echo "Uninstall completed."
