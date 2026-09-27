#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

# sim-use iOS E2E matrix runner
#
# Drives the iOS E2E suites across the supported host environments:
#
#   leg       selected Xcode   UI host at boot     HID transport exercised
#   x26-sim   Xcode 26.x       Device Hub closed   legacy SimulatorKit (indigo)
#   x27-sim   Xcode 27.x       Device Hub closed   legacy SimulatorKit (indigo)
#   x26-hub   Xcode 26.x       Device Hub open     CoreDevice dtuhidd (dtuhid)
#   x27-hub   Xcode 27.x       Device Hub open     CoreDevice dtuhidd (dtuhid)
#
# "sim" legs boot headless with Device Hub closed — the same HID state as
# the classic Simulator.app workflow. "hub" legs boot while Device Hub sits
# open, which attaches dtuhidd to the fresh boot and makes the automatic
# transport selection route HID through CoreDevice. Device Hub ships inside
# the Xcode 27 bundle, so both hub legs need an Xcode 27 install; x26-hub is
# the "Xcode 26 selected, Xcode 27's Device Hub running" mixed setup.
#
# One leg runs the full E2E pass (default: x27-hub, the primary workflow
# once Xcode 27 ships); the rest run the smoke tier (describe-ui, tap,
# type, scroll). The package is built ONCE with the xcode-select toolchain
# (build_products/ is toolchain-locked); each leg swaps only the runtime
# Xcode via SIM_USE_TEST_DEVELOPER_DIR — exactly how a released binary
# meets whatever Xcode a user has selected. Each leg also boots a device
# whose iOS runtime matches its Xcode generation (runtimes are installed
# system-wide, so "newest available" would otherwise cross-contaminate).
#
# Every leg is gated and evidenced so a choreography failure cannot
# silently green-run the wrong combination:
#   - pre-suites:  dtuhidd must be attached (hub) / absent (sim), and a
#                  SIM_USE_DEBUG probe must report the matching transport
#                  selection predicate;
#   - post-suites: the dtuhidd state must not have drifted mid-leg.
# Per-leg logs and an evidence file land in .build/e2e-matrix/<timestamp>/.
#
# WARNING: leg choreography quits Device Hub and shuts down EVERY booted
# simulator (quitting the Hub does that by design). Do not run this while
# other simulator work is in flight.

set -o pipefail

cd "$(dirname "$0")/.." || exit 1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error()   { echo -e "${RED}❌ $1${NC}"; }
print_header() {
    echo -e "\n${BLUE}================================================${NC}"
    echo -e "${BLUE}🎯 $1${NC}"
    echo -e "${BLUE}================================================${NC}\n"
}

SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"
ALL_LEGS="x26-sim x27-sim x26-hub x27-hub"
FULL_SPEC="x27-hub"
LEGS_CSV=""
LIST_ONLY=false

show_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --legs <csv>   Legs to run, comma-separated (default: all)."
    echo "                 Valid legs: $ALL_LEGS"
    echo "  --full <spec>  Which leg(s) run the full suite instead of the smoke"
    echo "                 tier: a leg id, 'all', or 'none' (default: x27-hub)"
    echo "  --list         Print the resolved Xcodes and leg/tier map, then exit"
    echo "  -h, --help     Show this help"
    echo ""
    echo "Environment:"
    echo "  XCODE26_APP / XCODE27_APP  Override Xcode install discovery"
    echo "  SIMULATOR_NAME             Device name (default: iPhone 17 Pro)"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --legs)
            LEGS_CSV="$2"
            shift 2
            ;;
        --full)
            FULL_SPEC="$2"
            shift 2
            ;;
        --list)
            LIST_ONLY=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

case " all none $ALL_LEGS " in
    *" $FULL_SPEC "*) ;;
    *)
        print_error "--full must be one of: all, none, $ALL_LEGS"
        exit 1
        ;;
esac

LEGS=()
if [[ -n "$LEGS_CSV" ]]; then
    IFS=',' read -r -a requested <<< "$LEGS_CSV"
    for leg in "${requested[@]}"; do
        case " $ALL_LEGS " in
            *" $leg "*) LEGS+=("$leg") ;;
            *)
                print_error "Unknown leg: $leg (valid: $ALL_LEGS)"
                exit 1
                ;;
        esac
    done
else
    for leg in $ALL_LEGS; do LEGS+=("$leg"); done
fi

# --- Xcode discovery ---------------------------------------------------------

xcode_version() {
    plutil -extract CFBundleShortVersionString raw "$1/Contents/Info.plist" 2>/dev/null
}

discover_xcode() {
    # $1 = "26" (26.x) or "27" (>= 27). Highest version wins.
    local wanted="$1" best="" best_ver="0" app ver major
    for app in /Applications/Xcode*.app; do
        [[ -d "$app" ]] || continue
        ver=$(xcode_version "$app") || continue
        major="${ver%%.*}"
        case "$wanted" in
            26) [[ "$major" == "26" ]] || continue ;;
            27) [[ "$major" -ge 27 ]] 2>/dev/null || continue ;;
        esac
        if [[ "$(printf '%s\n%s\n' "$best_ver" "$ver" | sort -V | tail -1)" == "$ver" ]]; then
            best="$app"
            best_ver="$ver"
        fi
    done
    echo "$best"
}

XCODE26_APP="${XCODE26_APP:-$(discover_xcode 26)}"
XCODE27_APP="${XCODE27_APP:-$(discover_xcode 27)}"
DEV26="${XCODE26_APP:+$XCODE26_APP/Contents/Developer}"
DEV27="${XCODE27_APP:+$XCODE27_APP/Contents/Developer}"
HUB_APP="${XCODE27_APP:+$XCODE27_APP/Contents/Applications/DeviceHub.app}"
if [[ -z "$HUB_APP" || ! -d "$HUB_APP" ]]; then
    HUB_APP=""
fi

# --- Leg helpers -------------------------------------------------------------

leg_dev_dir()   { case "$1" in x26-*) echo "$DEV26" ;; x27-*) echo "$DEV27" ;; esac; }
leg_ios_major() { case "$1" in x26-*) echo 26 ;; x27-*) echo 27 ;; esac; }
leg_host()      { echo "${1#*-}"; }

leg_unavailable_reason() {
    local dev
    dev=$(leg_dev_dir "$1")
    if [[ -z "$dev" || ! -d "$dev" ]]; then
        echo "no Xcode $(leg_ios_major "$1").x install found (set XCODE26_APP/XCODE27_APP)"
        return
    fi
    if [[ "$(leg_host "$1")" == "hub" && -z "$HUB_APP" ]]; then
        echo "DeviceHub.app not found (it ships inside the Xcode 27 bundle)"
        return
    fi
    echo ""
}

leg_tier() {
    case "$FULL_SPEC" in
        all)  echo full ;;
        none) echo smoke ;;
        "$1") echo full ;;
        *)    echo smoke ;;
    esac
}

resolve_udid() {
    # $1 dev_dir, $2 iOS major. Runtimes are system-wide, so scope the
    # search to sections of the leg's iOS generation; the newest matching
    # section wins (sections are listed oldest-first). Exact device-name
    # match: "iPhone 17 Pro" must not also catch "iPhone 17 Pro Max".
    env DEVELOPER_DIR="$1" xcrun simctl list devices available | awk -v name="$SIMULATOR_NAME" -v major="$2" '
        /^-- / { in_section = ($0 ~ ("^-- iOS " major "\\.")) }
        in_section && index($0, "    " name " (") == 1 {
            if (match($0, /[A-F0-9-]{36}/)) udid = substr($0, RSTART, RLENGTH)
        }
        END { if (udid != "") print udid }'
}

device_runtime_line() {
    # $1 dev_dir, $2 udid → the "-- iOS X.Y --" section the device lives in.
    env DEVELOPER_DIR="$1" xcrun simctl list devices | awk -v udid="$2" '
        /^-- / { section = $0 }
        index($0, udid) { print section; exit }'
}

# --- Host app choreography ---------------------------------------------------

quit_device_hub() {
    pgrep -xq DeviceHub || return 0
    print_info "Quitting Device Hub (shuts down the simulators it manages)..."
    osascript -e 'tell application id "com.apple.dt.Devices" to quit' >/dev/null 2>&1 || pkill -x DeviceHub || true
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -xq DeviceHub || break
        sleep 1
    done
    if pgrep -xq DeviceHub; then
        print_warning "Device Hub did not quit cooperatively; killing it"
        pkill -9 -x DeviceHub
        sleep 2
    fi
    return 0
}

open_device_hub() {
    print_info "Opening Device Hub: $HUB_APP"
    open -g "$HUB_APP" || return 1
    # Give it time to reach the device list; from there it attaches dtuhidd
    # to every simulator boot (0-3 s after boot in practice).
    sleep 5
}

quit_simulator_app() {
    pgrep -xq Simulator || return 0
    print_info "Quitting Simulator.app..."
    osascript -e 'quit app "Simulator"' >/dev/null 2>&1 || true
    sleep 2
    return 0
}

# --- HID state gates and evidence --------------------------------------------

# -x (exact process name) on purpose: -f would match any process whose
# command line merely mentions dtuhidd — a log tail, an editor, this
# script's own pipeline — and fake the gate in both directions.
dtuhidd_running() { pgrep -qx dtuhidd; }

wait_for_dtuhidd() {
    local i
    for i in $(seq 1 "$1"); do
        dtuhidd_running && return 0
        sleep 1
    done
    return 1
}

probe_transport() {
    # $1 dev_dir, $2 udid, $3 logfile. `ios key 231` presses a lone
    # right-GUI modifier — it creates a real HID session (forcing the
    # transport selection, whose predicate SIM_USE_DEBUG logs) with no
    # visible UI effect. Echoes the transport line, empty on failure.
    env SIM_USE_DEBUG=1 SIM_USE_NO_DAEMON=1 DEVELOPER_DIR="$1" \
        "$SIM_USE_BIN" ios key 231 --udid "$2" >"$3" 2>&1
    grep "HID transport" "$3" | tail -1
}

verify_probe() {
    # $1 sim|hub, $2 probe line. The transport-selection predicate logs
    # "dtuhidd in this simulator's process tree: present|absent|unknown"
    # (HIDInteractor.swift); "unknown" means the process-table probe could
    # not run at all, which is a gate failure in either direction.
    local host="$1" line="$2"
    if [[ -z "$line" ]]; then
        print_error "Probe produced no HID transport line (see the probe log)"
        return 1
    fi
    print_info "Probe: $line"
    case "$host" in
        hub)
            if [[ "$line" != *"process tree: present"* ]]; then
                print_error "Probe did not report dtuhidd as present, but this is a hub leg"
                return 1
            fi
            ;;
        sim)
            if [[ "$line" != *"process tree: absent"* ]]; then
                print_error "Probe did not report dtuhidd as absent, but this is a sim leg"
                return 1
            fi
            ;;
    esac
    return 0
}

# --- Leg execution -----------------------------------------------------------

run_leg() {
    local leg="$1" tier="$2"
    local dev host major udid runtime_line probe_line
    dev=$(leg_dev_dir "$leg")
    host=$(leg_host "$leg")
    major=$(leg_ios_major "$leg")
    local leg_dir="$RUN_DIR/$leg"
    mkdir -p "$leg_dir"

    print_header "Leg $leg — tier: $tier"
    print_info "Xcode: $dev"

    # Clean slate. Daemons from the previous leg pin the previous leg's
    # Xcode; quitting the Hub also shuts down the sims it manages.
    "$SIM_USE_BIN" daemon stop --all >/dev/null 2>&1 || true
    quit_device_hub
    quit_simulator_app
    env DEVELOPER_DIR="$dev" xcrun simctl shutdown all >/dev/null 2>&1 || true

    if [[ "$host" == "hub" ]]; then
        open_device_hub || { print_error "Failed to open Device Hub"; return 1; }
    fi

    udid=$(resolve_udid "$dev" "$major")
    if [[ -z "$udid" ]]; then
        print_error "No available '$SIMULATOR_NAME' with an iOS $major.x runtime under $dev"
        return 1
    fi
    runtime_line=$(device_runtime_line "$dev" "$udid")
    print_info "Simulator: $SIMULATOR_NAME ($udid) $runtime_line"

    # bootstatus -b boots the device if needed and blocks until fully booted.
    env DEVELOPER_DIR="$dev" xcrun simctl bootstatus "$udid" -b >/dev/null || {
        print_error "Simulator failed to boot"
        return 1
    }

    # Pre-suite gate 1: process-tree state must match the leg.
    if [[ "$host" == "hub" ]]; then
        if ! wait_for_dtuhidd 20; then
            print_error "dtuhidd never attached after boot — Device Hub choreography failed; the leg would run the WRONG transport"
            return 1
        fi
        print_success "dtuhidd attached to the fresh boot"
    else
        sleep 3
        if dtuhidd_running; then
            print_error "dtuhidd present on a Hub-closed leg — is another CoreDevice client open?"
            return 1
        fi
        print_success "No dtuhidd on the fresh boot"
    fi

    # Reset the per-UDID daemon log so post-mortems cannot pick up lines
    # from an earlier leg that used the same device.
    rm -f "/tmp/sim-use-$(id -u)/$udid.log"

    # Pre-suite gate 2: a real HID session must select the expected transport.
    probe_line=$(probe_transport "$dev" "$udid" "$leg_dir/probe.log")
    verify_probe "$host" "$probe_line" || return 1

    {
        echo "leg=$leg"
        echo "tier=$tier"
        echo "developer_dir=$dev"
        echo "xcodebuild=$(env DEVELOPER_DIR="$dev" xcrun xcodebuild -version 2>/dev/null | tr '\n' ' ')"
        echo "udid=$udid"
        echo "runtime=$runtime_line"
        echo "device_hub_open=$(pgrep -xq DeviceHub && echo yes || echo no)"
        echo "probe=$probe_line"
    } > "$leg_dir/evidence.txt"

    local runner_args=()
    if [[ "$tier" == "smoke" ]]; then
        runner_args+=(--smoke)
    fi
    if ! env SIM_USE_TEST_DEVELOPER_DIR="$dev" SIMULATOR_UDID="$udid" \
        ./scripts/test-runner.sh "${runner_args[@]}" 2>&1 | tee "$leg_dir/runner.log"; then
        print_error "Suite run failed for $leg (full log: $leg_dir/runner.log)"
        return 1
    fi

    # Post-suite gate: the HID environment must not have drifted mid-leg.
    if [[ "$host" == "hub" ]]; then
        if ! dtuhidd_running; then
            print_error "dtuhidd vanished mid-leg — Device Hub state drifted; results are not trustworthy"
            return 1
        fi
    else
        if dtuhidd_running; then
            print_error "dtuhidd appeared mid-leg — results are not trustworthy"
            return 1
        fi
    fi
    print_success "Post-suite HID state verified"
    return 0
}

# --- Main --------------------------------------------------------------------

print_header "sim-use E2E matrix"
print_info "Xcode 26:   ${XCODE26_APP:-<not found>}"
print_info "Xcode 27:   ${XCODE27_APP:-<not found>}"
print_info "Device Hub: ${HUB_APP:-<not found>}"
print_info "Device:     $SIMULATOR_NAME"
echo ""
for leg in "${LEGS[@]}"; do
    reason=$(leg_unavailable_reason "$leg")
    if [[ -n "$reason" ]]; then
        print_warning "  $leg: SKIP — $reason"
    else
        print_info "  $leg: $(leg_tier "$leg")"
    fi
done

if [[ "$LIST_ONLY" == true ]]; then
    exit 0
fi

echo ""
print_warning "This run quits Device Hub / Simulator.app and shuts down ALL booted simulators."

print_header "Building once on the xcode-select toolchain"
make build || exit 1
SIM_USE_BIN="$(swift build --show-bin-path)/sim-use"
if [[ ! -x "$SIM_USE_BIN" ]]; then
    print_error "sim-use binary not found at $SIM_USE_BIN"
    exit 1
fi
print_info "sim-use under test: $SIM_USE_BIN"

RUN_DIR=".build/e2e-matrix/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
print_info "Logs and evidence: $RUN_DIR"

RESULT_LINES=()
overall_fail=0
for leg in "${LEGS[@]}"; do
    reason=$(leg_unavailable_reason "$leg")
    tier=$(leg_tier "$leg")
    if [[ -n "$reason" ]]; then
        RESULT_LINES+=("SKIP|$leg ($tier) — $reason")
        continue
    fi
    leg_start=$SECONDS
    if run_leg "$leg" "$tier"; then
        dur=$((SECONDS - leg_start))
        RESULT_LINES+=("PASS|$leg ($tier, $((dur / 60))m$((dur % 60))s)")
    else
        dur=$((SECONDS - leg_start))
        RESULT_LINES+=("FAIL|$leg ($tier, $((dur / 60))m$((dur % 60))s) — see $RUN_DIR/$leg/")
        overall_fail=1
    fi
done

# Leave the machine clean: no matrix daemons, no Hub-managed sims.
"$SIM_USE_BIN" daemon stop --all >/dev/null 2>&1 || true
quit_device_hub

print_header "E2E matrix results"
for line in "${RESULT_LINES[@]}"; do
    status="${line%%|*}"
    rest="${line#*|}"
    case "$status" in
        PASS) print_success "$rest" ;;
        FAIL) print_error "$rest" ;;
        SKIP) print_warning "$rest" ;;
    esac
done
echo ""
print_info "Per-leg combination evidence:"
for leg in "${LEGS[@]}"; do
    if [[ -f "$RUN_DIR/$leg/evidence.txt" ]]; then
        echo ""
        sed 's/^/    /' "$RUN_DIR/$leg/evidence.txt"
    fi
done

if [[ $overall_fail -ne 0 ]]; then
    print_error "E2E matrix: one or more legs failed"
    exit 1
fi
print_success "E2E matrix: all runnable legs green"
