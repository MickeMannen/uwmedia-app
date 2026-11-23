#!/bin/bash

# UWMedia app test runner. The suites are described in CONTRIBUTING.md.
#
# Usage: tool/run_tests.sh [1-5] - with a choice, run it without the menu
# (for scripts, hooks, CI and agents); without one, ask (Enter = 1).
#
# The default run excludes the `golden` and `release` tags (dart_test.yaml
# declares them); the other suites change only the tag filter.

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}====================================================${NC}"
echo -e "${CYAN}         UWMedia app test suite runner              ${NC}"
echo -e "${CYAN}====================================================${NC}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || exit 1

# The ffmpeg, ffprobe and exiftool the apps ship with, not the system's.
. tool/own_tools.sh

choice_arg="$1"

if [ -z "$choice_arg" ]; then
    echo -e "\nSelect a test suite to run:"
    echo -e "  ${YELLOW}1)${NC} Default: format check, analyzer, every test except golden and release"
    echo -e "  ${YELLOW}2)${NC} Quick: as 1, without the render tests"
    echo -e "  ${YELLOW}3)${NC} Release: the pre-release tests on the full media only"
    echo -e "  ${YELLOW}4)${NC} Everything: default + release + overlay golden images - run this before a release"
    echo -e "  ${YELLOW}5)${NC} Exit"
fi

# Static checks shared by the suites that include them. Formatting is checked,
# not applied, so a run never changes the tree.
static_checks() {
    echo -e "\n${GREEN}[*] dart format (check only)...${NC}"
    dart format --output=none --set-exit-if-changed lib test tool || return 1
    echo -e "\n${GREEN}[*] flutter analyze...${NC}"
    flutter analyze --fatal-infos || return 1
}

run_tests() {
    # $1: --tags/--exclude-tags arguments. flutter test exits 79 when no test
    # carries the requested tag; that is "nothing to run", not a failure (the
    # release and golden suites are empty until those tests exist).
    echo -e "\n${GREEN}[*] flutter test $1...${NC}"
    # shellcheck disable=SC2086
    flutter test $1
    local rc=$?
    if [ "$rc" -eq 79 ]; then
        echo -e "${YELLOW}No tests match '$1'; nothing to run.${NC}"
        return 0
    fi
    return $rc
}

status=0
while true; do
    if [ -n "$choice_arg" ]; then
        choice="$choice_arg"
    else
        echo -n "Choose a test suite to run [1-5, Enter = 1]: "
        read -r choice || { echo -e "\n${RED}No input; pass a choice: tool/run_tests.sh 1${NC}"; exit 2; }
        [ -z "$choice" ] && choice=1
    fi
    choice=$(echo "$choice" | tr -d '\r')

    case "$choice" in
        1)
            echo -e "\n${GREEN}[*] Running the default suite (everything except golden and release)...${NC}"
            static_checks && run_tests '--exclude-tags golden,release'
            status=$?
            break
            ;;
        2)
            echo -e "\n${GREEN}[*] Running the quick suite (no renders, no golden, no release)...${NC}"
            static_checks && run_tests '--exclude-tags render,golden,release'
            status=$?
            break
            ;;
        3)
            echo -e "\n${GREEN}[*] Running the pre-release tests...${NC}"
            run_tests '--tags release'
            status=$?
            break
            ;;
        4)
            echo -e "\n${GREEN}[*] Running every test...${NC}"
            static_checks && run_tests '--exclude-tags golden,release' && run_tests '--tags release' && run_tests '--tags golden'
            status=$?
            break
            ;;
        5)
            echo -e "${YELLOW}Exiting runner.${NC}"
            break
            ;;
        *)
            echo -e "${RED}Invalid selection '$choice'. Please choose a number between 1 and 5.${NC}"
            [ -n "$choice_arg" ] && exit 2
            ;;
    esac
done

if [ "$status" -eq 0 ]; then
    echo -e "\n${GREEN}Suite passed.${NC}"
else
    echo -e "\n${RED}Suite failed (exit $status).${NC}"
fi
exit $status
