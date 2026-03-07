from __future__ import annotations

import os
import sys
from pathlib import Path
from string import Template

import snowflake.connector


def connect():
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        role=os.environ["SNOWFLAKE_ROLE"],
        warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
    )


def render(path: Path) -> str:
    return Template(path.read_text()).safe_substitute(os.environ)


def statements(sql: str) -> list[str]:
    return [statement.strip() for statement in sql.split(";") if statement.strip()]


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: apply_sql.py <file1> [file2...]", file=sys.stderr)
        return 2

    files = [Path(arg) for arg in sys.argv[1:]]
    connection = connect()
    try:
        with connection.cursor() as cursor:
            for path in files:
                sql = render(path)
                for statement in statements(sql):
                    cursor.execute(statement)
                    print(f"executed: {path.name}")
    finally:
        connection.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
