# Sourced through BASH_ENV. Each read the runner makes after a failed
# GET_LOCK can come back NULL or fail on a real server only inside a window no
# self-test can time, so the variables below make one of them answer that way
# while every other query reaches the real server.
#
# SELFTEST_GET_LOCK=NULL puts ./mysql first on PATH. The lock session is
# started through stdbuf, which looks mysql up on PATH and never sees a shell
# function.
if [ "${SELFTEST_GET_LOCK-}" = NULL ]; then
  PATH="/lock-reads:$PATH"
fi
mysql() {
  case "${*: -1}" in
    "SELECT IS_USED_LOCK("*)
      if [ "${SELFTEST_IS_USED_LOCK-}" = NULL ]; then
        printf 'NULL\n'
        return 0
      elif [ "${SELFTEST_IS_USED_LOCK-}" = error ]; then
        echo 'ERROR 2013 (HY000): Lost connection to MySQL server during query' >&2
        return 1
      fi
      ;;
    "SELECT USER, HOST FROM performance_schema.processlist "*)
      if [ "${SELFTEST_PROCESSLIST-}" = error ]; then
        echo 'ERROR 2013 (HY000): Lost connection to MySQL server during query' >&2
        return 1
      fi
      ;;
  esac
  command mysql "$@"
}
