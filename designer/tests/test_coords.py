import numpy as np
import pytest

from designer.coords import int_coords


def test_whole_numbers_of_any_numeric_type_are_accepted() -> None:
    assert int_coords([4.0, np.int64(-3), 7], "pos") == (4, -3, 7)


@pytest.mark.parametrize("bad", [-0.5, 2.9, float("nan"), float("inf"), True, "1", None])
def test_a_value_that_is_not_a_whole_number_is_rejected(bad: object) -> None:
    with pytest.raises(ValueError, match=r"pos, got \("):
        int_coords([0, bad, 0], "pos")
