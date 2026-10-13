# Sourced through BASH_ENV by the Dockerfile order check in selftest.sh. A real
# sort asked for a locale the host does not carry answers differently by
# implementation: GNU falls back to C order, uutils collates the name anyway.
# This gives one answer on every host. Under any collation but C, C.UTF-8 or
# POSIX it folds case, as en_US.UTF-8 does when it puts a.Dockerfile before
# Z.Dockerfile, and runs the real sort under C so the folded order cannot
# depend on which locales are installed.
sort() {
  case "${LC_ALL:-${LC_COLLATE:-${LANG:-}}}" in
    '' | C | C.UTF-8 | C.utf8 | POSIX) command sort "$@" ;;
    *) LC_ALL=C command sort -f "$@" ;;
  esac
}
