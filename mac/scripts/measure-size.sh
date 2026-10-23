#!/bin/zsh
# Measures mMac on disk and in memory, and Muse Desktop (the installed Electron app) on disk, and
# writes each number beside the method that made it. Muse Desktop's memory is read, never launched.
#
#   mac/scripts/measure-size.sh                   Builds mMac, launches its measurement build once,
#                                                 measures, reports. Never launches Muse Desktop.
#   mac/scripts/measure-size.sh --builds-only     Builds mMac twice and checks the measurement
#                                                 marker. Launches nothing.
#   mac/scripts/measure-size.sh --electron-running
#                                                 Reads the memory of the Muse Desktop that Dom
#                                                 opened himself, and appends it to the report.
#                                                 Launches nothing, quits nothing, signals nothing.
#
# Disk: `du -sk`, in KiB, of a clean Release mMac.app, /Applications/Muse Desktop.app, the Node
# binary mMac's backend runs on, the checkout's src/ and the node_modules packages the backend
# loads. mMac's bundle and its runtime dependencies get separate lines.
#
# Memory: `footprint` (physical footprint, the number Activity Monitor shows as Memory) and RSS
# from `ps`, each summed over the app's process tree. `muse serve` and its children get their own
# line, and every process its own line.
# - mMac: the script launches the measurement build once with a temporary home and no project,
#   leaves it on its first screen for 60 seconds, measures, quits it with SIGTERM and checks that
#   no process is left.
# - Muse Desktop (--electron-running): Dom opens /Applications/Muse Desktop.app himself, with his
#   own data, and leaves it at least 60 seconds. The script finds its process tree by the exact
#   executable path and only reads it. The number includes his real projects and conversations.
#
# Safety:
# - mMac's memory run uses a second Release build, compiled with MMAC_MEASURE. That build keeps
#   the bridge token in memory, so it never reads or writes the Keychain item
#   com.domalhambra.mmac.bridge-token. It keeps window defaults in the suite
#   com.domalhambra.mmac.measure, which the script deletes at the end, and it runs the checkout it
#   was built from. Before the launch, the script finds the build's marker text in its binary, and
#   checks that the plain Release build does not carry it.
# - mMac runs with HOME, CFFIXED_USER_HOME, MUSE_HOME, XDG_CONFIG_HOME, XDG_DATA_HOME,
#   XDG_STATE_HOME and ZDOTDIR in a temporary folder, MMAC_DATA_FOLDER inside it,
#   MUSE_DESKTOP_TEST_PROVIDER=echo and MUSE_NO_AUTO_UPDATE=1. CFFIXED_USER_HOME does not move
#   preferences (cfprefsd writes the real ~/Library/Preferences), so the build's own suite is what
#   keeps mMac's defaults out of Dom's.
# - The script reads mMac's real defaults (com.domalhambra.mmac) before and after, and only reads
#   them. The Isolation section checks them, ~/Library/Application Support/mMac and `muse serve`.
# - Whatever the script launched is stopped, and the temporary home removed, on any exit.
# - The default run refuses to start while mMac or Muse Desktop is running.
#
# Output: .cache/size/report.txt at the repository root, with the build logs and mMac's stderr
# beside it.
set -u

readonly electron_app="/Applications/Muse Desktop.app"
readonly electron_bin="$electron_app/Contents/MacOS/Muse Desktop"
readonly marker="mMac measurement build: the bridge token stays in memory."
readonly suite=com.domalhambra.mmac.measure
readonly domain=com.domalhambra.mmac
readonly idle=60
readonly settle=20
# The packages that src/headless, src/shared and src/main import. tsx joins them: mMac starts the
# backend with `node --import tsx` (ProcessTransport.serverArguments). The script stops when the
# imports name another package, so this list cannot drift.
readonly imported=(@modelcontextprotocol/sdk @muse-code/sdk chokidar zod)
readonly loader=tsx

repository=${0:A:h:h:h}
out=$repository/.cache/size
report=$out/report.txt
release_app=$repository/.cache/mmac-rel/Build/Products/Release/mMac.app
measure_app=$repository/.cache/mmac-measure/Build/Products/Release/mMac.app
mode=full
if (( $# == 1 )) && [[ $1 == --builds-only ]]; then
  mode=builds
elif (( $# == 1 )) && [[ $1 == --electron-running ]]; then
  mode=electron
elif (( $# != 0 )); then
  print -u2 "Usage: $0 [--builds-only | --electron-running]"
  exit 2
fi
launched=()
failed=0
T=""
mkdir -p "$out"
cd "$repository"

fail() {
  print -u2 -- "$*"
  exit 1
}

# True while the process runs. A zombie counts as gone.
alive() {
  local state
  state=$(ps -o stat= -p $1 2>/dev/null) || return 1
  [[ -n $state && $state != Z* ]]
}

# The process and every descendant, one PID per line.
tree_of() {
  local child
  print -- $1
  for child in $(pgrep -P $1); do tree_of $child; done
}

# --- Memory, read only --------------------------------------------------------------------------

mib() { awk -v b=$1 'BEGIN { printf "%.1f", b / 1048576 }' }

# Summed physical footprint in bytes, and how many processes footprint could read.
footprint_of() {
  (( $# )) || { print 0 0; return }
  local p args=()
  for p in $@; do args+=(-p $p); done
  footprint -f bytes --noCategories $args 2>/dev/null \
    | awk '/phys_footprint:/ { s += $2; n++ } END { print s + 0, n + 0 }'
}

# Summed RSS in bytes.
rss_of() {
  (( $# )) || { print 0; return }
  ps -o rss= -p ${(j:,:)@} | awk '{ s += $1 } END { print s * 1024 }'
}

memory_line() { # label, PIDs...
  local label=$1
  shift
  if (( $# == 0 )); then
    printf '  %-44s none running\n' "$label" >> "$memory"
    return
  fi
  local fp=($(footprint_of $@)) note=""
  (( fp[2] != $# )) && note="  (footprint read $fp[2] of $# processes)"
  printf '  %-44s %2d processes  footprint %7s MiB  RSS %7s MiB%s\n' "$label" $# \
    $(mib $fp[1]) $(mib $(rss_of $@)) "$note" >> "$memory"
}

# Measures the tree under the PID $2 and writes it to $memory under the name $1. Sets tree.
measure_tree() {
  local name=$1 root=$2 p serve=()
  tree=(${(u)$(tree_of $root)})
  for p in $tree; do
    [[ $(ps -o args= -p $p) == *" serve --trust-workspace"* ]] && serve+=($(tree_of $p))
  done
  serve=(${(u)serve})
  memory_line "$name" ${tree:|serve}
  memory_line "$name: muse serve" $serve
  for p in $tree; do
    local fp=($(footprint_of $p))
    printf '      %-36s pid %-6s footprint %7s MiB  RSS %7s MiB\n' "${$(ps -o comm= -p $p):t}" $p \
      $(mib $fp[1]) $(mib $(rss_of $p)) >> "$memory"
  done
}

# --- Muse Desktop, opened by Dom: read only -----------------------------------------------------

if [[ $mode == electron ]]; then
  # The main process: its command is exactly the app's executable, with or without arguments.
  # Helpers run other executables inside the bundle, so they do not match.
  roots=(${(f)"$(ps -axo pid=,args= | awk -v bin="$electron_bin" '{
    pid = $1; sub(/^ *[0-9]+ /, "")
    if ($0 == bin || index($0, bin " ") == 1) print pid
  }')"})
  (( ${#roots} == 1 )) || fail "Found ${#roots} Muse Desktop main processes running $electron_bin. Open it once (from /Applications), then run this again."
  root=$roots[1]
  # ps prints the elapsed time as [[dd-]hh:]mm:ss.
  up=$(ps -o etime= -p $root | tr -d ' ' | awk -F'[-:]' '{
    if (NF == 4) print $1 * 86400 + $2 * 3600 + $3 * 60 + $4
    else if (NF == 3) print $1 * 3600 + $2 * 60 + $3
    else print $1 * 60 + $2 }')
  (( up >= idle )) || fail "Muse Desktop has run $up seconds. Wait $(( idle - up )) more seconds, then run this again."
  memory=$out/electron-memory.txt
  : > "$memory"
  measure_tree "Muse Desktop: app and helpers" $root
  [[ -f $report ]] || print "mMac and Muse Desktop: size (no default run yet; run the script without arguments)" > "$report"
  {
    print
    print "Muse Desktop (opened by Dom, his real data)"
    print "  Measured $(date '+%Y-%m-%d %H:%M %Z'), $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$electron_app/Contents/Info.plist" 2>/dev/null), up $up seconds, read only."
    print "  This number includes Dom's real projects and conversations, so it is not idle on an empty"
    print "  first screen as mMac's is."
    cat "$memory"
  } >> "$report"
  cat "$report"
  exit 0
fi

# Stops whatever the script launched and is still running, and removes the temporary home.
# Runs on every exit; safe to run twice.
cleaned=0
cleanup() {
  (( cleaned )) && return 0
  cleaned=1
  local p
  for p in $launched; do
    alive $p && kill -TERM $(tree_of $p) 2>/dev/null
  done
  launched=()
  [[ -n $T && -d $T ]] && rm -rf "$T"
  if defaults domains 2>/dev/null | tr -d ' ' | tr ',' '\n' | grep -qxF $suite; then
    defaults delete $suite 2>/dev/null
  fi
  return 0
}

trap cleanup EXIT
trap 'print -u2 "Interrupted. Stopping what the script launched."; exit 130' HUP INT TERM

# --- Builds -------------------------------------------------------------------------------------

build() { # derived-data folder, log file name, xcodebuild actions and settings...
  local data=$1 log=$out/$2
  shift 2
  xcodebuild -project mac/mMac.xcodeproj -scheme mMac -configuration Release \
    -destination 'platform=macOS' -derivedDataPath "$data" "$@" > "$log" 2>&1 \
    || fail "The build in $data failed. See $log."
}

print "== Building mMac: Release (clean), then the measurement build"
(cd mac && xcodegen generate > /dev/null) || fail "xcodegen generate failed."
build .cache/mmac-rel build-release.log clean build
build .cache/mmac-measure build-measure.log build 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) MMAC_MEASURE'

LC_ALL=C grep -qaF -- "$marker" "$measure_app/Contents/MacOS/mMac" \
  || fail "The measurement build lacks its marker, so it could read the Keychain. It was not launched."
if LC_ALL=C grep -qaF -- "$marker" "$release_app/Contents/MacOS/mMac"; then
  fail "The Release build carries the measurement marker. Nothing was launched."
fi
print "Markers: the measurement build has its marker. The Release build has none."
[[ $mode == builds ]] && exit 0

# --- Checks before the launch -------------------------------------------------------------------

muse_bin=$(command -v muse) || fail "muse is not on PATH. The run needs the installed Muse Code CLI."
[[ -d $electron_app ]] || fail "$electron_app is not installed. Its disk number needs it."
pgrep -x mMac > /dev/null && fail "mMac is running. Quit it, then run the script again."
pgrep -f "$electron_bin" > /dev/null && fail "Muse Desktop is running. Quit it, then run the script again."

# Writes a domain's real defaults, or "(domain absent)", as mac/scripts/ui-tests.sh does. Read only.
export_defaults() { # domain
  local domains
  domains=$(defaults domains) || return 1
  if ! print -r -- $domains | tr -d ' ' | tr ',' '\n' | grep -qxF $1; then
    print "(domain absent)"
    return 0
  fi
  defaults export $1 -
}

export_defaults $domain > "$out/defaults-before.plist" || fail "mMac's defaults could not be read. Nothing was launched."
pgrep -f 'serve --trust-workspace' | LC_ALL=C sort > "$out/serve-before.txt"

T=$(mktemp -d "${TMPDIR:-/tmp}/mmac-size.XXXXXX") || fail "mktemp failed."
T=${T:A}
touch "$T/start"

# The app's environment, one assignment per line.
home_env() { # home folder
  print -l -- "HOME=$1" "CFFIXED_USER_HOME=$1" "ZDOTDIR=$1" "MUSE_HOME=$1/muse" \
    "XDG_CONFIG_HOME=$1/config" "XDG_DATA_HOME=$1/data" "XDG_STATE_HOME=$1/state" \
    MUSE_DESKTOP_TEST_PROVIDER=echo MUSE_NO_AUTO_UPDATE=1
}

memory=$out/memory.txt
: > "$memory"

# Quits the app at PID $2 with SIGTERM and waits up to $settle seconds for every PID in tree.
quit_tree() {
  local name=$1 root=$2 left=() p i
  kill -TERM $root 2>/dev/null
  for (( i = 0; i < settle; i++ )); do
    left=()
    for p in $tree; do alive $p && left+=($p); done
    (( ${#left} == 0 )) && break
    sleep 1
  done
  if (( ${#left} )); then
    print "  $name left these processes after $settle seconds; the script killed them:" >> "$memory"
    ps -o pid=,args= -p ${(j:,:)left} | sed 's/^/    /' >> "$memory"
    kill -KILL $left 2>/dev/null
    failed=1
  else
    print "  $name quit with SIGTERM and left no process." >> "$memory"
    launched=(${launched:#$root})
  fi
}

print "== mMac: measurement build, $idle seconds idle"
mmac_home=$T/mmac
mkdir -p "$mmac_home/app-data"
printf '{"cliPath":"%s"}\n' "$muse_bin" > "$mmac_home/app-data/preferences.json"
env "${(f)$(home_env $mmac_home)}" MMAC_DATA_FOLDER="$mmac_home/app-data" MMAC_DEFAULTS_SUITE=$suite \
  "$measure_app/Contents/MacOS/mMac" -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO \
  > "$out/mmac.log" 2>&1 &
mmac_pid=$!
launched+=($mmac_pid)
sleep $idle
alive $mmac_pid || fail "mMac ended before the measurement. See $out/mmac.log."
grep -qF -- "$marker" "$out/mmac.log" || fail "mMac did not print the measurement marker. See $out/mmac.log."
backend=$(pgrep -P $mmac_pid -f 'headless/server.ts' | head -n 1)
[[ -n $backend ]] || fail "mMac's backend is not running after $idle seconds. See $out/mmac.log."
# The backend's executable, as an absolute path: lsof's first txt entry, else ps and PATH.
node_bin=$(lsof -a -p $backend -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
if [[ $node_bin != /* ]]; then
  node_bin=$(ps -o comm= -p $backend)
  [[ $node_bin == /* ]] || node_bin=$(command -v ${node_bin:t})
fi
[[ $node_bin == /* && -x $node_bin ]] || fail "The backend's Node binary could not be found (got '$node_bin')."
measure_tree "mMac: app and backend" $mmac_pid
quit_tree mMac $mmac_pid

# --- Isolation ----------------------------------------------------------------------------------

isolation=$out/isolation.txt
: > "$isolation"
check() { # description, then a command that succeeds when the check passes
  local description=$1
  shift
  if "$@"; then
    print "  pass: $description" >> "$isolation"
  else
    print "  FAIL: $description" >> "$isolation"
    failed=1
  fi
}
# A folder that is absent, or holds nothing changed since the script started.
no_newer_files() { [[ ! -e $1 || -z $(find "$1" -newer "$T/start" -print -quit 2>/dev/null) ]] }
same_file() { cmp -s "$1" "$2" }
no_new_pids() { # pattern, file of PIDs from before
  local now=$(pgrep -f "$1" | LC_ALL=C sort)
  [[ -z $(LC_ALL=C comm -13 "$2" <(print -r -- $now) | grep -v '^$') ]]
}

export_defaults $domain > "$out/defaults-after.plist"
check "nothing new in ~/Library/Application Support/mMac" no_newer_files "$HOME/Library/Application Support/mMac"
check "mMac's real defaults ($domain) are unchanged" same_file "$out/defaults-before.plist" "$out/defaults-after.plist"
check "no muse serve process is left" no_new_pids 'serve --trust-workspace' "$out/serve-before.txt"

# --- Disk ---------------------------------------------------------------------------------------

kib() { du -sk "$1" | awk '{ print $1 }' }
sum_kib() { awk '{ s += $1 } END { print s + 0 }' }
# A package folder without the node_modules folder inside it: nested packages are counted on
# their own when they are in the set.
packages_kib() { tr '\n' '\0' | xargs -0 du -sk -I node_modules | sum_kib }

backend_files() {
  find src/headless src/shared src/main -type f ! -path src/main/index.ts ! -path src/main/updates.ts "$@"
}

found=$(backend_files -name '*.ts' -print0 | xargs -0 grep -hoE "(from|import\() *'[^.'][^']*'" \
  | sed -E "s/^(from|import\() *'//; s/'\$//" | grep -v '^node:' \
  | sed -E 's#^((@[^/]+/)?[^/]+).*#\1#' | LC_ALL=C sort -u)
expected=$(print -l -- $imported | LC_ALL=C sort -u)
[[ $found == "$expected" ]] || fail "The backend imports these packages: ${(f)found}. The script counts: $imported. Update imported in this script."

cat > "$T/closure.mjs" <<'EOF'
// Prints the folder of every package in the dependency closure of the named packages, as Node
// resolves them from the repository: dependencies, and the optional and peer dependencies that
// are installed.
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'

const [root, ...names] = process.argv.slice(2)
const seen = new Set()
const missing = []

function find(from, name) {
  for (let dir = from; ; dir = dirname(dir)) {
    const folder = join(dir, 'node_modules', name)
    if (existsSync(join(folder, 'package.json'))) return folder
    if (dir === root || dir === dirname(dir)) return undefined
  }
}

function visit(from, name, required) {
  const folder = find(from, name)
  if (!folder) {
    if (required) missing.push(`${name} (needed by ${from})`)
    return
  }
  if (seen.has(folder)) return
  seen.add(folder)
  const manifest = JSON.parse(readFileSync(join(folder, 'package.json'), 'utf8'))
  for (const dependency of Object.keys(manifest.dependencies ?? {})) visit(folder, dependency, true)
  for (const dependency of Object.keys(manifest.optionalDependencies ?? {}))
    visit(folder, dependency, false)
  for (const dependency of Object.keys(manifest.peerDependencies ?? {}))
    visit(folder, dependency, false)
}

for (const name of names) visit(root, name, true)
if (missing.length) {
  console.error(`Not installed: ${missing.join(', ')}. Run npm ci.`)
  process.exit(1)
}
console.log([...seen].sort().join('\n'))
EOF
runtime=$("$node_bin" "$T/closure.mjs" "$repository" $imported $loader) || fail "The package closure failed."
production=$(npm ls --omit=dev --parseable --all 2>/dev/null | LC_ALL=C sort -u | grep -vxF "$repository")
[[ -n $production ]] || fail "npm ls --omit=dev printed no packages. Run npm ci."

mmac_kib=$(kib "$release_app")
electron_kib=$(kib "$electron_app")
node_kib=$(kib "${node_bin:A}")
# otool prints a header line per architecture, each ending in a colon.
node_libraries=$(otool -L "${node_bin:A}" | awk '!/:$/ { print $1 }' | grep -vE '^/(usr/lib|System)/')
node_archs=$(lipo -archs "${node_bin:A}" 2>/dev/null)
src_kib=$(kib src)
backend_src_kib=$(backend_files -print0 | xargs -0 du -k | sum_kib)
runtime_kib=$(print -r -- $runtime | packages_kib)
production_kib=$(print -r -- $production | packages_kib)

# --- Report -------------------------------------------------------------------------------------

{
  print "mMac and Muse Desktop: size, measured $(date '+%Y-%m-%d %H:%M %Z')"
  print "macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sysctl -n hw.model), $(uname -m). mMac at $(git rev-parse --short HEAD)."
  print "Disk: du -sk, in KiB (1 KiB = 1,024 bytes). Memory: footprint (physical footprint, as Activity"
  print "Monitor's Memory column) and ps RSS, summed per process. mMac: after $idle s idle on the first"
  print "screen, with no project open and a temporary home. RSS counts shared pages in every process"
  print "that maps them, so it reads higher than footprint."
  print
  print "Disk"
  printf '  %-62s %9s KiB\n' "mMac.app (Release, clean build)" $mmac_kib
  printf '  %-62s %9s KiB\n' "Muse Desktop.app (/Applications, $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$electron_app/Contents/Info.plist"))" $electron_kib
  print "  mMac's runtime dependencies, outside its bundle:"
  printf '    %-60s %9s KiB\n' "Node ${node_bin:A} ($("$node_bin" --version), $node_archs)" $node_kib
  [[ -n $node_libraries ]] && print "      Node also links these libraries, not counted: ${(f)node_libraries}"
  printf '    %-60s %9s KiB\n' "src/, the whole folder" $src_kib
  printf '    %-60s %9s KiB\n' "src/ the backend loads: headless, shared, main (no index.ts, updates.ts)" $backend_src_kib
  printf '    %-60s %9s KiB\n' "node_modules the backend loads ($(print -r -- $runtime | wc -l | tr -d ' ') packages)" $runtime_kib
  print "      The closure of $imported and $loader."
  printf '    %-60s %9s KiB\n' "node_modules, npm's production set ($(print -r -- $production | wc -l | tr -d ' ') packages)" $production_kib
  print "      npm ls --omit=dev --all. While Electron's shell is in the repo, this set holds its renderer"
  print "      packages and leaves out tsx, so the line above is mMac's number."
  print
  print "Memory: mMac"
  cat "$memory"
  print "  Muse Desktop's memory: open /Applications/Muse Desktop.app, wait 60 s, then run"
  print "  mac/scripts/measure-size.sh --electron-running. It appends its own section below."
  print
  print "Isolation (mMac)"
  cat "$isolation"
} > "$report"

cat "$report"
exit $failed
