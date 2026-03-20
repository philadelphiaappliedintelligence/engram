#!/bin/zsh
# curl -fsSL https://raw.githubusercontent.com/philadelphiaappliedintelligence/engram/main/install.sh | sh
set -e

BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[36m'
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
RESET='\033[0m'

REPO="https://github.com/philadelphiaappliedintelligence/engram.git"
INSTALL_DIR="/usr/local/bin"
BUILD_DIR="$HOME/.engram-build"

printf "\n  ${BOLD}engram${RESET} ${DIM}— AI agent with holographic memory${RESET}\n\n"

[ "$(uname)" != "Darwin" ] && printf "${RED}  macOS required.${RESET}\n" && exit 1

# Require Xcode.app (SwiftData macros need the full toolchain)
XCODE_PATH=$(xcode-select -p 2>/dev/null || echo "")

if [ -z "$XCODE_PATH" ] || [[ "$XCODE_PATH" == */CommandLineTools* ]]; then
    printf "${YELLOW}  Xcode.app required${RESET}\n\n"
    if [ -d "/Applications/Xcode.app" ]; then
        printf "  Xcode is installed but not selected:\n"
        printf "  ${CYAN}sudo xcode-select -s /Applications/Xcode.app/Contents/Developer${RESET}\n"
        printf "  ${CYAN}sudo xcodebuild -license accept${RESET}\n\n"
    else
        printf "  ${BOLD}App Store:${RESET}  ${CYAN}open \"https://apps.apple.com/app/xcode/id497799835\"${RESET}\n"
        printf "  ${BOLD}Direct:${RESET}     ${CYAN}https://developer.apple.com/download/applications/${RESET}\n"
        printf "  ${BOLD}Transfer:${RESET}   ${DIM}scp Xcode*.xip user@host:~/ && xip -x Xcode*.xip && mv Xcode.app /Applications/${RESET}\n\n"
        printf "  Then: ${CYAN}sudo xcode-select -s /Applications/Xcode.app/Contents/Developer && sudo xcodebuild -license accept${RESET}\n\n"
    fi
    exit 1
fi

[ ! command -v swift > /dev/null 2>&1 ] || true
printf "${DIM}  $(sw_vers -productVersion) • $(uname -m) • Swift $(swift --version 2>&1 | head -1 | sed 's/.*version //' | sed 's/ .*//')${RESET}\n"

# Clone or update
if [ -d "$BUILD_DIR/.git" ]; then
    printf "${DIM}  Updating source...${RESET}\n"
    git -C "$BUILD_DIR" pull --ff-only --quiet
else
    printf "${DIM}  Cloning...${RESET}\n"
    rm -rf "$BUILD_DIR"
    git clone --quiet "$REPO" "$BUILD_DIR"
fi

printf "${CYAN}  Building...${RESET}\n"
cd "$BUILD_DIR"
swift build -c release --quiet

printf "${DIM}  Installing to $INSTALL_DIR...${RESET}\n"
sudo mkdir -p "$INSTALL_DIR"
sudo cp .build/release/engram "$INSTALL_DIR/engram"
sudo codesign -s - -f "$INSTALL_DIR/engram" 2>/dev/null || true
sudo xattr -c "$INSTALL_DIR/engram" 2>/dev/null || true

# Build IMCore helper if SIP disabled
if csrutil status 2>&1 | grep -q "disabled"; then
    printf "${DIM}  Building iMessage helper...${RESET}\n"
    sh scripts/build-helper.sh 2>/dev/null
    mkdir -p "$HOME/.engram"
    cp .build/release/engram-imcore-helper.dylib "$HOME/.engram/engram-imcore-helper.dylib" 2>/dev/null || true
fi

printf "\n${GREEN}  Installed${RESET}\n\n"
printf "  ${CYAN}engram login${RESET}    Authenticate\n"
printf "  ${CYAN}engram${RESET}          Start chatting\n"
printf "  ${CYAN}engram --help${RESET}   All commands\n\n"
