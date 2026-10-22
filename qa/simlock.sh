#!/bin/sh
# Holds one or more simulators while a command runs, so only one run drives a simulator's screen at a time (UI tests,
# taps, location playback; CLAUDE.md, "Simulators"). A second run waits for the first, saying who has the simulator,
# for up to -t seconds (default 1800), then gives up with a `RESULT: ABORT` line and exit code 75. The lock belongs to
# the running process, so a run that crashes or is killed never leaves it held.
#
#   qa/simlock.sh C0A40D2A-0607-4B95-A1BE-F8C9190D81C1 -- xcodebuild test ... -only-testing:ikutUITests/CreateTripUITests
#   qa/simlock.sh -t 600 C0A40D2A-0607-4B95-A1BE-F8C9190D81C1,FD0ACD10-F3C4-4797-8DB8-A6F554585CC1 -- <command>
#
# The qa runners that drive a simulator (run-ui, run-convoy2, demo, demo-two-cars, drive-trip) take the lock
# themselves (holdSimulators in lib/shell.mjs). A command started under simlock.sh sees the simulators it holds in
# IKUT_SIMLOCK_HELD, and asking again for one of those doesn't wait.

wait_s=1800
if [ "${1:-}" = -t ]; then wait_s=$2; shift 2; fi
[ $# -ge 1 ] || { echo "usage: simlock.sh [-t seconds] UDID[,UDID...] [--] command [args]" >&2; exit 64; }
# Sorted, so two runs that each want both simulators take them in the same order and can't wait on each other.
udids=$(printf '%s\n' "$1" | tr ',' '\n' | sort -u | paste -sd, -)
shift
[ "${1:-}" = -- ] && shift
[ $# -ge 1 ] || { echo "simlock.sh: no command to run" >&2; exit 64; }

first=${udids%%,*}
rest=${udids#"$first"}
rest=${rest#,}
if [ -n "$rest" ]; then set -- "$0" -t "$wait_s" "$rest" -- "$@"; fi

case ",${IKUT_SIMLOCK_HELD:-}," in
  *",$first,"*) exec "$@" ;; # already ours (a runner started under simlock.sh)
esac

lock=/tmp/ikut-sim-$first.lock
holder=/tmp/ikut-sim-$first.holder
if ! lockf -k -t 0 "$lock" true 2>/dev/null; then
  echo "[simlock] simulator $first is in use by: $(cat "$holder" 2>/dev/null || echo 'another run'); waiting up to $wait_s s" >&2
fi
IKUT_SIMLOCK_HELD=${IKUT_SIMLOCK_HELD:+$IKUT_SIMLOCK_HELD,}$first
export IKUT_SIMLOCK_HELD
# Inside the lock: say who has it (for the next run's waiting line), then become the command.
lockf -k -t "$wait_s" "$lock" /bin/sh -c 'printf "%s (pid %s, since %s)\n" "$1" "$$" "$(date +%H:%M:%S)" > "$2"; shift 2; exec "$@"' \
  simlock "$*" "$holder" "$@"
code=$?
if [ "$code" -eq 75 ]; then
  echo "[simlock] simulator $first still in use after $wait_s s by: $(cat "$holder" 2>/dev/null || echo 'another run')" >&2
  printf '\nRESULT: ABORT (simulator %s busy for %s s)\n' "$first" "$wait_s"
fi
exit "$code"
