"""Gate: a Python test opens a database created by the Swift (GRDB) migrations.
The iOS unit test DatabaseTests writes build/swift_created.sqlite; test_all.sh runs
this file again after the iOS layer (layer `python-swiftdb`)."""

import os

import pytest

from conftest import ROOT
from fengshui_engine import db

PATH = ROOT / "build" / "swift_created.sqlite"


@pytest.mark.skipif(not PATH.exists() and not os.environ.get("FENGSHUI_REQUIRE_SWIFT_DB"),
                    reason="run the iOS unit tests first (scripts/test_all.sh does)")
def test_swift_created_db_passes_engine_schema_check():
    assert PATH.exists(), "build/swift_created.sqlite missing"
    conn = db.connect(str(PATH))
    assert db.check_schema(conn) == 1
    sql = {r[0]: r[1] for r in conn.execute("SELECT name, sql FROM sqlite_master WHERE type='table'")}
    ref = db.create(":memory:")
    want = {r[0]: r[1] for r in ref.execute("SELECT name, sql FROM sqlite_master WHERE type='table'")}
    for name, s in want.items():
        assert sql.get(name) == s, name
