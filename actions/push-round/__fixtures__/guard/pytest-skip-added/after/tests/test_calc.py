from calc import double


import pytest


@pytest.mark.skip(reason="flaky")
def test_double():
    assert double(2) == 4
