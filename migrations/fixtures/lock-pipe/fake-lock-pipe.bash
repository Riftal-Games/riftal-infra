# Sourced through BASH_ENV. Puts ./stdbuf first on PATH, so the lock session
# closes its stdin, and holds the runner's write to that session until the
# stand-in has closed it, so the write always meets a pipe with no reader.
PATH="/lock-pipe:$PATH"
printf() {
  local wait_for=""
  case "${SELFTEST_LOCK_PIPE-}" in
    at-start) wait_for="GET_LOCK(" ;;
    after-lock) wait_for="RELEASE_LOCK(" ;;
  esac
  if [ -n "$wait_for" ] && [[ "$1" == *"$wait_for"* ]] && [ -n "${LOCKCONN_PID-}" ]; then
    for _ in $(seq 1 50); do
      [ -e "/proc/$LOCKCONN_PID/fd/0" ] || break
      sleep 0.1
    done
  fi
  builtin printf "$@"
}
