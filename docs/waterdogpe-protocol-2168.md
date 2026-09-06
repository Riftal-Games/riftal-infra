# Does WaterdogPE handle protocol 2168?

Finding for riftal-infra#3. Evidence gathered 2026-09-07. This answers the question
that riftal-infra#2, the proxy image, cannot start without: does the image pin a
released jar, or does it build from source? Those are two different Dockerfiles.

It does not build anything. It records what is true and what is still unproven.

## Short answer

**No stable WaterdogPE release handles protocol 2168.** The latest stable, v2.0.3,
tops out at protocol 766 (MCBE 1.21.50) and predates 1.26 entirely.

**A published, downloadable artifact does.** WaterdogPE's `master` branch declares
2168, 2168-with-1.26.44-hotfix and 2169, and the rolling `latest` snapshot jar built
from it contains those codecs. Verified by downloading the jar, not by reading a
changelog.

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

When each landed on `master`, from that file's commit history:

| Date | Commit | Change |
|---|---|---|
| 2026-07-31 | `fcab4c5c` | Add support for v26.40 (#444), protocol 2168 |
| 2026-08-14 | `5d300de8` | Add v1.26.44 support |
| 2026-08-20 | `6bfbb132` | Add 1.26.45 version support (2169) (#458) |
| 2026-08-20 | `c98ee3f6` | Fix internal protocol inconsistency |
| 2026-08-27 | `ebb281a8` | Fix v2168 BDS compatibility |

2168 support is five weeks old and was still being corrected in late August. It is not
a mature code path.

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
`26.45`. Class file major version is 61, so Java 17, matching the Java 17 or newer
requirement already recorded in this repo's platform facts.

The identical probe against the v2.0.3 jar
(`sha256 b2018db89d8a7a0a61e6733f09a901c080757367757bdb3c6c1fb18c8a9805e1`,
`git.build.version=2.0.3`) returns nothing for `codec/v2168` or `codec/v2169`. Its
three highest codecs are 729, 748 and 766. This is the negative control: the probe
discriminates, it does not simply match everything.

WaterdogPE also publishes container images to `ghcr.io/waterdogpe/waterdogpe`. Tags
available on 2026-09-07: `latest`, `waterdog-2`, `master`, `release`, `2.0.0`,
`2.0.1`, `2.0.2`, `2.0.3`. There is no `2.0.4` tag. Current digests:

```
latest  sha256:0069d069ce97c0f9944cef8e4b229311674f4e313e6e9132be303a36e404a168
2.0.3   sha256:3e194df33af482990c72eb61a01eac01a2a0e195d91b17dc0acf58042d5fd725
```

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
packet serialization **without bumping the protocol number**, which is why
`ProtocolVersion` needs a second discriminator (`protocolInternal`) and the separate
`Bedrock_v2168_hotfix4` codec to tell 1.26.40 and 1.26.44 apart at the same number
2168.

This lands on us. `pmmp-core` pins `axolotl-pm/bedrock-protocol` at
`59.0.1+bedrock-1.26.40` (`composer.json:39`, `composer.lock:148`, reference
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
tag: `.github/workflows/build.yml` on `master` recreates the release with
`prerelease_name: "latest"` on every push, so the jar behind that URL is replaced
without notice. Pinning by URL is not reproducible and violates this repo's own rule
that a deploy is an immutable tag. Two ways to get immutability back: pin the ghcr
digest above, or build from a pinned commit SHA. Both are real work for #2 and both
mean running unreleased code in production.

**B. Wait for a stable v2.0.4.**
The `release` branch head is `2dfd9fa8`, dated 2024-12-04, the v2.0.3 release commit.
It has not moved in nine months. There is no `2.0.4` tag, no `2.0.4` ghcr tag, and one
unrelated open PR (#455). I found no announced date. Waiting has no visible end, and
M0's sentence needs a proxy.

**C. Move the protocol target.**
The proxy does not force this either way. `master` covers 2168 and 2169 in the same
build, so choosing 26.44 or 26.45 in `pmmp-core#4` is not gated by WaterdogPE. This
option buys nothing on the proxy side and should not be adopted for proxy reasons.

Option C is the one the evidence retires. A and B are Nasir's call.

## What #2 can rely on regardless of that choice

These hold under A and under B, so the proxy image work is not fully blocked:

- **Java 17 is the floor**, confirmed from bytecode major version 61 in both jars, not
  from documentation.
- **The image is ours, on `ubuntu:24.04`.** Upstream's own Dockerfile is
  `FROM eclipse-temurin:17-jdk-jammy`, which is Ubuntu 22.04 and conflicts with hard
  rule 7. Consuming `ghcr.io/waterdogpe/waterdogpe` directly inherits that base. The
  proxy image should install a JRE onto our base and add the jar.
- **Building from source currently resolves.** `gradle/libs.versions.toml` at master
  head pins `protocol = "3.0.0.Beta13-20260824.114016-17"` and
  `raklib = "1.1.0.CR1-20260820.174333-6"`. Both are timestamped snapshots, and both
  were fetchable from `repo.opencollab.dev/maven-snapshots` on 2026-09-07 (HTTP 200).
  A build from source therefore depends on a snapshot repository retaining timestamped
  artifacts. I did not check its retention policy, so treat that as an unmeasured risk
  rather than a safe assumption.
- **`19132` is UDP.** Upstream's Dockerfile exposes both `19132/tcp` and `19132/udp`.
  Only the UDP publish carries players.

## Method

Everything above came from `gh` against `WaterdogPE/WaterdogPE`, `curl` against the
release and registry endpoints, and `unzip` of the two jars. No claim rests on a
README or a changelog summary. Where a claim rests on someone else's report rather
than a measurement, it says so.

## Verdict against the original risk

`../docs/decision-log.md` recorded, on 2026-08-11, that "WaterdogPE's latest stable at
bootstrap was 2.0.3, with 2.0.4-SNAPSHOT on master, and its coverage of the current
Bedrock protocol is unconfirmed."

Confirmed, and now specific. v2.0.3 stops at protocol 766. 2.0.4-SNAPSHOT is still
what carries 2168, still unreleased, and the version numbers in that entry have not
moved in the intervening nine months.
