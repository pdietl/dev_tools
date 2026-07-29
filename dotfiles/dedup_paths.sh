prepend_path() {
    export PATH=$1:$PATH
}

append_path() {
    # Only add a ':' if PATH is not empty.
    export PATH=$PATH${PATH:+:}$1
}

dedup_paths() {
    local -a paths  # An array containing all the paths from $PATH.
    local -A aa     # An associative array as a set to identify previously encountered paths.
    local -a unique # An array of unique paths in $PATH, in the same order.

    # Doing it this way ensures that paths containing whitespace are still preserved.
    mapfile -d : -t paths < <(printf '%s' "$PATH")
    for p in "${paths[@]}"; do
        # If "$p" not in $aa
        if [ -z "${aa[$p]+abc}" ]; then
            aa[$p]=foo     # Add it with a dummy value.
            unique+=("$p") # Add path to list of unique paths.
        fi
    done

    export PATH=''
    for p in "${unique[@]}"; do
        append_path "$p"
    done
}

