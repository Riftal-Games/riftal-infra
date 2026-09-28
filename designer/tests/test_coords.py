import numpy as np
import pytest

from designer.coords import int_coord, int_coords

NOT_WHOLE = [-0.5, 2.9, float("nan"), float("inf"), True, "1", None]


def test_whole_numbers_of_any_numeric_type_are_accepted() -> None:
    assert int_coords([4.0, np.int64(-3), 7], "pos") == (4, -3, 7)


@pytest.mark.parametrize("bad", NOT_WHOLE)
def test_a_value_that_is_not_a_whole_number_is_rejected(bad: object) -> None:
    with pytest.raises(ValueError, match=r"pos, got \("):
        int_coords([0, bad, 0], "pos")


def test_a_whole_scalar_of_any_numeric_type_is_accepted() -> None:
    assert (int_coord(4.0, "y"), int_coord(np.int64(-3), "y"), int_coord(7, "y")) == (4, -3, 7)


@pytest.mark.parametrize("bad", NOT_WHOLE)
def test_a_scalar_that_is_not_a_whole_number_is_rejected(bad: object) -> None:
    with pytest.raises(ValueError, match=r"y, got "):
        int_coord(bad, "y")
