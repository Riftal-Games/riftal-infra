# Does WaterdogPE handle protocol 2193?

Finding for riftal-infra#106. Evidence gathered 2026-09-28. `pmmp-core#4`/PR #45
rebased the fork onto upstream 5.49.1, Bedrock 1.26.50, **protocol 2193**
(`riftal-pm/docs/decision-log.md`, 2026-09-27), so that is the number a proxy in
front of it has to advertise. This document answers the same question this
workspace has now asked three times at three different numbers, 2168 then 2169 then
2193, each time the fork's own target moved. It does not build anything. It records
what is true and what is still unproven.

## Current answer, protocol 2193

**No stable WaterdogPE release handles protocol 2193.** The latest stable release is
still v2.0.3, unchanged since 2024-12-04 (`gh api repos/WaterdogPE/WaterdogPE/releases`,
checked 2026-09-28), topping out at protocol 766 and predating 1.26 entirely.

**`master` declares 2193, with one codec, and no divergence between the two
display names it covers.** Verified 2026-09-28 by cloning
`https://github.com/WaterdogPE/WaterdogPE.git` at `master` head
`c76a112f51c4dc3b2551ff739c69da8b8b81e859` (committed 2026-09-27T21:43:51Z) and
reading `ProtocolVersion.java` directly. Line 157:

```java
MINECRAFT_PE_1_26_50(2193, Bedrock_v2193.CODEC, "26.50", "26.51"),
```

One `Bedrock_v2193` codec, no second `Bedrock_v2193_*` import, no second enum entry
at 2193. That is the opposite shape from 2168, which needed
`Bedrock_v2168` **and** `Bedrock_v2168_hotfix4` at lines 154-155 of the same file
(preserved below) because 1.26.40 and 1.26.44 shared a protocol number but not a
wire format. Nothing in `master`'s own table says 26.50 and 26.51 have that problem.

**26.52, the build PR #45's body reports an actual device joining with, has no entry
in `master`'s table at all.** The enum ends at `MINECRAFT_PE_1_26_50`. That is silence,
not a negative finding: it says WaterdogPE has not catalogued 26.52 as its own entry,
not that 26.52 diverges from 26.50/26.51's codec.

### 2193 itself arrived corrected, not settled on the first try

The same commit history method that caught the 2168/1.26.44 problem, read fresh
against `ProtocolVersion.java`'s history via
`gh api repos/WaterdogPE/WaterdogPE/commits?path=...`, shows 2193 needed three
follow-up commits after it first appeared:

| Date (UTC) | Commit | Change |
|---|---|---|
| 2026-09-10T00:18:51Z | `da683c11` | Adds 1.26.50 as **protocol 2192**, new codec class `Bedrock_v2192` |
| 2026-09-15T16:05:46Z | `cca3bb25` | Renumbers the entry to **2193**, still using the `Bedrock_v2192` codec class unchanged |
| 2026-09-15T17:12:17Z | `38d358cf` | Patches that same codec at runtime, `Bedrock_v2192.CODEC.toBuilder().protocolVersion(2193).build()`, to report 2193 without a matching codec class |
| 2026-09-22T22:16:39Z | `42b73d74` | Adds a real `Bedrock_v2193` codec class and switches to it; "26.51" is added as a second display name on the same entry |

So the number 1.26.50 first shipped under, 2192, was wrong for five days, and the
patched-in-place codec that followed the correction lasted one more week before a
dedicated `Bedrock_v2193` codec replaced it. That final commit is six days old at
this evidence date. This is the same class of risk the original 2168 finding named,
version-number churn on WaterdogPE's own side rather than on the client's, and it is
resolved as of `42b73d74`, not before it. A build pinned to a `master` commit before
2026-09-22 would advertise 2193 without actually running the codec that now backs it.

Confirmed independently in the downloadable artifact, not only in source: the
`latest` snapshot jar downloaded 2026-09-28
(`sha256:2b74e370003da8e45b3f0fb551ec4dec9cc980cf128b385c2fa2e97d22fe1934`,
`git.properties` inside it reads `git.commit.id=c76a112f51c4dc3b2551ff739c69da8b8b81e859`,
matching the clone) contains a real, distinct `org/cloudburstmc/protocol/bedrock/codec/v2193/`
package with its own serializers (`BossEventSerializer_v2193`, `CameraPresetsSerializer_v2193`,
`DebugDrawerSerializer_v2193`, `PlayerAuthInputSerializer_v2193`, and more), not a
renamed copy of `v2168`'s classes, alongside the still-present `v2168` package from
the earlier finding. Downloading the jar and listing its contents, not reading a
changelog.

**Nobody in this workspace has watched a 2193 client connect through a WaterdogPE
proxy.** That is the same tier 3 gap the original finding left open at 2168, and
riftal-infra#28 (filed to close it) still names the older number; it needs the same
update this document just got, and is flagged separately.

## What #2 can still rely on

Unchanged from the original finding, re-confirmed 2026-09-28 against the same jar:

- **Java 17 is the floor.** `ProtocolVersion.class` inside the 2026-09-28 snapshot jar
  has bytecode major version 61 (`cafebabe 0000 003d`), same as the 2026-09-07 jar.
- **`19132` is UDP.** Unchanged; not re-checked this round, no reason to expect a
  change.
- **The image is ours, on `ubuntu:24.04`.** Unchanged; upstream's own Dockerfile
  still targets a different base and should not be consumed directly.

The rest of this document is the 2026-09-07 finding at 2168, later read against
2169. It is preserved because its tier 1/2/3 method and its account of what changed
between 1.26.40 and 1.26.44 with no protocol bump are still the reference case this
document points back to above. Its own "short answer" and decision below are
superseded by the current answer above; nothing past this point should be read as
describing WaterdogPE's support for 2193.

## Short answer, 2168 (superseded, kept as the reference case above points to)

**No stable WaterdogPE release handles protocol 2168.** The latest stable, v2.0.3,
tops out at protocol 766 (MCBE 1.21.50) and predates 1.26 entirely.

**A published, downloadable artifact contains the 2168 codecs.** WaterdogPE's `master`
branch declares 2168, 2168-with-1.26.44-hotfix and 2169, and the rolling `latest`
snapshot jar built from it ships those codec classes. Verified by downloading the jar,
not by reading a changelog. Shipping a codec is not the same as handling a client, so
this is a tier 2 claim and stops there.

Nobody in this workspace has watched a 2168 client connect through a WaterdogPE
proxy. That step is not done and is not claimed below.

Because the answer is "master yes, stable no", the choice of what to depend on is
Nasir's. See [The decision this forces](#the-decision-this-forces).

## Evidence, in three tiers

These are deliberately separate. A version that declares support in source, a version
with an artifact you can download, and a version observed carrying a real client are
three different claims, and only the third is proof that players can connect.

### Tier 1, declared in source

`ProtocolVersion.java` at `master` head `23c834e16a9a0a7cb2aa504b6ae28b358a6892c4`
(committed 2026-09-03T21:38:08Z) declares, at lines 153 to 155:

```java
MINECRAFT_PE_1_26_40(2168, Bedrock_v2168.CODEC, "26.40", "26.41", "26.42", "26.43"),
MINECRAFT_PE_1_26_44(2168, 1, Bedrock_v2168_hotfix4.CODEC, "26.44"), // this version has not bumped protocol number on client side
MINECRAFT_PE_1_26_45(2169, Bedrock_v2169.CODEC, "26.45"),
```

Path: `src/main/java/dev/waterdog/waterdogpe/network/protocol/ProtocolVersion.java`.

The same file at tag `v2.0.3` ends at line 119 with
`MINECRAFT_PE_1_21_50(766, Bedrock_v766.CODEC);`. No 1.26 entry of any kind.

When each landed, from that file's own commit history
(`gh api "repos/WaterdogPE/WaterdogPE/commits?sha=23c834e1&path=<the file>"`). This is
every commit touching `ProtocolVersion.java` from the arrival of 2168 to master head,
with none omitted:

| Date | Commit | Change |
|---|---|---|
| 2026-07-31 | `fcab4c5c` | Add support for v26.40 (#444), protocol 2168 |
| 2026-08-14 | `5d300de8` | Add v1.26.44 support |
| 2026-08-15 | `e764e7cd` | Fix 26.11 being listed twice |
| 2026-08-20 | `6bfbb132` | Add 1.26.45 version support (2169) (#458) |
| 2026-08-20 | `c98ee3f6` | Fix internal protocol inconsistency |

Two later `master` commits also bear on 2168 but are **not** in that file's history.
They are cited separately, with the files they touched, so the provenance is not
blurred:

| Date | Commit | Files touched | Change |
|---|---|---|---|
| 2026-08-27 | `ebb281a8` | `ConnectedUpstreamHandler.java`, `PlayerRewriteUtils.java` | Fix v2168 BDS compatibility |
| 2026-08-27 | `44c5e404` | `PlayerRewriteUtils.java` | Update comment, follows the above by four minutes |

`ebb281a8` matters more than its one-line message suggests. It gives
`injectAirSubChunkResponse` a `ProtocolVersion` argument and branches on
`version.isBefore(ProtocolVersion.MINECRAFT_PE_1_26_40)`, changing how sub-chunk
responses are serialized at 2168 and above. That helper runs on the **downstream
switch path**, which is the move this repo is built around.

2168 support is five weeks old and was still being corrected in late August, in the
enum and in the packet handling around it. It is not a mature code path.

### Tier 2, present in a downloadable artifact

Downloaded 2026-09-07 from the `latest` release:

```
https://github.com/WaterdogPE/WaterdogPE/releases/download/latest/Waterdog.jar
sha256  0c90b6910c703035ff545d1d788a11a30e874739dfa9c101b869c396ae14e1f4
size    40463130
```

`git.properties` inside that jar:

```
git.branch=master
git.build.version=2.0.4-SNAPSHOT
git.commit.id=23c834e16a9a0a7cb2aa504b6ae28b358a6892c4
git.commit.time=2026-09-03T21:38:08+0000
```

The jar is therefore the tier 1 source tree, compiled. It contains:

```
org/cloudburstmc/protocol/bedrock/codec/v2168/Bedrock_v2168.class
org/cloudburstmc/protocol/bedrock/codec/v2168/Bedrock_v2168_hotfix4.class
org/cloudburstmc/protocol/bedrock/codec/v2169/Bedrock_v2169.class
```

and `ProtocolVersion.class` carries the constants `MINECRAFT_PE_1_26_40`,
`MINECRAFT_PE_1_26_44`, `MINECRAFT_PE_1_26_45` with display strings `26.40` through
`26.45`.

The negative control is the stable jar, downloaded the same day by the same method:

```
https://github.com/WaterdogPE/WaterdogPE/releases/download/v2.0.3/Waterdog.jar
sha256  b2018db89d8a7a0a61e6733f09a901c080757367757bdb3c6c1fb18c8a9805e1
size    40041966
```

`git.properties` inside it reads `git.build.version=2.0.3`,
`git.commit.id=2dfd9fa83356c990aa30c76bd55866db11cec819`. The identical probe returns
nothing for `codec/v2168` or `codec/v2169`. Its three highest codecs are 729, 748 and
766, and its `ProtocolVersion.class` carries `MINECRAFT_PE_1_21_50` and no
`MINECRAFT_PE_1_26_*`. So the probe discriminates rather than matching everything, and
the empty side is empty because the codecs are absent, not because the file could not
be read.

Class file major version is 61 in **both** jars, read from the first eight bytes of
`ProtocolVersion.class` in each. Java 17 is therefore the floor for the stable line and
the snapshot line alike, and that is measured rather than taken from documentation.

WaterdogPE also publishes container images to `ghcr.io/waterdogpe/waterdogpe`. Read
from the registry API on 2026-09-07, `GET /v2/waterdogpe/waterdogpe/tags/list`
returned exactly: `latest`, `waterdog-2`, `master`, `release`, `2.0.0`, `2.0.1`,
`2.0.2`, `2.0.3`. There is no `2.0.4` tag. Digests from the
`docker-content-digest` header on that date:

```
latest  sha256:0069d069ce97c0f9944cef8e4b229311674f4e313e6e9132be303a36e404a168
2.0.3   sha256:3e194df33af482990c72eb61a01eac01a2a0e195d91b17dc0acf58042d5fd725
```

A tag list and a `latest` digest are both point-in-time readings of mutable
references. The digests are the only durable half; re-read the tag before relying on
it. That is the same objection this document raises against the jar URL, and it
applies here too.

### Tier 3, observed carrying a client

**Not established here, and it is the tier that decides whether players connect.**

The nearest evidence is second-hand and comes out of a bug report. Upstream issue
[#456](https://github.com/WaterdogPE/WaterdogPE/issues/456), opened 2026-08-15 and
still open, contains a third-party proxy log from a user running `master`:

```
[Bedrock Listener - #8] INFO  - [.../...|Fikrethan] <-> Upstream has connected (protocol=2168 version=1.26.44)
[Bedrock Listener - #8] INFO  - Encryption enabled for ...
```

That is a 2168 client completing login and encryption against a `master` build. It is
someone else's log, on someone else's downstream, quoted inside a report that the same
session then failed. It is worth exactly what it is and no more.

What would settle tier 3: run the snapshot jar as a proxy in front of our own core
image and join from a real 1.26.4x device. That is PLAYABLE, and only Nasir can claim
it. An intermediate step is available and cheaper: stand the proxy up and confirm its
RakNet ping answers and that a downstream connection is established, which is
REACHABLE plus a login, still short of a join.

## What is not yet safe, and is not a proxy bug

Issue #456 is not about a client failing to connect. It is about 1.26.44 changing
packet serialization **without bumping the protocol number**, so telling 1.26.40 and
1.26.44 apart at the same number 2168 needs a second discriminator alongside the
separate `Bedrock_v2168_hotfix4` codec.

Be precise about what is new there, because it is easy to overstate. The
`protocolInternal` field is not new. It exists at `v2.0.3` (line 130 of that file),
where `MINECRAFT_PE_1_21_50_29(765, 766, ...)` at line 118 used it as a plain second
protocol number: a private ordering key borrowed from the protocol number space. What
changed on `master` is the encoding, to
`this.protocolInternal = (protocol << 2) | (internalPatch & 0x3);`, at line 183 of that
file at `23c834e1`. That is what `isBefore()` orders on.

The reason it changed is worth following, because it is a collision between two of the
three options below. Reconstructed from the three commit patches, with timestamps from
the API:

| When | Commit | The 1.26.44 entry after it |
|---|---|---|
| 2026-08-14T19:46:55Z | `5d300de8` | `MINECRAFT_PE_1_26_44(2168, 2169, Bedrock_v2168_hotfix4.CODEC, "26.44")` |
| 2026-08-20T12:48:17Z | `6bfbb132` | `MINECRAFT_PE_1_26_44(2168, Bedrock_v2168_hotfix4.CODEC, "26.44")` |
| 2026-08-20T14:16:42Z | `c98ee3f6` | `MINECRAFT_PE_1_26_44(2168, 1, Bedrock_v2168_hotfix4.CODEC, "26.44")` |

1.26.44 had a discriminator from the day it landed, in the old raw-second-number form,
and the number it borrowed was **2169**. 5 days 17 hours later `6bfbb132` gave 2169 to a
real protocol, 1.26.45, and in the same hunk stripped the `2169` argument off 1.26.44.

The collapse that follows is read from the tree at `6bfbb132`, not from a later
commit's pre-image. At that tree, `ProtocolVersion.java:153-154` has both 1.26.40 and
1.26.44 taking the two-argument constructor, and line 179 delegates
`this(protocol, protocol, codec, displayNames)`. So both resolve to
`protocolInternal = 2168`, and `isBefore()`, which compares exactly that field at line
190, cannot separate them. The ordering keys across the three commits:

```
after 5d300de8   1_26_40 = 2168   1_26_44 = 2169
after 6bfbb132   1_26_40 = 2168   1_26_44 = 2168
after c98ee3f6   1_26_40 = 8672   1_26_44 = 8673
```

`c98ee3f6` restored the distinction 1h28m25s later by packing a two-bit patch index into
the low bits, freeing the ordering key from the protocol number space, and converted the
two other raw-second-number entries, 1.19.62 and 1.21.110, in the same commit.

**Fact, and stated flat:** one hunk of `6bfbb132` both assigns 2169 to 1.26.45 and
removes it from 1.26.44, and at that commit the two 2168 variants share an ordering key.

**Inference, and marked wherever it appears:** that 2169's arrival is *why* the current
encoding exists. That reading rests on the sequence and on `c98ee3f6`'s message, "Fix
internal protocol inconsistency", and no commit states it. A competing explanation fits
the same evidence: the sweep of 1.19.62 and 1.21.110 is what a planned refactor away
from raw second numbers would look like, and it may have been coming regardless.

Two things this does **not** say. The discriminator was never missing by oversight; it
was displaced for 1h28m25s. And issue #456 was opened 2026-08-15, after `5d300de8` and
before that window, so it is not a symptom of it.

This lands on us. `pmmp-core` pins `axolotl-pm/bedrock-protocol` at
`59.0.1+bedrock-1.26.40` (`composer.json:39`; `composer.lock:147` names the package,
`:148` the version, `:152` and `:157` the reference
`7528264597919647eb11bb6a2bfe08b75430907f`). That pin is labelled 1.26.40, not
1.26.44. A 1.26.44 client will pass the proxy's protocol check at 2168 and then reach
a downstream that may serialize some packets the older way. Whether our pin carries
the hotfix is a `pmmp-core` question and is unverified here.

Consequence for planning: "proxy accepts 2168" and "our downstream understands every
client that advertises 2168" are separate facts. The first is close to settled; the
second is open.

## The decision this forces

No stable release covers 2168, so something has to give. The options and their real
costs, presented without a recommendation because this entangles `pmmp-core#4`, which
Nasir has deferred.

**A. Depend on the master snapshot.**
Available today, covers 2168 and 2169. The cost is that `latest` is a mutable rolling
tag: `.github/workflows/build.yml:30-31` at master head sets `create_prerelease` on
`refs/heads/master` with `prerelease_name: "latest"`, so the release is recreated and
the jar behind that URL replaced on every push, without notice. Pinning by URL is not
reproducible and violates this repo's own rule that a deploy is an immutable tag. Two
ways to get immutability back: pin the ghcr digest above, or build from a pinned
commit SHA. Both are real work for #2 and both mean running unreleased code in
production.

**B. Wait for a stable v2.0.4.**
The `release` branch head is `2dfd9fa8`, dated 2024-12-04, the v2.0.3 release commit.
It has not moved in the 21 months to this evidence date. There is no `2.0.4` tag, no
`2.0.4` ghcr tag, and one unrelated open PR (#455). I found no announced date. The cost
is therefore an unbounded wait: nothing observable here predicts when it ends, and M0
has no proxy until it does.

**C. Move the protocol target to 2169.**
Not gated either way, and not free either way. `master` carries 2168 and 2169 in the
same build, so WaterdogPE does not force the 26.44-versus-26.45 choice in
`pmmp-core#4`. But the two are not equivalent on the proxy side, and this is where the
narrow claim must not be widened:

- At **2168** the proxy has to tell 1.26.40 from 1.26.44 at one protocol number, using
  `protocolInternal` and a second codec, `Bedrock_v2168_hotfix4`. That discrimination
  landed 2026-08-14, 24 days before this evidence date. It was then displaced for
  1h28m25s on 2026-08-20, and was never missing by oversight. It is the subject of open
  upstream issue #456.
- At **2169** there is one codec, `Bedrock_v2169`, and nothing to discriminate. The
  ambiguity that #456 lives in does not exist there.

C and the status quo interact directly, so read this before choosing either.
**Assigning 2169 to 1.26.45 is the same change that stripped 1.26.44's ordering key**:
one hunk of `6bfbb132` does both. At that commit, `ProtocolVersion.java:153-154` shows
1.26.40 and 1.26.44 both taking the two-argument constructor, which at line 179
delegates `this(protocol, protocol, codec, displayNames)`, so both resolve to
`protocolInternal = 2168` and `isBefore()` can no longer separate them. That is read
from the tree at `6bfbb132`, not from a later diff, and it is fact rather than
inference.

**Inference, not fact:** that 2169's arrival is *why* the current encoding exists. It is
the reading the sequence and `c98ee3f6`'s message support, and no commit states it.
There is a competing explanation this document cannot rule out: `c98ee3f6` also
converted 1.19.62 and 1.21.110 away from raw second numbers, which is what a planned
refactor would look like, and such a refactor may have been coming regardless.

Either way the mechanical point stands and is the one that bears on C: the encoding
2168's two-variant handling depends on is 18 days old, and it arrived in the same
commit that repaired that collision.

So C buys a genuinely simpler proxy path. What it costs is a `pmmp-core` protocol move
Nasir has deferred, on top of everything in `pmmp-core#4`, and 2169's WaterdogPE
support is younger still, landing 2026-08-20 in `6bfbb132` against 2168's 2026-07-31.
Newer and simpler are not the same thing, and neither has been observed here.

All three are Nasir's call. This document deliberately picks none of them.

## What #2 can rely on regardless of that choice

These hold under A, B and C, so the proxy image work is not fully blocked:

- **Java 17 is the floor**, confirmed from bytecode major version 61 in both jars, not
  from documentation.
- **The image is ours, on `ubuntu:24.04`.** Upstream's own `Dockerfile:1` at master
  head is `FROM eclipse-temurin:17-jdk-jammy`, which is Ubuntu 22.04 and conflicts with
  hard rule 7. Consuming `ghcr.io/waterdogpe/waterdogpe` directly inherits that base.
  The proxy image should install a JRE onto our base and add the jar.
- **Building from source currently resolves.** `gradle/libs.versions.toml:2-3` at
  master head pins `raklib = "1.1.0.CR1-20260820.174333-6"` and
  `protocol = "3.0.0.Beta13-20260824.114016-17"`. Both are timestamped snapshots, and
  both returned HTTP 200 from `repo.opencollab.dev/maven-snapshots` on 2026-09-07. A
  build from source therefore depends on a snapshot repository retaining timestamped
  artifacts. I did not check its retention policy, so treat that as an unmeasured risk
  rather than a safe assumption.
- **`19132` is UDP.** Upstream's `Dockerfile:3-4` exposes `19132/tcp` and `19132/udp`.
  Only the UDP publish carries players.

Every upstream path in this section is read at master head
`23c834e16a9a0a7cb2aa504b6ae28b358a6892c4`, the same commit as tiers 1 and 2. `master`
moves without notice, so a path without a SHA is not a citation anyone can re-check.

## Method

Everything above came from `gh` against `WaterdogPE/WaterdogPE`, `curl` against the
release and registry endpoints, and `unzip` of the two jars. No claim rests on a
README or a changelog summary. Where a claim rests on someone else's report rather
than a measurement, it says so. Upstream file paths are cited at a commit SHA, because
`master` is a moving target and this document's own argument turns on that.

Two cautions for anyone extending this. They are the same mistake wearing different
clothes: provenance inferred instead of established.

`commits?sha=<ref>` lists commits on a branch. `commits?sha=<ref>&path=<file>` lists
only those touching that file. They look alike and are not, and attributing a row from
the first to the second overstates where a change happened. This is why the late-August
fixes are in their own table with the files they touched.

A diff hunk's removed lines are the state **before that commit**, not the state created
by whichever commit introduced the feature. Reading
`- MINECRAFT_PE_1_26_44(2168, Bedrock_v2168_hotfix4.CODEC, "26.44")` out of
`c98ee3f6` says only that the line existed at `c98ee3f6~1`. Establishing which commit
wrote it needs its own lookup, and here the `+` side that wrote it belongs to
`6bfbb132`, 5 days 17 hours after the commit it is easiest to assume. To attribute a
line, find the commit whose `+` side added it. Better still, when the claim is about
what the code did rather than who changed it, read the file at that tree, which is
where the shared ordering key above is established.

## Verdict against the original risk

`../../docs/decision-log.md:39` recorded, on 2026-08-11, that "WaterdogPE's latest
stable at bootstrap was 2.0.3, with 2.0.4-SNAPSHOT on master, and its coverage of the
current Bedrock protocol is unconfirmed."

Confirmed, and now specific. v2.0.3 stops at protocol 766. 2.0.4-SNAPSHOT is still
what carries 2168 and is still unreleased. Both version numbers in that entry are
unchanged 27 days later, and the stable one has been unchanged since 2024-12-04.

Still true 51 days later, at 2193: v2.0.3 has not moved, and the codec the fork now
needs still lives only on the unreleased snapshot. See
[Current answer, protocol 2193](#current-answer-protocol-2193) above.
