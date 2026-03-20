#!/bin/sh
# Engram Installer — curl -fsSL https://engram.dev/install | sh
# Downloads pre-built binary or builds from source as fallback.

set -e

BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[36m'
GREEN='\033[32m'
RED='\033[31m'
RESET='\033[0m'

REPO="nologin/engram"
INSTALL_DIR="$HOME/bin"
ENGRAM_HOME="$HOME/.engram"

main() {
    clear
    printf "\n"
    printf "${BOLD}  ╔══════════════════════════════════════╗${RESET}\n"
    printf "${BOLD}  ║            ${CYAN}E N G R A M${RESET}${BOLD}               ║${RESET}\n"
    printf "${BOLD}  ║   ${DIM}AI agent with holographic memory${RESET}${BOLD}   ║${RESET}\n"
    printf "${BOLD}  ╚══════════════════════════════════════╝${RESET}\n"
    printf "\n"

    # Check macOS
    if [ "$(uname)" != "Darwin" ]; then
        printf "${RED}  Engram requires macOS.${RESET}\n"
        exit 1
    fi

    ARCH=$(uname -m)
    printf "${DIM}  System: macOS $(sw_vers -productVersion) ($ARCH)${RESET}\n\n"

    # Try pre-built binary first
    if download_binary; then
        setup
        success
    else
        printf "${DIM}  Pre-built binary not available. Building from source...${RESET}\n\n"
        build_from_source
        setup
        success
    fi
}

download_binary() {
    LATEST=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | grep '"tag_name"' | head -1 | sed 's/.*: "//;s/".*//' || echo "")

    if [ -z "$LATEST" ]; then
        return 1
    fi

    printf "${CYAN}  Downloading $LATEST...${RESET}\n"

    # Try architecture-specific binary
    ASSET="engram-${ARCH}-apple-darwin"
    URL="https://github.com/$REPO/releases/download/$LATEST/$ASSET"

    TMPFILE=$(mktemp /tmp/engram.XXXXXX)
    if curl -fsSL "$URL" -o "$TMPFILE" 2>/dev/null; then
        mkdir -p "$INSTALL_DIR"
        mv "$TMPFILE" "$INSTALL_DIR/engram"
        chmod +x "$INSTALL_DIR/engram"
        codesign -s - -f "$INSTALL_DIR/engram" 2>/dev/null || true
        xattr -c "$INSTALL_DIR/engram" 2>/dev/null || true
        printf "${GREEN}  ✓ Downloaded${RESET}\n"
        return 0
    fi

    rm -f "$TMPFILE"
    return 1
}

build_from_source() {
    # Check Swift
    if ! command -v swift > /dev/null 2>&1; then
        printf "${RED}  Swift not found. Install Xcode Command Line Tools:${RESET}\n"
        printf "    xcode-select --install\n"
        exit 1
    fi

    printf "${DIM}  Swift: $(swift --version 2>&1 | head -1)${RESET}\n\n"

    # Clone
    TMPDIR=$(mktemp -d /tmp/engram-build.XXXXXX)
    printf "${CYAN}  Cloning...${RESET}\n"
    git clone --depth 1 "https://github.com/$REPO.git" "$TMPDIR" 2>/dev/null || {
        printf "${RED}  Clone failed. Check your network and that the repo exists.${RESET}\n"
        exit 1
    }

    # Build
    printf "${CYAN}  Building (this takes ~10s)...${RESET}\n"
    cd "$TMPDIR"
    swift build -c release --quiet 2>&1

    # Install
    mkdir -p "$INSTALL_DIR"
    cp .build/release/engram "$INSTALL_DIR/engram"
    codesign -s - -f "$INSTALL_DIR/engram" 2>/dev/null || true
    xattr -c "$INSTALL_DIR/engram" 2>/dev/null || true

    # Cleanup
    rm -rf "$TMPDIR"
    printf "${GREEN}  ✓ Built and installed${RESET}\n"
}

setup() {
    # Add to PATH
    if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
        SHELL_RC="$HOME/.zshrc"
        if [ ! -f "$SHELL_RC" ] && [ -f "$HOME/.zprofile" ]; then
            SHELL_RC="$HOME/.zprofile"
        fi
        if [ ! -f "$SHELL_RC" ]; then
            SHELL_RC="$HOME/.zshrc"
        fi
        printf '\n# Engram\nexport PATH="$HOME/bin:$PATH"\n' >> "$SHELL_RC"
        export PATH="$HOME/bin:$PATH"
    fi

    # Create default config
    mkdir -p "$ENGRAM_HOME"
    "$INSTALL_DIR/engram" memory > /dev/null 2>&1 || true
}

success() {
    printf "\n"
    printf "${GREEN}  ✓ Engram installed${RESET}\n"
    printf "\n"
    printf "${DIM}  ~/.engram/SOUL.md      Agent personality${RESET}\n"
    printf "${DIM}  ~/.engram/USER.md      About you${RESET}\n"
    printf "${DIM}  ~/.engram/config.json  Configuration${RESET}\n"
    printf "\n"
    printf "${BOLD}  Get started:${RESET}\n"
    printf "\n"
    printf "    ${CYAN}engram login${RESET}             Authenticate\n"
    printf "    ${CYAN}engram${RESET}                   Start chatting\n"
    printf "    ${CYAN}engram model${RESET}             Choose a model\n"
    printf "    ${CYAN}engram gateway telegram${RESET}  Connect Telegram\n"
    printf "    ${CYAN}engram daemon start${RESET}      Run in background\n"
    printf "\n"
    printf "${DIM}  Open a new terminal tab if 'engram' is not found.${RESET}\n"
    printf "\n"
}

main
