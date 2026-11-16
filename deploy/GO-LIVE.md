# Go-live runbook

The go-live runbook of the riftal-pm workspace's spec 016 (criterion 6). The
loop rehearses every step but the last on staging, the dev machine. The last,
choosing and paying for a host and opening it to players, is Nasir's, and so
is running any step here on that host. It holds the pre-open steps that have landed;
the steps spec 016's other criteria need join ahead of the last as they land.

## 1. Write-latency probe, before the host first takes anyone

The steward's ruling on riftal-pm#1348, item 3. Custody makes two durable
writes on the main thread: a player file write (riftal-game `lib`'s
`DatFilePlayerSave`), for each pickup flush, at most K a tick, and each tile
deposit; and a chunk write (`DurableChunkSave`), for each tile withdrawal.
Tile moves run at most W a tick. The probe times each write with its fsyncs on
the host's storage and passes, as ADR 017 P11 and ADR 025 P7 do, when the
player file write's p99 times K is under 25 ms and the slower tile save's p99,
the slower of the two writes, times W is under 25 ms. A fail means lowering K
or W in tuning and probing again. K cannot go below 2 or W below 1, since
`custody` stops the instance at boot below either (ADR 017 item 5, ADR 025
item 8); a fail at those floors goes to Nasir.

`write-latency-probe.sh` runs `write-latency-probe.php` with the image's `php`
in a throwaway container of the instance's image tag, with `--network none`,
so no port is published, the instance's 2 GB and 2 CPU limits, and a throwaway
`riftal_smoke_latency_*` volume of the instance volume's driver. It boots no
server: no dev bots, no `--riftal-dev-bots`, no xbox-auth change. Both are
removed when it ends. It makes 1,000 writes of each (`WRITES`), 8 KiB player
files and chunks of 16 subchunks of 4 KiB, random so compression flatters
neither. It times storage, not serializing a real player or chunk.

K and W come from the RiftalCustody `config.yml` the instance boots with,
`pickup-flushes-per-tick` and `tile-moves-per-tick`, the values `custody`
enforces; the riftal-pm workspace's `docs/tuning-numbers.md` records why. On a
booted instance that is `plugin_data/RiftalCustody/config.yml` on its volume,
before a first boot `custody/resources/config.yml` in the riftal-game release.
The probe refuses, before starting anything, when either is missing, set twice
or not a positive integer. RiftalCustody's shipped config has no
`tile-moves-per-tick` yet (riftal-game `custody/resources/config.yml` at
`fcf772f`), so until it does the probe refuses on it by design.

On the chosen host, from a checkout of this repository at the release:

```sh
CORE_IMAGE=<the instance's image tag> \
CUSTODY_CONFIG=<path to that config.yml> \
INSTANCE_VOLUME=<the instance's data volume> \
  bash deploy/write-latency-probe.sh
```

Exit 0 is `WRITE LATENCY PASS`, 1 `WRITE LATENCY FAIL` naming the bound over
budget, 2 `WRITE LATENCY REFUSED`, never a pass. An `INSTANCE_VOLUME` with
driver options is refused, since they can name the instance's own storage;
probe a volume made the same way by hand. In CI, `write-latency-selftest.sh`
proves the arithmetic and each refusal, and `write-latency-probe-selftest.sh`
proves on a stub `docker` that the probe volume takes the instance volume's
driver and is the one the probe writes to, and with `--probe` runs the probe
once for real.

Only the probe run on the chosen host is the go-live result. A staging run on
the dev machine, PASS or FAIL, is the rehearsal spec 016 criterion 6 asks for:
the step was performed, not passed. Its number is not read as a verdict, since
the dev machine's shared WSL2 disk and daemon spread it widely from run to run
(riftal-infra#1147, riftal-pm#1367).

## 2. Custody page, before the host first takes anyone

Nasir's, on the host. `deploy/custody-alert-act.sh` parks an instance and pages
on a `CUSTODY ALERT` (`README.md`, "Parking an instance and paging on an
alert"). To make the page reach him:

1. Create a Discord webhook in a private channel he owns (channel settings,
   Integrations, Webhooks). It is free.
2. Place its URL as `CUSTODY_WEBHOOK_URL` in the environment of the job that
   runs the script, from the host's secrets location outside the repository.
   The URL is a credential: it is never committed or printed.
3. Run the script against a staging instance's logs holding a custody
   emergency, and confirm the message arrives and the instance is parked,
   then un-park it as `README.md` shows.

Left unset, an alert still parks the instance and is logged, and nobody is
paged.
