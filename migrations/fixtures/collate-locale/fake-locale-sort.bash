# Sourced through BASH_ENV. The mysql:8 image carries only the C, C.utf8 and
# POSIX locales, so no real collating locale can be selected inside it. This
# sort stands in for one such as en_US.UTF-8, which folds case and so orders
# 0001_a before 0001_B, under any LC_ALL other than C.
sort() {
  if [ "${LC_ALL-}" = C ]; then
    command sort "$@"
  else
    command sort -f "$@"
  fi
}
