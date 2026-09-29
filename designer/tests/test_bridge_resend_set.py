from designer.bridge import IDEMPOTENT_OPS

# Spec 001 (riftal-pm docs/specs/001-designer-toolchain.md, The toolkit) lists the
# resend set by hand. Changing IDEMPOTENT_OPS must fail here until the spec changes too.
SPEC_001_RESEND_SET = frozenset({
    "ping", "server_info", "list_worlds", "get_region", "get_heightmap", "get_light",
    "get_job", "cancel_job", "list_entities", "tail_log", "scan_items",
})


def test_resend_set_matches_spec_001() -> None:
    assert IDEMPOTENT_OPS == SPEC_001_RESEND_SET
