def test_ci_goes_red_on_a_failing_test() -> None:
    assert False, "deliberate failure to prove the CI step can fail"
