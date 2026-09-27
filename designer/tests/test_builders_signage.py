import pytest

from designer.builders.signage import Sign, SignageSpec, build_signage
from designer.edits import Text


def _spec(**over) -> SignageSpec:
    data = {"world": "design", "signs": [
        {"name": "sign_a", "pos": [0, 60, 0], "text": "welcome"},
        {"name": "sign_b", "pos": [4, 60, 0], "text": "sell shop -->"},
    ]}
    data.update(over)
    return SignageSpec.from_dict(data)


def test_sign_from_dict_rejects_a_missing_field() -> None:
    with pytest.raises(ValueError, match=r"missing \['text'\]"):
        Sign.from_dict({"name": "s", "pos": [0, 0, 0]})


def test_from_dict_rejects_a_missing_field() -> None:
    with pytest.raises(ValueError, match=r"missing \['signs'\]"):
        SignageSpec.from_dict({"world": "design"})


def test_from_dict_rejects_an_empty_sign_list() -> None:
    with pytest.raises(ValueError, match="at least one sign"):
        _spec(signs=[])


def test_from_dict_rejects_duplicate_names() -> None:
    with pytest.raises(ValueError, match="must be unique"):
        _spec(signs=[{"name": "dup", "pos": [0, 60, 0], "text": "a"}, {"name": "dup", "pos": [1, 60, 0], "text": "b"}])


def test_one_text_op_per_sign_keyed_by_name() -> None:
    spec = _spec()
    edits = build_signage(spec)
    texts = [op for op in edits.ops if isinstance(op, Text)]
    assert {(t.x, t.y, t.z, t.text, t.id) for t in texts} == {
        (0, 60, 0, "welcome", "sign_a"), (4, 60, 0, "sell shop -->", "sign_b"),
    }


def test_one_location_per_sign_tagged_sign() -> None:
    spec = _spec()
    edits = build_signage(spec)
    locations = edits.extras["locations"]
    assert {l["name"] for l in locations} == {"sign_a", "sign_b"}
    assert all(l["tags"] == ["sign"] and l["world"] == "design" for l in locations)
    by_name = {l["name"]: l for l in locations}
    assert by_name["sign_b"]["pos"] == [4, 60, 0]


def test_build_signage_is_deterministic() -> None:
    spec = _spec()
    assert build_signage(spec).to_json() == build_signage(spec).to_json()
