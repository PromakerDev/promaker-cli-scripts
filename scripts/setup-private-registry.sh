#!/usr/bin/env bash
set -euo pipefail

REGISTRY_URL="${CLI_PACKAGE_REGISTRY:-https://npm.pkg.github.com}"
NPMRC_PATH="${NPM_CONFIG_USERCONFIG:-$HOME/.npmrc}"
SCOPE=""
PACKAGE_NAME=""
INSTALL_AFTER_SETUP="false"
BRAND_SLUG="${CLI_BRAND_SLUG:-promaker}"
DEFAULT_SCOPE="${CLI_PACKAGE_SCOPE:-@promakerdev}"
DEFAULT_PACKAGE_BASENAME="${CLI_PACKAGE_NAME:-promaker-cli}"

print_help() {
  cat <<'USAGE'
Configure npm to install private packages from GitHub Packages using your `gh` auth token.

Usage:
  ./scripts/setup-private-registry.sh [options]

Options:
  --scope <scope>         npm scope to configure (example: @acme)
  --registry <url>        npm registry URL (default: https://npm.pkg.github.com)
  --userconfig <path>     npm user config file path (default: ~/.npmrc)
  --package <name>        package to install globally after setup (default: <scope>/<brand-slug>-cli)
  --install               install the package globally after registry setup
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      SCOPE="$2"
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
    --package)
      PACKAGE_NAME="$2"
      shift 2
      ;;
    --install)
      INSTALL_AFTER_SETUP="true"
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      print_help
      exit 1
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required. Install it from https://cli.github.com"
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "npm is required but was not found in PATH."
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "You are not authenticated in gh. Run: gh auth login"
  exit 1
fi

if [[ -z "$SCOPE" ]]; then
  if [[ -n "$DEFAULT_SCOPE" ]]; then
    SCOPE="$DEFAULT_SCOPE"
  elif ! SCOPE="$(parse_scope_from_remote)"; then
    if [[ -n "$BRAND_SLUG" ]]; then
      SCOPE="@$BRAND_SLUG"
    else
      echo "Unable to infer npm scope. Pass --scope or set CLI_PACKAGE_SCOPE/CLI_BRAND_SLUG." >&2
      exit 1
    fi
  fi
fi

if [[ "$SCOPE" != @* ]]; then
  SCOPE="@$SCOPE"
fi

if [[ -z "$PACKAGE_NAME" ]]; then
  if [[ -z "$DEFAULT_PACKAGE_BASENAME" ]]; then
    if [[ -n "$BRAND_SLUG" ]]; then
      DEFAULT_PACKAGE_BASENAME="${BRAND_SLUG}-cli"
    else
      DEFAULT_PACKAGE_BASENAME="$(echo "$SCOPE" | sed 's/^@//')-cli"
    fi
  fi

  if [[ "$DEFAULT_PACKAGE_BASENAME" == @*/* ]]; then
    PACKAGE_NAME="$DEFAULT_PACKAGE_BASENAME"
  else
    PACKAGE_NAME="$SCOPE/$DEFAULT_PACKAGE_BASENAME"
  fi
fi

GH_TOKEN="$(gh auth token)"
REGISTRY_HOST="$(echo "$REGISTRY_URL" | sed -E 's#^https?://##' | cut -d'/' -f1)"
if [[ -z "$REGISTRY_HOST" ]]; then
  echo "Could not parse registry host from '$REGISTRY_URL'." >&2
  exit 1
fi

npm config set "$SCOPE:registry" "$REGISTRY_URL" --userconfig "$NPMRC_PATH"
npm config set "//$REGISTRY_HOST/:_authToken" "$GH_TOKEN" --userconfig "$NPMRC_PATH"

echo "Configured npm registry for scope '$SCOPE' in '$NPMRC_PATH'."
echo "You can now install private packages from GitHub Packages."

echo "Example: npm install -g $PACKAGE_NAME"

if [[ "$INSTALL_AFTER_SETUP" == "true" ]]; then
  npm install -g "$PACKAGE_NAME"
  echo "Installed $PACKAGE_NAME globally."
fi
