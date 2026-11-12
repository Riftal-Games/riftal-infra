#!/usr/bin/env python3
"""Lint one compose file under deploy/alpha/, read as written.

Reads the YAML itself, never the model `docker compose config` resolves, because
the rules judge what an operator wrote: an `image:` that is a literal tag, an
`environment:` key that would override `env_file:`, a mount line. Interpolation
is left alone.

Services. `mysql`, `backup` and `migrate` are named by the compose. Every other
service is a release-image service, so a stray or misnamed instance is judged by
the same rules instead of escaping them. The release tag is the tag `backup` and
`migrate` both name. `--alpha-root DIR` is the tree that holds deploy/alpha/;
its instances/<id>/image files are the definitions. A release-image service
finds its definition through an `env_file:` entry that resolves to
DIR/instances/<id>/instance.env.

ADR 043 items 3 and 4, on a release-image service:
  ALPHA_RELEASE_COMMAND, ALPHA_RELEASE_ENTRYPOINT  sets command: or entrypoint:
  ALPHA_RELEASE_MOUNT_RESERVED  mounts at, below or above /etc/riftal or
                                /opt/riftal, which would replace what the tag
                                delivers, through volumes:, tmpfs:, or the
                                target: of a configs: or secrets: entry
  ALPHA_RELEASE_VOLUMES_FROM    volumes_from:, which takes another service's
                                mounts past the rules on mounts
  ALPHA_RELEASE_ENV_ZONES, ALPHA_RELEASE_ENV_ARGS  sets RIFTAL_LEVEL_ZONES or
                                POCKETMINE_ARGS in environment:, which overrides
                                env_file: and boots what CI never read
  ALPHA_RELEASE_TAG_MISMATCH    its image: is not its instances/<id>/image
  ALPHA_RELEASE_ENV_FILE_EXTRA  an env_file: entry other than its definition's
                                instance.env, a second source for the flags

ADR 045 item 4:
  ALPHA_BACKUP_MIGRATE_TAG_DIFFER  backup and migrate name different tags
  ALPHA_RELEASE_TAG_UNNAMED        no definition names the release tag
  ALPHA_TOO_MANY_TAGS              definitions name more than one tag besides
                                   the release tag
  ALPHA_CAPTURE_MISSING_RO         a release-image service lacks
                                   riftal-capture:/capture:ro
  ALPHA_CAPTURE_RELEASE_RW         a release-image service mounts it read-write
  ALPHA_CAPTURE_RW_NOT_BACKUP      any other service but backup mounts it
                                   read-write
  ALPHA_BACKUP_MISSING_RO_MOUNT    an instance volume, the named volume at
                                   /data, has no <volume>:/worlds/<volume>:ro
                                   in backup
  ALPHA_BUILD_KEY                  a build: key
  ALPHA_RELATIVE_BIND              a bind of a relative path
  ALPHA_DATA_VOLUME_NOT_EXTERNAL   a named volume other than riftal-capture
                                   that is not declared external: true

Left to this lint by ADR 045 rows 17 and 18 and ADR 043 item 3:
  ALPHA_RESTART_NOT_ON_FAILURE  restart: is anything but on-failure
  ALPHA_RELEASE_HEALTHCHECK     a healthcheck: key
  ALPHA_RELEASE_BOOT_STARTS     RIFTAL_BOOT_STARTS in environment: or in an
                                env_file: of a release-image service

What the rules above need to read, and refuse when they cannot:
  ALPHA_EXTENDS                  extends: on any service, which takes keys from
                                 a service this lint never reads
  ALPHA_INCLUDE                  a top-level include:, which adds services this
                                 lint never judges
  ALPHA_SERVICE_MISSING          no backup, no migrate, or no release-image
                                 service
  ALPHA_IMAGE_TAG_UNREADABLE     an image: with no tag, with latest, with a
                                 digest instead, or with interpolation in it
  ALPHA_RELEASE_NO_DEFINITION    no env_file: entry resolves to
                                 instances/<id>/instance.env
  ALPHA_DEFINITION_IMAGE_UNREADABLE  that definition's image file is missing or
                                 does not hold one <image>:<tag> line

Usage: check_alpha_compose.py --alpha-root DIR FILE
Exit 0 when clean, 1 when there are findings, 2 when the input is unreadable.
"""

from __future__ import annotations

import posixpath
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write("check_alpha_compose.py needs PyYAML\n")
    raise SystemExit(2)

sys.dont_write_bytecode = True

from check_port_policy import Finding

OPS_SERVICES = {"mysql", "backup", "migrate"}
RESERVED_MOUNTS = ("/etc/riftal", "/opt/riftal")
CAPTURE_VOLUME = "riftal-capture"
CAPTURE_TARGET = "/capture"
INSTANCE_DATA_TARGET = "/data"
TAG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")


def image_tag(image):
    """The tag of a literal name:tag image, or None."""
    if not isinstance(image, str) or "@" in image or "$" in image:
        return None
    _, sep, tag = image.rpartition(":")
    if not sep or "/" in tag or tag == "latest" or not TAG_RE.match(tag):
        return None
    return tag


def mounts(service):
    """Every entry of volumes:, short or long syntax, as one shape."""
    found = []
    for entry in service.get("volumes") or []:
        if isinstance(entry, str):
            parts = entry.split(":")
            source = parts[0] if len(parts) > 1 else None
            target = parts[1] if len(parts) > 1 else parts[0]
            options = parts[2].split(",") if len(parts) > 2 else []
            read_only = "ro" in options
        elif isinstance(entry, dict):
            source = entry.get("source")
            target = entry.get("target")
            read_only = bool(entry.get("read_only"))
        else:
            continue
        source = None if source is None else str(source)
        is_bind = source is not None and (
            source.startswith(("/", ".", "~")) or "/" in source
        )
        if isinstance(entry, dict) and entry.get("type") == "bind":
            is_bind = True
        found.append(
            {
                "source": source,
                "target": posixpath.normpath(str(target)) if target else "",
                "read_only": read_only,
                "bind": is_bind,
            }
        )
    return found


def reserved_target(target):
    """The reserved path a mount target is at, below or above, or None."""
    for reserved in RESERVED_MOUNTS:
        if (
            target == reserved
            or target.startswith(reserved + "/")
            or reserved.startswith(target.rstrip("/") + "/")
        ):
            return reserved
    return None


def absolute_target(target, relative_base):
    target = str(target)
    if not target.startswith("/"):
        target = posixpath.join(relative_base, target)
    return posixpath.normpath(target)


def extra_mount_targets(service):
    """(key, target) of what tmpfs: and the long form of configs: and secrets:
    mount, which volumes: does not cover."""
    found = []
    tmpfs = service.get("tmpfs") or []
    if isinstance(tmpfs, str):
        tmpfs = [tmpfs]
    for entry in tmpfs:
        if isinstance(entry, str):
            found.append(("tmpfs", absolute_target(entry.split(":")[0], "/")))
    for key, base in (("configs", "/"), ("secrets", "/run/secrets")):
        for entry in service.get(key) or []:
            if isinstance(entry, dict) and entry.get("target"):
                found.append((key, absolute_target(entry["target"], base)))
    return found


def environment_keys(service):
    environment = service.get("environment")
    if isinstance(environment, dict):
        return set(environment)
    if isinstance(environment, list):
        return {str(item).split("=", 1)[0] for item in environment}
    return set()


def env_files(service, compose_dir):
    entries = service.get("env_file") or []
    if isinstance(entries, (str, dict)):
        entries = [entries]
    files = []
    for entry in entries:
        if isinstance(entry, dict):
            entry = entry.get("path")
        if isinstance(entry, str):
            files.append((compose_dir / entry).resolve())
    return files


def env_file_keys(path):
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return set()
    keys = set()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):]
        keys.add(line.split("=", 1)[0].strip())
    return keys


def read_definition_image(definitions, ident):
    """The one image line of instances/<id>/image, or None."""
    try:
        lines = (definitions / ident / "image").read_text(encoding="utf-8").split("\n")
    except OSError:
        return None
    if lines and lines[-1] == "":
        lines.pop()
    if len(lines) != 1 or image_tag(lines[0]) is None:
        return None
    return lines[0]


def definition_images(definitions):
    images = {}
    if definitions.is_dir():
        for entry in sorted(definitions.iterdir()):
            if entry.is_dir():
                images[entry.name] = read_definition_image(definitions, entry.name)
    return images


def lint(path, alpha_root, document, findings):
    compose_dir = Path(path).resolve().parent
    definitions = (Path(alpha_root) / "instances").resolve()
    services = document.get("services") or {}
    declared = document.get("volumes") or {}
    release = {n: s for n, s in services.items() if n not in OPS_SERVICES}

    def add(code, where, detail):
        findings.append(Finding(code, path, where, detail))

    if "include" in document:
        add(
            "ALPHA_INCLUDE",
            "include",
            "an include:, which adds services this lint does not read.",
        )

    not_external = set()
    for name, service in services.items():
        where = f"services.{name}"
        service_mounts = mounts(service)

        if "extends" in service:
            add(
                "ALPHA_EXTENDS",
                where,
                "an extends:, which takes keys from a service this lint does "
                "not read.",
            )

        if "build" in service:
            add("ALPHA_BUILD_KEY", where, "a build: key. An image is a tag.")

        for mount in service_mounts:
            if mount["bind"] and not (mount["source"] or "").startswith("/"):
                add(
                    "ALPHA_RELATIVE_BIND",
                    where,
                    f"binds {mount['source']}, a relative path.",
                )
            if (
                mount["source"] is not None
                and not mount["bind"]
                and mount["source"] != CAPTURE_VOLUME
            ):
                volume = declared.get(mount["source"])
                if (
                    not (isinstance(volume, dict) and volume.get("external"))
                    and mount["source"] not in not_external
                ):
                    not_external.add(mount["source"])
                    add(
                        "ALPHA_DATA_VOLUME_NOT_EXTERNAL",
                        f"volumes.{mount['source']}",
                        "holds data and is not declared external: true, so "
                        "a compose command can remove it.",
                    )

        captures = [m for m in service_mounts if m["source"] == CAPTURE_VOLUME]
        writable = [m for m in captures if not m["read_only"]]
        if name in release:
            if writable:
                add(
                    "ALPHA_CAPTURE_RELEASE_RW",
                    where,
                    f"mounts {CAPTURE_VOLUME} read-write. Only backup does.",
                )
            elif not any(m["target"] == CAPTURE_TARGET for m in captures):
                add(
                    "ALPHA_CAPTURE_MISSING_RO",
                    where,
                    f"has no {CAPTURE_VOLUME}:{CAPTURE_TARGET}:ro.",
                )
        elif name != "backup" and writable:
            add(
                "ALPHA_CAPTURE_RW_NOT_BACKUP",
                where,
                f"mounts {CAPTURE_VOLUME} read-write. Only backup does.",
            )

    tags = {}
    for name in ("backup", "migrate"):
        if name not in services:
            add("ALPHA_SERVICE_MISSING", "services", f"no {name} service.")
            continue
        tag = image_tag(services[name].get("image"))
        if tag is None:
            add(
                "ALPHA_IMAGE_TAG_UNREADABLE",
                f"services.{name}",
                f"image {services[name].get('image')!r} is not a literal "
                "name:tag, and latest is not a tag.",
            )
        else:
            tags[name] = tag
    if not release:
        add("ALPHA_SERVICE_MISSING", "services", "no release-image service.")

    release_tag = None
    if len(tags) == 2:
        if tags["backup"] != tags["migrate"]:
            add(
                "ALPHA_BACKUP_MIGRATE_TAG_DIFFER",
                "services",
                f"backup names {tags['backup']} and migrate {tags['migrate']}.",
            )
        else:
            release_tag = tags["backup"]

    images = definition_images(definitions)
    definition_tags = {image_tag(i) for i in images.values() if i is not None}
    if release_tag is not None:
        if release_tag not in definition_tags:
            add(
                "ALPHA_RELEASE_TAG_UNNAMED",
                "services",
                f"no instances/<id>/image names the release tag {release_tag}.",
            )
        others = sorted(definition_tags - {release_tag})
        if len(others) > 1:
            add(
                "ALPHA_TOO_MANY_TAGS",
                "services",
                f"definitions name {', '.join(others)} besides the release tag "
                f"{release_tag}. One is the most a serial rollout leaves behind.",
            )

    backup_mounts = mounts(services["backup"]) if "backup" in services else []

    for name, service in release.items():
        where = f"services.{name}"
        service_mounts = mounts(service)

        for key, code in (
            ("command", "ALPHA_RELEASE_COMMAND"),
            ("entrypoint", "ALPHA_RELEASE_ENTRYPOINT"),
            ("healthcheck", "ALPHA_RELEASE_HEALTHCHECK"),
            ("volumes_from", "ALPHA_RELEASE_VOLUMES_FROM"),
        ):
            if key in service:
                add(code, where, f"sets {key}:, which the release image owns.")

        for key, target in [
            ("volumes", m["target"]) for m in service_mounts
        ] + extra_mount_targets(service):
            reserved = reserved_target(target)
            if reserved is not None:
                add(
                    "ALPHA_RELEASE_MOUNT_RESERVED",
                    where,
                    f"{key} puts a mount at {target}, which covers {reserved}.",
                )

        keys = environment_keys(service)
        for key, code in (
            ("RIFTAL_LEVEL_ZONES", "ALPHA_RELEASE_ENV_ZONES"),
            ("POCKETMINE_ARGS", "ALPHA_RELEASE_ENV_ARGS"),
        ):
            if key in keys:
                add(
                    code,
                    where,
                    f"sets {key} in environment:, which overrides its "
                    "definition's instance.env.",
                )

        files = env_files(service, compose_dir)
        if "RIFTAL_BOOT_STARTS" in keys or any(
            "RIFTAL_BOOT_STARTS" in env_file_keys(f) for f in files
        ):
            add(
                "ALPHA_RELEASE_BOOT_STARTS",
                where,
                "sets RIFTAL_BOOT_STARTS, which moves the restart gate's file.",
            )

        if service.get("restart") != "on-failure":
            add(
                "ALPHA_RESTART_NOT_ON_FAILURE",
                where,
                f"restart is {service.get('restart', 'unset')!r}. The boot gate "
                "relies on on-failure.",
            )

        for mount in service_mounts:
            if mount["target"] != INSTANCE_DATA_TARGET or mount["bind"]:
                continue
            volume = mount["source"]
            if not any(
                b["source"] == volume
                and b["target"] == f"/worlds/{volume}"
                and b["read_only"]
                for b in backup_mounts
            ):
                add(
                    "ALPHA_BACKUP_MISSING_RO_MOUNT",
                    where,
                    f"mounts {volume} at {INSTANCE_DATA_TARGET}, and backup has "
                    f"no {volume}:/worlds/{volume}:ro.",
                )

        image = service.get("image")
        if image_tag(image) is None:
            add(
                "ALPHA_IMAGE_TAG_UNREADABLE",
                where,
                f"image {image!r} is not a literal name:tag, and latest is "
                "not a tag.",
            )

        definition_files = [
            f
            for f in files
            if f.name == "instance.env" and f.parent.parent == definitions
        ]
        ident = definition_files[0].parent.name if definition_files else None
        if definition_files:
            for env_file in files:
                if env_file != definition_files[0]:
                    add(
                        "ALPHA_RELEASE_ENV_FILE_EXTRA",
                        where,
                        f"env_file: lists {env_file}, and its definition's "
                        "instance.env is the only source of its flags.",
                    )
        if ident is None:
            add(
                "ALPHA_RELEASE_NO_DEFINITION",
                where,
                "no env_file: entry is an instances/<id>/instance.env of this "
                "tree, so its tag cannot be compared with a definition.",
            )
        elif images.get(ident) is None:
            add(
                "ALPHA_DEFINITION_IMAGE_UNREADABLE",
                where,
                f"instances/{ident}/image is missing or is not one "
                "<image>:<tag> line.",
            )
        elif image_tag(image) is not None and image != images[ident]:
            add(
                "ALPHA_RELEASE_TAG_MISMATCH",
                where,
                f"image {image} is not the {images[ident]} that "
                f"instances/{ident}/image records.",
            )


def main(argv):
    args = argv[1:]
    if len(args) != 3 or args[0] != "--alpha-root":
        sys.stderr.write(__doc__)
        return 2
    alpha_root, path = args[1], args[2]
    try:
        with open(path, encoding="utf-8") as handle:
            document = yaml.safe_load(handle)
    except (OSError, yaml.YAMLError) as exc:
        sys.stderr.write(f"{path}: cannot read the compose file: {exc}\n")
        return 2
    if not isinstance(document, dict):
        sys.stderr.write(f"{path}: the compose file is not a mapping\n")
        return 2

    findings = []
    lint(path, alpha_root, document, findings)
    for finding in findings:
        print(f"::error file={finding.path}::{finding}")
    print(f"{len(findings)} alpha lint finding(s) in {path}")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
