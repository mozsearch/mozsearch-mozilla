# Step lines and timings for try imports' scripts (../firefox-try/import-try,
# semantic/analyze.sh), which source this:
# - `begin_step PREFIX STEP NAME` says "Performing PREFIX::STEP step for NAME :
#   DATE", like the indexer's steps (mozsearch's tools/src/try_import.rs reads
#   analyze.sh's to say which step its semantic analysis failed in), ending
#   the step before it, if any.
# - `end_steps LABEL` ends the last step and says how long each step took, and
#   the CPU time of the processes it ran (theirs included, if they waited for
#   them), ex: "try-import timings: fetch 62 s (CPU 9 s), history 53 s (CPU
#   31 s), ...", which the scripts do as they exit (in an EXIT trap), even if
#   a step failed.

STEP_NAME=
STEP_START=
STEP_CPU=
STEP_TIMES=()

# The CPU time, in clock ticks, of the processes this shell has waited for (and
# of those they waited for, and so on): /proc/PID/stat's cutime and cstime,
# its 16th and 17th fields (after the command, in parentheses, which can
# contain spaces).
step_children_cpu() {
    local stat fields
    stat=$(< "/proc/$$/stat")
    read -r -a fields <<< "${stat##*) }"
    echo $(( fields[13] + fields[14] ))
}

end_step() {
    local -
    set +x
    if [[ -n "$STEP_NAME" ]]; then
        local wall cpu
        wall=$(( $(date +%s) - STEP_START ))
        cpu=$(( ($(step_children_cpu) - STEP_CPU) / $(getconf CLK_TCK) ))
        STEP_TIMES+=("$STEP_NAME $wall s (CPU $cpu s)")
        STEP_NAME=
    fi
}

begin_step() {
    local -
    set +x
    end_step
    STEP_NAME=$2
    STEP_START=$(date +%s)
    STEP_CPU=$(step_children_cpu)
    echo "Performing $1::$2 step for $3 : $(date +"%Y-%m-%dT%H:%M:%S%z")"
}

end_steps() {
    local -
    set +x
    end_step
    local joined
    joined=$(printf ', %s' "${STEP_TIMES[@]}")
    echo "$1 timings: ${joined:2}"
}
