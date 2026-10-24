import sqlite3

import pytest

from fengshui_engine import db, minute, version


def test_version():
    assert version() == "0.1.0"


def test_minute_id():
    assert minute.minute_id(0) == 0
    assert minute.minute_id(59.999) == 0
    assert minute.minute_id(60) == 1
    assert minute.minute_id(-0.5) == -1
    assert minute.minute_id(1792843215.0) == 29880720


def test_create_and_check(tmp_path):
    p = str(tmp_path / "t.sqlite")
    conn = db.create(p)
    assert db.check_schema(conn) == 1
    assert conn.execute("PRAGMA journal_mode").fetchone()[0] == "wal"
    assert conn.execute("PRAGMA foreign_keys").fetchone()[0] == 1
    # Idempotent re-create.
    conn.close()
    db.create(p).close()


def test_unknown_schema_refused(tmp_path):
    p = str(tmp_path / "t.sqlite")
    db.create(p).close()
    c = sqlite3.connect(p)
    c.execute("INSERT INTO schema_version VALUES (99)")
    c.commit()
    c.close()
    with pytest.raises(db.SchemaError, match="unknown schema version 99"):
        db.check_schema(db.connect(p))


def test_missing_table_refused(tmp_path):
    p = str(tmp_path / "t.sqlite")
    db.create(p).close()
    c = sqlite3.connect(p)
    c.execute("DROP TABLE ai_log")
    c.commit()
    c.close()
    with pytest.raises(db.SchemaError, match="ai_log"):
        db.check_schema(db.connect(p))


def test_engine_state(tmp_path):
    conn = db.create(str(tmp_path / "t.sqlite"))
    assert db.get_state(conn, "x") is None
    db.set_state(conn, "x", "1")
    db.set_state(conn, "x", "2")
    assert db.get_state(conn, "x") == "2"


def test_run_refuses_bad_where(tmp_path):
    import fengshui_engine
    p = str(tmp_path / "t.sqlite")
    db.create(p).close()
    with pytest.raises(ValueError):
        fengshui_engine.run(p, now_ts=0, tz="UTC", where="mars")
    s = fengshui_engine.run(p, now_ts=0, tz="UTC", where="phone", tasks=[])
    assert s["engine_version"] == "0.1.0"
