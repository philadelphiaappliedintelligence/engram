#!/bin/zsh
# Build universal binary for GitHub Releases
# Produces: engram-arm64-apple-darwin and engram-x86_64-apple-darwin

set -e

BOLD='\033[1m'
DIM='\033[2m'
CYAN='\033[36m'
GREEN='\033[32m'
RESET='\033[0m'

cd "$(dirname "$0")/.."
VERSION=$(git describe --tags 2>/dev/null || echo "dev")
DIST="dist"

echo "${BOLD}Building Engram $VERSION${RESET}"
echo ""

mkdir -p "$DIST"

# Build for arm64 (Apple Silicon)
echo "${CYAN}Building arm64...${RESET}"
swift build -c release --arch arm64 --quiet
cp .build/release/engram "$DIST/engram-arm64-apple-darwin"
codesign -s - -f "$DIST/engram-arm64-apple-darwin" 2>/dev/null
echo "${DIM}  $(file "$DIST/engram-arm64-apple-darwin" | sed 's/.*: //')${RESET}"

# Build for x86_64 (Intel)
echo "${CYAN}Building x86_64...${RESET}"
swift build -c release --arch x86_64 --quiet 2>/dev/null && {
    cp .build/release/engram "$DIST/engram-x86_64-apple-darwin"
    codesign -s - -f "$DIST/engram-x86_64-apple-darwin" 2>/dev/null
    echo "${DIM}  $(file "$DIST/engram-x86_64-apple-darwin" | sed 's/.*: //')${RESET}"
} || {
    echo "${DIM}  x86_64 build skipped (cross-compilation not available)${RESET}"
}

# Universal binary (if both architectures built)
if [[ -f "$DIST/engram-arm64-apple-darwin" ]] && [[ -f "$DIST/engram-x86_64-apple-darwin" ]]; then
    echo "${CYAN}Creating universal binary...${RESET}"
    lipo -create \
        "$DIST/engram-arm64-apple-darwin" \
        "$DIST/engram-x86_64-apple-darwin" \
        -output "$DIST/engram-universal-apple-darwin"
    codesign -s - -f "$DIST/engram-universal-apple-darwin" 2>/dev/null
    echo "${DIM}  $(file "$DIST/engram-universal-apple-darwin" | sed 's/.*: //')${RESET}"
fi

# Checksums
echo "${CYAN}Checksums:${RESET}"
cd "$DIST"
shasum -a 256 engram-* > checksums.txt
cat checksums.txt | while read line; do echo "${DIM}  $line${RESET}"; done

echo ""
echo "${GREEN}Done.${RESET} Release artifacts in $DIST/"
echo ""
echo "To create a GitHub release:"
echo "  git tag v$VERSION"
echo "  git push origin v$VERSION"
echo "  gh release create v$VERSION dist/engram-* dist/checksums.txt"
