#!/bin/zsh
# Engram — Build from source installer
# curl -fsSL https://raw.githubusercontent.com/philadelphiaappliedintelligence/engram/main/install.sh | sh

set -e

BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[36m'
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
RESET='\033[0m'

INSTALL_DIR="$HOME/bin"

clear
printf "\n"
printf "${BOLD}  ╔══════════════════════════════════════╗${RESET}\n"
printf "${BOLD}  ║            ${CYAN}E N G R A M${RESET}${BOLD}               ║${RESET}\n"
printf "${BOLD}  ║   ${DIM}AI agent with holographic memory${RESET}${BOLD}   ║${RESET}\n"
printf "${BOLD}  ╚══════════════════════════════════════╝${RESET}\n"
printf "\n"

if [ "$(uname)" != "Darwin" ]; then
    printf "${RED}  Engram requires macOS.${RESET}\n"; exit 1
fi

# Xcode.app is required (not just Command Line Tools)
# SwiftData macros and SearchKit need the full Xcode toolchain
XCODE_PATH=$(xcode-select -p 2>/dev/null || echo "")

if [ -z "$XCODE_PATH" ]; then
    printf "${RED}  Xcode is not installed.${RESET}\n\n"
    printf "  Engram uses SwiftData and SearchKit which require the full Xcode toolchain.\n"
    printf "  Command Line Tools alone are not sufficient.\n\n"
    printf "  Install Xcode from the App Store:\n"
    printf "  ${CYAN}  open \"https://apps.apple.com/app/xcode/id497799835\"${RESET}\n\n"
    printf "  Or install via xcodesorg:\n"
    printf "  ${CYAN}  brew install xcodesorg/made/xcodes && xcodes install --latest${RESET}\n\n"
    printf "  After installing, run: ${CYAN}sudo xcode-select -s /Applications/Xcode.app/Contents/Developer${RESET}\n"
    printf "  Then re-run this installer.\n\n"
    exit 1
fi

if [[ "$XCODE_PATH" == */CommandLineTools* ]]; then
    printf "${YELLOW}  ⚠ Xcode.app required${RESET}\n\n"
    printf "  Your system is using Command Line Tools:\n"
    printf "  ${DIM}  $XCODE_PATH${RESET}\n\n"
    printf "  Engram uses SwiftData and SearchKit which require the full Xcode toolchain.\n\n"

    if [ -d "/Applications/Xcode.app" ]; then
        printf "  Xcode.app is installed but not selected. Fix with:\n"
        printf "  ${CYAN}  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer${RESET}\n\n"
        printf "  Run that command, then re-run this installer.\n\n"
    else
        printf "  Install Xcode from the App Store:\n"
        printf "  ${CYAN}  open \"https://apps.apple.com/app/xcode/id497799835\"${RESET}\n\n"
        printf "  Or install via xcodesorg:\n"
        printf "  ${CYAN}  brew install xcodesorg/made/xcodes && xcodes install --latest${RESET}\n\n"
        printf "  After installing, run: ${CYAN}sudo xcode-select -s /Applications/Xcode.app/Contents/Developer${RESET}\n"
        printf "  Then re-run this installer.\n\n"
    fi
    exit 1
fi

if ! command -v swift > /dev/null 2>&1; then
    printf "${RED}  Swift not found. Xcode may need to finish setup.${RESET}\n"
    printf "  Try: ${CYAN}sudo xcodebuild -license accept${RESET}\n"; exit 1
fi

printf "${DIM}  macOS $(sw_vers -productVersion) • $(uname -m) • Swift $(swift --version 2>&1 | head -1 | sed 's/.*version //' | sed 's/ .*//')${RESET}\n"
printf "${DIM}  Xcode: $XCODE_PATH${RESET}\n"
printf "${DIM}  Install to: $INSTALL_DIR/engram${RESET}\n\n"
printf "  Press ${BOLD}Enter${RESET} to build and install. "
read -r

printf "\n${CYAN}  Building release...${RESET}\n"
swift build -c release --quiet

mkdir -p "$INSTALL_DIR"
cp .build/release/engram "$INSTALL_DIR/engram"
codesign -s - -f "$INSTALL_DIR/engram" 2>/dev/null || true
xattr -c "$INSTALL_DIR/engram" 2>/dev/null || true

if ! echo "$PATH" | grep -q "$INSTALL_DIR"; then
    RC="$HOME/.zshrc"
    [ ! -f "$RC" ] && RC="$HOME/.zprofile"
    printf '\n# Engram\nexport PATH="$HOME/bin:$PATH"\n' >> "$RC"
    export PATH="$HOME/bin:$PATH"
fi

"$INSTALL_DIR/engram" memory > /dev/null 2>&1 || true

printf "\n${GREEN}  ✓ Installed${RESET}\n\n"
printf "  ${CYAN}engram login${RESET}    Authenticate\n"
printf "  ${CYAN}engram${RESET}          Start chatting\n"
printf "  ${CYAN}engram --help${RESET}   All commands\n\n"
