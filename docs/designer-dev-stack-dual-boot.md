# Live proof: the regular dev stack and the designer stack, booted together

Closes riftal-infra#162, the follow-up `../../riftal-infra` PR #161 (riftal-infra#157)
could not finish itself: PR #161 fixed the designer stack's port collision at the
config level (`DESIGNER_GAME_PORT` defaulting to `19134`, distinct from the regular
dev stack's `19132`/`19133`) and verified the compose YAML with `docker compose
config`, but had no working container runtime to boot both stacks at once and watch
each answer its own pong. This is that boot, run once wslc's `ERROR_SHARING_VIOLATION`
(riftal-pm#120) made way for the Docker fallback engine (riftal-pm#129):
`wsl -d Ubuntu-26.04 -u runner -- docker ...`.

Three PocketMine containers, one Docker daemon, one boot:

| Container | Compose service | Published port | World | MOTD |
|---|---|---|---|---|
| `riftal-instance` | `images/compose.yaml` `instance` | `0.0.0.0:19132/udp` | `mine_a` | `riftal-dev` |
| `riftal-instance-b` | `images/compose.yaml` `instance-b` | `0.0.0.0:19133/udp` | `plots_b` | `riftal-dev-b` |
| `designer` | `designer/stack/compose.yaml` `designer` | `127.0.0.1:19134/udp` | `design` | `riftal-designer` |

`riftal-instance` and `riftal-mysql` already existed under the Docker fallback engine
from earlier work in this environment, both `Exited (0)` when this session started
(`docker ps -a`, read before touching anything). `dev-stack.ps1 -Engine docker start`
starts and stops those two by name; it does not create or remove them, and this proof
left them in the same `Exited (0)` state it found them in. `riftal-instance-b` and
`designer` did not exist yet and were created fresh for this proof, then removed at the
end; their named volumes (`riftal-world-b`, `designer-world`) were left in place, never
`docker volume rm`.

## Lock

Held for the duration, per `dev-stack.ps1`'s own convention:

```
$ mkdir C:/Users/nasir/riftal-games/devtools/.stack-lock
$ printf "infra" > C:/Users/nasir/riftal-games/devtools/.stack-lock/owner
$ date -u
Mon Sep 28 00:45:02 UTC 2026
```

Released at the end, after teardown, by removing the directory.

## 1. Regular dev stack, via the Docker fallback engine

```
$ cd C:/Users/nasir/riftal-games
$ pwsh -NoProfile -File dev-stack.ps1 -Engine docker start
riftal-mysql ready
riftal-instance ready
relay ready on 127.0.0.1:19142 -> 192.168.0.123:19132
```

`riftal-instance`'s own log, read after the fact with `docker logs`, since
`dev-stack.ps1` only prints "ready":

```
[00:45:24.133] [Server thread/INFO]: Preparing world "mine_a"
[00:45:24.463] [Server thread/INFO]: Minecraft network interface running on 0.0.0.0:19132
[00:45:24.468] [Server thread/INFO]: Minecraft network interface running on [::]:19133
[00:45:24.468] [Server thread/INFO]: Done (0.992s)! For help, type "help" or "?"
```

## 2. Second instance, `riftal-instance-b`

`dev-stack.ps1` does not manage this one (`docs/dev-stack-two-instance.md` is the
translation that has never been folded into `.claude/skills/dev-stack/SKILL.md`
because no agent in this environment can edit that file). Run by hand, same shape as
that doc, adapted to the Docker fallback engine instead of `wslc`:

A copy of this command must append `--auto-report.enabled=0` to `POCKETMINE_ARGS`, or a crash uploads its dump; only `0` disables it, since `(bool) "false"` is `true` (riftal-infra#232).

```
$ docker volume create riftal-world-b
$ docker run -d -i --name riftal-instance-b --network riftal-dev \
    -p 0.0.0.0:19133:19132/udp \
    -v riftal-world-b:/data -v .../riftal-infra/images/plugins:/plugins \
    -e INSTANCE_ID=dev-2 -e RIFTAL_DEV_ENV=1 \
    -e "POCKETMINE_ARGS=--level-name=plots_b --level-type=flat --xbox-auth=false --motd=riftal-dev-b --riftal-dev-bots=on" \
    local-pocketmine-mp
```

```
[00:46:28.666] [Server thread/INFO]: Preparing world "plots_b"
[00:46:29.083] [Server thread/INFO]: Minecraft network interface running on 0.0.0.0:19132
[00:46:29.090] [Server thread/INFO]: Minecraft network interface running on [::]:19133
[00:46:29.091] [Server thread/INFO]: Done (1.15s)! For help, type "help" or "?"
```

## 3. Designer stack, alongside both

A copy of this command must append `--auto-report.enabled=0` to `POCKETMINE_ARGS`, or a crash uploads its dump; only `0` disables it, since `(bool) "false"` is `true` (riftal-infra#232).

```
$ docker volume create designer-world
$ docker run -d -i --name designer \
    -p 127.0.0.1:19134:19132/udp -p 127.0.0.1:19140:19140/tcp \
    -v designer-world:/data \
    -v .../riftal-infra/designer/stack/plugins:/plugins \
    -v .../riftal-game/designbridge:/plugins/DesignBridge:ro \
    -e DESIGNBRIDGE_TOKEN=local-dev-only \
    -e "POCKETMINE_ARGS=--level-name=design --level-type=normal --level-seed=20260907 --xbox-auth=false --gamemode=1 --max-players=4 --view-distance=16 --motd=riftal-designer" \
    local-pocketmine-mp
```

```
[00:48:09.703] [Server thread/INFO]: Loading DesignBridge v0.1.0
[00:48:09.953] [Server thread/INFO]: Preparing world "design"
[00:48:10.146] [Server thread/INFO]: [DesignBridge] enabled, bridge target 0.0.0.0:19140
[00:48:11.184] [Server thread/INFO]: Minecraft network interface running on 0.0.0.0:19132
[00:48:11.191] [Server thread/INFO]: Done (2.622s)! For help, type "help" or "?"
```

No bind failure anywhere. Confirmed by grepping all three containers' full logs for
`bind|address already in use|EMERGENCY|ALERT|CRITICAL|ERROR` once all three were up:
every one came back empty.

```
$ docker ps --filter "name=riftal-instance" --filter "name=designer" \
    --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
NAMES               STATUS              PORTS
designer            Up 25 seconds       19132/tcp, 19133/udp, 127.0.0.1:19140->19140/tcp, 127.0.0.1:19134->19132/udp
riftal-instance-b   Up About a minute   19132/tcp, 19133/udp, 0.0.0.0:19133->19132/udp
riftal-instance     Up 3 minutes        0.0.0.0:19132->19132/udp, 19132/tcp, 19133/udp
```

Three distinct host-side publishes, `19132`, `19133`, `19134`, on the one Docker
daemon, at the same time. This is the fact riftal-infra#157 asked for a live boot to
settle and PR #161 could only argue from the compose file.

## 4. The pong, from each of the three

The Docker fallback engine is the Docker inside the bridged `Ubuntu-26.04` WSL distro
(`dev-stack.ps1:44-46`), so `0.0.0.0`-bound publishes answer on that distro's own
network namespace at `127.0.0.1` as well as at its bridged LAN address. The designer
stack's `127.0.0.1`-only publish only ever answers inside that same namespace, so all
three pings below were run from inside `Ubuntu-26.04`, against `127.0.0.1`, for one
consistent vantage point across all three ports. The ping itself is a raw RakNet
Unconnected Ping/Pong exchange, standard library only (`socket`, `struct`), so it
depends on nothing this environment might not have:

```
$ wsl -d Ubuntu-26.04 -u runner -- python3 raknet_ping.py 127.0.0.1 19132 riftal-instance
[riftal-instance] 127.0.0.1:19132 PONG from ('127.0.0.1', 19132): MCPE;riftal-dev;2193;1.26.50;0;20;301103540578609707;Axolotl-PM;Survival;1;19132;19133;0;0;1;

$ wsl -d Ubuntu-26.04 -u runner -- python3 raknet_ping.py 127.0.0.1 19133 riftal-instance-b
[riftal-instance-b] 127.0.0.1:19133 PONG from ('127.0.0.1', 19133): MCPE;riftal-dev-b;2193;1.26.50;0;20;3175466232144512086;Axolotl-PM;Survival;1;19132;19133;0;0;1;

$ wsl -d Ubuntu-26.04 -u runner -- python3 raknet_ping.py 127.0.0.1 19134 designer
[designer] 127.0.0.1:19134 PONG from ('127.0.0.1', 19134): MCPE;riftal-designer;2193;1.26.50;0;4;3565515100548126753;Axolotl-PM;Creative;1;19132;19133;0;0;1;
```

Three pongs, three distinct MOTDs (`riftal-dev`, `riftal-dev-b`, `riftal-designer`),
three distinct server GUIDs, the same protocol (`2193`, `v1.26.50`, this environment's
current core build per `../../docs/decision-log.md`'s 2026-09-27 entry) and each
server's own player cap and game mode (`20`/Survival for both regular instances, `4`/
Creative for the designer stack, matching its `--max-players=4 --gamemode=1`). No
cross-talk: `riftal-instance` never answered on `19133` or `19134`, and neither
`riftal-instance-b` nor `designer` answered on a port that was not their own.

## Supplementary: the same two regular-stack ports from the Windows host

Not required by riftal-infra#162 (the pings above already prove the three ports don't
collide, from a single consistent vantage point), but cheap to add and closer to the
path a real client or `devtools/relay.js` actually takes: from Windows, through the
bridged distro address `dev-stack.ps1` itself discovered
(`relay ready on 127.0.0.1:19142 -> 192.168.0.123:19132`, above), using
`devtools/node_modules/bedrock-protocol`'s `ping()`:

```
$ node -e "... ping({host:'192.168.0.123', port:19132, timeout:3000, transport:'raknet'}) ..."
try 0 PONG {"motd":"riftal-dev", ..., "protocol":"2193","version":"1.26.50", ...}
try 1 PONG {"motd":"riftal-dev", ...}
try 2 PONG {"motd":"riftal-dev", ...}

$ node -e "... ping({host:'192.168.0.123', port:19133, timeout:3000}) ..."
riftal-instance-b 192.168.0.123:19133 {"motd":"riftal-dev-b", ..., "protocol":"2193","version":"1.26.50", ...}
```

One thing worth recording rather than silently discarding: the very first attempt at
`192.168.0.123:19132`, before pinning `transport: 'raknet'`, came back `NO PONG: All
promises were rejected`. `bedrock-protocol`'s default `ping()` races a `raknet` probe
against a `nethernet` one with `Promise.any` (`node_modules/bedrock-protocol/src/
createClient.js:118-129`); nothing on this stack speaks NetherNet, so that race can
lose to the doomed transport's rejection before the real RakNet reply lands, on a slow
first packet. Forcing `transport: 'raknet'` answered 3/3 immediately after, and every
`127.0.0.1`-vantage ping above (the primary evidence) answered first try every time.
Read as a client-side race in the ping helper's own transport selection, not a server
bind problem: no defect filed.

## 5. Teardown, in order

`designer` first (it depends on neither MySQL nor the other instances), then
`riftal-instance-b` (shares `riftal-mysql` with `riftal-instance` but nothing else
depends on it), then the regular stack via `dev-stack.ps1`'s own stop, which orders
relay, then instance, then MySQL.

```
$ docker stop -t 60 designer
[00:50:33.906] [Server thread/INFO]: Received signal interrupt, stopping the server
[00:50:33.909] [Server thread/INFO]: Disabling DesignBridge v0.1.0
[00:50:33.910] [Server thread/INFO]: Unloading world "design"
[00:50:34.119] [Server thread/INFO]: Stopping other threads
$ docker inspect designer --format '{{.State.Status}} {{.State.ExitCode}}'
exited 0
$ docker rm designer

$ docker stop -t 60 riftal-instance-b
[00:50:43.446] [Server thread/INFO]: Received signal interrupt, stopping the server
[00:50:43.447] [Server thread/INFO]: Unloading world "plots_b"
[00:50:43.464] [Server thread/INFO]: Stopping other threads
$ docker inspect riftal-instance-b --format '{{.State.Status}} {{.State.ExitCode}}'
exited 0
$ docker rm riftal-instance-b

$ pwsh -NoProfile -File dev-stack.ps1 -Engine docker stop
relay stopped
riftal-instance stopped
riftal-mysql stopped
$ docker inspect riftal-instance --format '{{.State.Status}} {{.State.ExitCode}}'
exited 0
```

Every stop went through the signal-into-clean-shutdown path
(`Received signal interrupt` / `Stopping the server` -> `Unloading world "<name>"` ->
`Stopping other threads`), never `kill`, and every exit code was `0`. `riftal-world-b`
and `designer-world` were left as named volumes; nothing was `docker volume rm`'d.
`riftal-instance` and `riftal-mysql` were left `Exited (0)`, the state they were found
in, since `dev-stack.ps1` only starts and stops those two, it never creates or removes
them.

Lock released last:

```
$ rm -rf C:/Users/nasir/riftal-games/devtools/.stack-lock
```

## Verdict

**Both stacks boot together. Each of the three ports, `19132`, `19133`, `19134`,
answers its own pong with its own MOTD, and none answers for another.** No bind
failure at any point, in any of the three containers' logs. This is the live proof
riftal-infra#157 asked for and riftal-infra#161 could not perform, closing the gap
between "the compose file no longer collides on paper" and "watched it not collide".

No defect found. PR #161's fix holds under an actual concurrent boot.
