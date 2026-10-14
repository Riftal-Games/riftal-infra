# Sourced through BASH_ENV, so the runner's VERSION() query answers
# SELFTEST_MYSQL_VERSION while every other query reaches the real server.
# No MySQL image below the floor is pulled, so this is how the self-test gets
# a server that reports one.
mysql() {
  if [ "${*: -1}" = 'SELECT VERSION()' ]; then
    printf '%s\n' "$SELFTEST_MYSQL_VERSION"
    return 0
  fi
  command mysql "$@"
}
