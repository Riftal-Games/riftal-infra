#!/bin/sh
# Run from a plugin folder after composer install and before pharynx. Carries
# link_replaced() from riftal-game/.github/scripts/packages.sh; keep the two
# in step.
#
# pharynx follows each virion's require into vendor/<name> by name alone and
# never reads replace. libasynql requires pocketmine/pocketmine-mp, which the
# fork satisfies as axolotl-pm/pocketmine-mp, so vendor/pocketmine/pocketmine-mp
# does not exist and pharynx stops there. Linking each name a virion requires
# and another package replaces to that package gives pharynx the folder it
# expects. That package is not a virion, so pharynx then skips it.
set -eu

# The $ are PHP's, so the shell must not expand them.
# shellcheck disable=SC2016
php -r '
  $installed = json_decode(file_get_contents("vendor/composer/installed.json"), true, flags: JSON_THROW_ON_ERROR);
  $packages = $installed["packages"] ?? $installed;
  $required = [];
  foreach ($packages as $package) {
    if (isset($package["extra"]["virion"])) {
      $required += $package["require"] ?? [];
    }
  }
  foreach ($packages as $package) {
    foreach (array_keys($package["replace"] ?? []) as $replaced) {
      $link = "vendor/$replaced";
      if (!isset($required[$replaced]) || file_exists($link) || is_link($link)) {
        continue;
      }
      if (!is_dir(dirname($link)) && !mkdir(dirname($link), 0777, true)) {
        exit(1);
      }
      if (!symlink("../" . $package["name"], $link)) {
        exit(1);
      }
      echo "linked $link to vendor/{$package["name"]}, which replaces it\n";
    }
  }
'
