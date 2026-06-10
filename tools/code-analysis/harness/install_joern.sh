#!/usr/bin/env bash
# Air-gapped installation of Joern from a local archive.
# Required env : JOERN_TAR  — path to joern-cli-X.Y.Z-all.zip (or .tar.gz)
# Optional env : JOERN_INSTALL — install root  (default: /opt/joern)
#                JDK_HOME      — pre-bundled JDK root
set -euo pipefail

JOERN_INSTALL="${JOERN_INSTALL:-/opt/joern}"
JOERN_TAR="${JOERN_TAR:-}"

err()  { echo "ERROR: $*" >&2; }
info() { echo "INFO:  $*"; }

if [[ -z "$JOERN_TAR" ]]; then
  err "JOERN_TAR is not set."
  err ""
  err "Pre-requisite files to bring in (air-gapped):"
  err "  joern-cli-X.Y.Z-all.zip      github.com/joernio/joern/releases"
  err "  openjdk-17_linux-x64_bin.tar.gz  jdk.java.net/17  (or Eclipse Temurin)"
  err ""
  err "Usage: JOERN_TAR=/path/to/joern-cli-X.Y.Z-all.zip ./install_joern.sh"
  exit 1
fi

if [[ ! -f "$JOERN_TAR" ]]; then
  err "JOERN_TAR not found: $JOERN_TAR"
  exit 1
fi

info "Installing Joern from: $JOERN_TAR"
info "Destination          : $JOERN_INSTALL"

mkdir -p "$JOERN_INSTALL"

if [[ "$JOERN_TAR" == *.zip ]]; then
  unzip -q "$JOERN_TAR" -d "$JOERN_INSTALL" || { err "unzip failed"; exit 2; }
else
  tar -xzf "$JOERN_TAR" -C "$JOERN_INSTALL" --strip-components=1 \
    || { err "tar extraction failed"; exit 2; }
fi

JOERN_BIN=$(find "$JOERN_INSTALL" -name "joern" -type f ! -name "*.bat" | head -1)
if [[ -z "$JOERN_BIN" ]]; then
  err "joern binary not found after extraction in $JOERN_INSTALL"
  exit 3
fi
chmod +x "$JOERN_BIN"

JOERN_PARSE_BIN=$(find "$JOERN_INSTALL" -name "joern-parse" -type f ! -name "*.bat" | head -1)
[[ -n "$JOERN_PARSE_BIN" ]] && chmod +x "$JOERN_PARSE_BIN"

ACTUAL_JOERN_HOME=$(dirname "$JOERN_BIN")

# Prefer bundled JDK if provided
if [[ -n "${JDK_HOME:-}" ]]; then
  export JAVA_HOME="$JDK_HOME"
  info "Using JDK_HOME: $JAVA_HOME"
fi

# Verify
VERIFY_OUT=$("$JOERN_BIN" --version 2>&1 || true)
if ! echo "$VERIFY_OUT" | grep -qi "joern"; then
  err "Joern verification failed. Check JDK availability (java -version)."
  err "  Set JDK_HOME=/path/to/bundled-jdk if system Java is missing."
  err "  Joern output: $VERIFY_OUT"
  exit 3
fi

JOERN_VER=$(echo "$VERIFY_OUT" | head -1)
info "Installed: $JOERN_VER"
echo ""
echo "Add to your shell profile (~/.bashrc or ~/.profile):"
echo "  export JOERN_HOME=\"$ACTUAL_JOERN_HOME\""
echo "  export PATH=\"\$JOERN_HOME:\$PATH\""
[[ -n "${JDK_HOME:-}" ]] && echo "  export JAVA_HOME=\"$JDK_HOME\""
