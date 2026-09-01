#!/usr/bin/env python3
"""Talk to the hbu RAG database without knowing where it is.

Terraform publishes the connection details to SSM under ``/<project>-<env>/db/*``
and lets RDS keep the master password in Secrets Manager. This resolves both,
so nothing here — and nothing in the app — carries an endpoint that changes
every time the instance is replaced, or a password that has to be pasted.

    ./scripts/db.py url                  # connection URL, password included
    ./scripts/db.py env [--app]          # shell exports; --app for the pipeline role
    ./scripts/db.py ca                   # RDS root cert, for sslmode=verify-full
    ./scripts/db.py bootstrap            # roles + grants, and the app password
    ./scripts/db.py init                 # apply sql/*.sql in name order
    ./scripts/db.py check                # extensions, tables, corpus, index metadata
    ./scripts/db.py shell                # psql, or a REPL if psql is absent
    ./scripts/db.py query "select 1"     # one statement, printed as a table
    ./scripts/db.py wait                 # block until the instance accepts TCP
    ./scripts/db.py start | stop         # for a scheduled-shutdown instance

Every command takes ``--env`` (default ``dev``) and honours ``AWS_PROFILE``.
Set ``DATABASE_URL`` to bypass AWS resolution entirely — a local
postgis+pgvector container, or an already-open SSM tunnel. Append
``?sslmode=disable`` for a server that speaks no TLS.

``--tunnel`` is the lighter version of that, and what the private posture
needs: credentials, database name, and instance id still come from AWS, and
only the address is redirected to an open ``make db-tunnel`` session.

Two databases' worth of ownership meet here, and the split matters:
``rag.chunks`` belongs to hbu_dataplatform, which creates it on first load;
this repo's sql/ owns the roles that schema belongs to, the extensions, the
spatial tables, and the functions that join the two. See the README.

Importable too, which is the point of the ``connect`` helper:

    from db import connect
    with connect(env="dev") as conn: ...
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass, replace
from functools import lru_cache
from pathlib import Path
from urllib.parse import quote as url_quote

SQL_DIR = Path(__file__).resolve().parent.parent / "sql"

DEFAULT_PROJECT = os.environ.get("HBU_PROJECT", "hbu")
DEFAULT_ENV = os.environ.get("HBU_ENV", "dev")
DEFAULT_REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"

#: Where `db.py ca` puts the RDS root certificate, and where libpq looks by
#: default — so verify-full works with no PGSSLROOTCERT set at all.
CA_BUNDLE = Path.home() / ".postgresql" / "root.crt"

# Cosmetic only, and skipped when stdout is not a terminal so piped output
# stays greppable.
_TTY = sys.stdout.isatty()
DIM = "\033[2m" if _TTY else ""
BOLD = "\033[1m" if _TTY else ""
RED = "\033[31m" if _TTY else ""
GREEN = "\033[32m" if _TTY else ""
RESET = "\033[0m" if _TTY else ""


class DbError(RuntimeError):
    """Anything the caller should read rather than see a traceback for."""


# ---------------------------------------------------------------------------
# Resolving the connection
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Connection:
    host: str
    port: int
    dbname: str
    user: str
    password: str
    instance_id: str | None = None
    #: require is right for RDS, which rejects cleartext anyway. A local
    #: postgres+postgis container speaks no TLS at all and needs `disable`,
    #: which is why this is read from DATABASE_URL rather than fixed.
    sslmode: str = "require"

    def url(self, *, hide_password: bool = False) -> str:
        secret = "***" if hide_password else url_quote(self.password, safe="")
        return (
            f"postgresql://{url_quote(self.user, safe='')}:{secret}"
            f"@{self.host}:{self.port}/{self.dbname}?sslmode={self.sslmode}"
        )

    def kwargs(self) -> dict:
        return {
            "host": self.host,
            "port": self.port,
            "dbname": self.dbname,
            "user": self.user,
            "password": self.password,
            "sslmode": self.sslmode,
        }


@lru_cache(maxsize=None)
def _aws(service: str, region: str):
    try:
        import boto3
    except ImportError as exc:  # pragma: no cover - environment problem
        raise DbError("boto3 is not installed — `pip install -r scripts/requirements.txt`") from exc
    return boto3.client(service, region_name=region)


def _ssm_values(project: str, env: str, region: str) -> dict[str, str]:
    prefix = f"/{project}-{env}"
    ssm = _aws("ssm", region)

    values: dict[str, str] = {}
    paginator = ssm.get_paginator("get_parameters_by_path")
    try:
        for page in paginator.paginate(Path=prefix, Recursive=True, WithDecryption=True):
            for param in page["Parameters"]:
                values[param["Name"][len(prefix) + 1 :]] = param["Value"]
    except ssm.exceptions.ClientError as exc:
        raise DbError(f"could not read SSM parameters under {prefix}: {exc}") from exc

    if "db/host" not in values:
        raise DbError(
            f"no database parameters under {prefix} in {region}.\n"
            f"  Has `make apply ENV={env}` run? Is AWS_PROFILE pointing at the right account?"
        )

    return values


def _master_secret(secret_arn: str, region: str) -> dict:
    secrets = _aws("secretsmanager", region)
    try:
        return json.loads(secrets.get_secret_value(SecretId=secret_arn)["SecretString"])
    except Exception as exc:
        raise DbError(
            f"could not read the master password from {secret_arn}: {exc}\n"
            "  The RDS-managed secret needs secretsmanager:GetSecretValue."
        ) from exc


def _from_ssm(project: str, env: str, region: str) -> Connection:
    values = _ssm_values(project, env, region)
    secret_arn = values["db/secret_arn"]
    payload = _master_secret(secret_arn, region)

    return Connection(
        host=values["db/host"],
        port=int(values["db/port"]),
        dbname=values["db/name"],
        user=values["db/user"],
        password=payload["password"],
        instance_id=values.get("db/instance_id"),
    )


def _from_url(url: str) -> Connection:
    from urllib.parse import parse_qs, unquote, urlparse

    parsed = urlparse(url)
    if parsed.scheme not in {"postgres", "postgresql"}:
        raise DbError(f"DATABASE_URL must be a postgresql:// URL, got {parsed.scheme!r}")
    query = parse_qs(parsed.query)
    return Connection(
        host=parsed.hostname or "localhost",
        port=parsed.port or 5432,
        dbname=(parsed.path or "/postgres").lstrip("/"),
        user=unquote(parsed.username or "postgres"),
        password=unquote(parsed.password or ""),
        sslmode=query.get("sslmode", ["require"])[0],
    )


#: Set by --tunnel. A database with no public endpoint is reachable only
#: through `make db-tunnel`, but everything except the address is unchanged, so
#: this swaps the host and port after resolution rather than before it: the
#: credentials, the database name, and the instance id still come from AWS.
_LOCAL_PORT: int | None = None


def resolve(
    env: str = DEFAULT_ENV,
    *,
    project: str = DEFAULT_PROJECT,
    region: str = DEFAULT_REGION,
    through_tunnel: bool = True,
) -> Connection:
    """Connection details, from DATABASE_URL if set and from AWS otherwise.

    ``through_tunnel=False`` returns the database's real address even while
    --tunnel is in effect. Anything that *connects* wants the default; anything
    that *records* the endpoint for someone else to read wants the real one.
    """
    override = os.environ.get("DATABASE_URL")
    details = _from_url(override) if override else _from_ssm(project, env, region)
    if through_tunnel and _LOCAL_PORT is not None:
        # 127.0.0.1, not "localhost": the Session Manager plugin binds IPv4
        # only, and on a machine that resolves localhost to ::1 first libpq
        # burns the entire connect_timeout on the dead address before falling
        # back. The connection still succeeds, which is what makes it look like
        # a slow tunnel rather than a misresolution.
        details = replace(details, host="127.0.0.1", port=_LOCAL_PORT)
    return details


# ---------------------------------------------------------------------------
# Connecting
# ---------------------------------------------------------------------------


def _driver():
    """psycopg 3 if present, psycopg2 otherwise, with one clear error if not."""
    try:
        import psycopg

        return psycopg, 3
    except ImportError:
        pass
    try:
        import psycopg2

        return psycopg2, 2
    except ImportError:
        pass
    raise DbError(
        "no postgres driver installed — `pip install -r scripts/requirements.txt`\n"
        "  (psycopg[binary] bundles libpq, so there is no system psql to install)"
    )


def connect(env: str = DEFAULT_ENV, **kwargs):
    """Open a connection. The returned object is a context manager."""
    details = kwargs.pop("connection", None) or resolve(env, **kwargs)
    driver, version = _driver()
    if version == 3:
        return driver.connect(**details.kwargs(), autocommit=True)
    conn = driver.connect(**details.kwargs())
    conn.autocommit = True
    return conn


def _run(conn, sql: str, params=None) -> tuple[list[str], list[tuple]]:
    with conn.cursor() as cur:
        # Passing no parameters at all, rather than an explicit None, is what
        # keeps psycopg on the simple query protocol — which is the only one
        # that accepts a whole .sql file's worth of statements in one call.
        if params is None:
            cur.execute(sql)
        else:
            cur.execute(sql, params)
        if cur.description is None:
            return [], []
        return [d[0] for d in cur.description], list(cur.fetchall())


def _table(columns: list[str], rows: list[tuple], *, max_width: int = 60) -> str:
    if not columns:
        return f"{DIM}(no rows returned){RESET}"

    def cell(value) -> str:
        text = "" if value is None else str(value)
        text = " ".join(text.split())
        return text if len(text) <= max_width else text[: max_width - 1] + "…"

    body = [[cell(v) for v in row] for row in rows]
    widths = [
        max(len(col), *(len(r[i]) for r in body)) if body else len(col)
        for i, col in enumerate(columns)
    ]
    line = "-+-".join("-" * w for w in widths)
    out = [
        BOLD + " | ".join(c.ljust(w) for c, w in zip(columns, widths)) + RESET,
        DIM + line + RESET,
    ]
    out += [" | ".join(c.ljust(w) for c, w in zip(row, widths)) for row in body]
    out.append(f"{DIM}({len(body)} row{'s' if len(body) != 1 else ''}){RESET}")
    return "\n".join(out)


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def cmd_url(args) -> int:
    print(resolve(args.env, region=args.region).url(hide_password=args.hide_password))
    return 0


def cmd_secret(args) -> int:
    """Print the RDS-managed master secret with URL-safe connection helpers."""
    values = _ssm_values(DEFAULT_PROJECT, args.env, args.region)
    payload = _master_secret(values["db/secret_arn"], args.region).copy()

    password = str(payload.get("password", ""))
    host = str(payload.get("host") or values["db/host"])
    port = int(payload.get("port") or values["db/port"])
    dbname = str(payload.get("dbname") or values["db/name"])
    user = str(payload.get("username") or values["db/user"])

    payload.setdefault("host", host)
    payload.setdefault("port", port)
    payload.setdefault("dbname", dbname)
    payload.setdefault("username", user)
    payload["password_urlencoded"] = url_quote(password, safe="")
    payload["database_url"] = Connection(
        host=host,
        port=port,
        dbname=dbname,
        user=user,
        password=password,
    ).url()

    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


def _shell_export(name: str, value: object) -> None:
    print(f"export {name}={shlex.quote(str(value))}")


def cmd_env(args) -> int:
    """Shell exports: `eval "$(./scripts/db.py env)"`.

    Both dialects, because two things read this. PG* is what psql and libpq
    pick up; URBAN_RAG_PG_* is what the dataplatform's PgSettings.from_env
    reads, so the same eval configures a `urban-rag` run against this instance.

    These are the MASTER credentials. For the pipeline's own role, use
    `--app`, which points URBAN_RAG_PG_SECRET_ID at the app secret and lets
    PgSettings resolve the password itself rather than putting it in a shell.
    """
    details = resolve(args.env, region=args.region)

    if args.app:
        prefix = f"/{DEFAULT_PROJECT}-{args.env}"
        ssm = _aws("ssm", args.region)
        try:
            secret_id = ssm.get_parameter(Name=f"{prefix}/db/app_secret_arn")["Parameter"]["Value"]
        except Exception as exc:
            raise DbError(f"no {prefix}/db/app_secret_arn - apply the Terraform first") from exc
        # The role the secret belongs to, exported alongside it. Leaving this
        # out was not neutral: the plain `env` above exports
        # URBAN_RAG_PG_USER=hbu_admin, so evaluating that and then this in the
        # same shell — or pasting the result into a .env — left the master
        # username paired with the app role's password, and every connection
        # failed as `password authentication failed for user "hbu_admin"`.
        # The two halves of one credential are now always emitted together.
        try:
            app_user = ssm.get_parameter(Name=f"{prefix}/db/app_user")["Parameter"]["Value"]
        except Exception as exc:
            raise DbError(
                f"no {prefix}/db/app_user - apply the Terraform first"
            ) from exc
        # HOST and HOSTADDR are split for the same reason the pipeline's .env
        # splits them: the exports below set verify-full, and the certificate is
        # issued to the endpoint, so HOST has to keep naming the endpoint for
        # the hostname check while HOSTADDR carries the address the socket
        # actually goes to. Exporting the tunnel address as HOST instead paired
        # verify-full with a name the certificate does not cover, and every
        # connection failed on `server certificate for ... does not match host
        # name "127.0.0.1"`.
        endpoint = resolve(args.env, region=args.region, through_tunnel=False)
        _shell_export("URBAN_RAG_PG_HOST", endpoint.host)
        if details.host != endpoint.host:
            _shell_export("URBAN_RAG_PG_HOSTADDR", details.host)
        _shell_export("URBAN_RAG_PG_PORT", details.port)
        _shell_export("URBAN_RAG_PG_DATABASE", details.dbname)
        _shell_export("URBAN_RAG_PG_USER", app_user)
        _shell_export("URBAN_RAG_PG_SECRET_ID", secret_id)
        _shell_export("URBAN_RAG_PG_REGION", args.region)
        _shell_export("URBAN_RAG_PG_SSLMODE", "verify-full")
        _shell_export("PGSSLROOTCERT", CA_BUNDLE)
        return 0

    _shell_export("PGHOST", details.host)
    _shell_export("PGPORT", details.port)
    _shell_export("PGDATABASE", details.dbname)
    _shell_export("PGUSER", details.user)
    _shell_export("PGPASSWORD", details.password)
    _shell_export("PGSSLMODE", "require")
    _shell_export("DATABASE_URL", details.url())
    _shell_export("URBAN_RAG_PG_HOST", details.host)
    _shell_export("URBAN_RAG_PG_PORT", details.port)
    _shell_export("URBAN_RAG_PG_DATABASE", details.dbname)
    _shell_export("URBAN_RAG_PG_USER", details.user)
    _shell_export("URBAN_RAG_PG_PASSWORD", details.password)
    _shell_export("URBAN_RAG_PG_REGION", args.region)
    return 0


def cmd_ca(args) -> int:
    """Download the RDS CA bundle that sslmode=verify-full needs.

    verify-full is the only mode that authenticates the server rather than just
    encrypting the link, and it is the dataplatform's default — but it needs a
    root certificate on disk to check the endpoint against.
    """
    import urllib.request

    target = Path(args.output).expanduser()
    target.parent.mkdir(parents=True, exist_ok=True)
    url = "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
    print(f"{url}\n  -> {target}")
    urllib.request.urlretrieve(url, target)
    print(f"  {GREEN}ok{RESET} ({target.stat().st_size // 1024} KB)")
    print(f"  {DIM}export PGSSLROOTCERT={target}{RESET}")
    return 0


def _requires(sql: str) -> str | None:
    """The relation a file names in a leading `-- requires: <name>` comment."""
    for line in sql.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if not stripped.startswith("--"):
            break
        match = re.match(r"--\s*requires:\s*(\S+)", stripped)
        if match:
            return match.group(1)
    return None


def cmd_init(args) -> int:
    details = resolve(args.env, region=args.region)
    files = sorted(SQL_DIR.glob("*.sql"))
    if not files:
        raise DbError(f"no .sql files in {SQL_DIR}")

    applied = skipped = 0
    with connect(connection=details) as conn:
        # HNSW builds are memory-bound; RDS defaults this to 64MB on a
        # db.t4g.micro. Doubling it for this session only is the safe move —
        # shared_buffers already claims ~25% of the instance's 1 GiB, and an
        # index that does not fit spills to disk (slow) rather than failing.
        _run(conn, "SET maintenance_work_mem = '128MB'")

        for path in files:
            sql = path.read_text(encoding="utf-8")

            # A file may declare a relation it cannot be parsed without —
            # rag.chunks belongs to the dataplatform and does not exist until
            # its first load. Skipping it is information, not an error.
            required = _requires(sql)
            if required:
                _, rows = _run(conn, "SELECT to_regclass(%s)", (required,))
                if not rows or rows[0][0] is None:
                    print(f"{BOLD}{path.name}{RESET} {DIM}skipped — {required} does not exist yet{RESET}")
                    skipped += 1
                    continue

            print(f"{BOLD}{path.name}{RESET}")
            try:
                _run(conn, sql)
            except Exception as exc:
                raise DbError(f"{path.name} failed: {exc}") from exc
            print(f"  {GREEN}ok{RESET}")
            applied += 1

    print(f"\n{GREEN}{applied} file(s) applied{RESET}" + (f", {skipped} skipped" if skipped else ""))
    if skipped:
        print(f"{DIM}Re-run once the dataplatform's document_index asset has created rag.chunks.{RESET}")
    return 0


#: Applied by `bootstrap` as well as by `init` — which is why it sorts first.
ROLES_FILE = "000_roles.sql"


def cmd_bootstrap(args) -> int:
    """Create the app roles, then give the pipeline's role its password.

    `sql/000_roles.sql` creates the `urban_rag` login role, the `rag` and
    `dagster` schemas it owns and the grants — the things the pipeline's own
    role is deliberately not privileged enough to create for itself. `init`
    applies that file too, in name order, so what is only ever done here is the
    credential: generate a password, set it, and put it where the pipeline
    reads it from.
    """
    import secrets as secrets_module

    path = SQL_DIR / ROLES_FILE
    if not path.exists():
        raise DbError(f"{path} not found — it is applied from this repo's sql/")

    details = resolve(args.env, region=args.region)
    password = args.app_password or secrets_module.token_urlsafe(24)

    with connect(connection=details) as conn:
        print(f"applying {path.name} as {details.user}")
        try:
            _run(conn, path.read_text(encoding="utf-8"))
        except Exception as exc:
            raise DbError(f"{path.name} failed: {exc}") from exc

        # ALTER ROLE ... PASSWORD takes a literal, not a bind parameter, so the
        # value has to be rendered into the statement rather than sent beside
        # it. Doubling any quote is the whole of the escaping that needs, and a
        # generated password has none to double.
        role = '"' + args.app_user.replace('"', '""') + '"'
        literal = "'" + password.replace("'", "''") + "'"
        try:
            _run(conn, f"ALTER ROLE {role} WITH PASSWORD {literal}")
        except Exception as exc:
            raise DbError(f"setting the {args.app_user} password failed: {exc}") from exc
    print(f"  {GREEN}ok{RESET}")

    if args.store_password:
        _store_app_password(args, details, password)
        print(f"  {GREEN}stored{RESET} in the app-role secret — the pipeline reads it from there")
    else:
        print(f"\n  app role password: {BOLD}{password}{RESET}")
        print(f"  {DIM}re-run with --store-password to put it in Secrets Manager instead{RESET}")
    return 0


def _store_app_password(args, details: "Connection", password: str) -> None:
    """Write the generated password into the secret Terraform created for it.

    ``details`` is what we connected as, which under --tunnel is a local port.
    The endpoint written here is read by every other consumer of the secret, on
    machines with no tunnel of their own, so it is resolved again without the
    override. Writing the tunnel address instead pinned `host` at localhost for
    everyone and silently overrode the pipeline's own URBAN_RAG_PG_HOST.
    """
    prefix = f"/{DEFAULT_PROJECT}-{args.env}"
    ssm = _aws("ssm", args.region)
    try:
        secret_id = ssm.get_parameter(Name=f"{prefix}/db/app_secret_arn")["Parameter"]["Value"]
    except Exception as exc:
        raise DbError(f"no {prefix}/db/app_secret_arn parameter — apply the Terraform first") from exc

    # The shape PgSettings.secret_id expects, which is also the shape RDS
    # writes for a password it manages itself.
    endpoint = resolve(args.env, region=args.region, through_tunnel=False)

    _aws("secretsmanager", args.region).put_secret_value(
        SecretId=secret_id,
        SecretString=json.dumps(
            {
                "username": args.app_user,
                "password": password,
                "engine": "postgres",
                "host": endpoint.host,
                "port": endpoint.port,
                "dbname": endpoint.dbname,
            }
        ),
    )


def cmd_check(args) -> int:
    details = resolve(args.env, region=args.region)
    with connect(connection=details) as conn:
        print(f"{BOLD}server{RESET}")
        cols, rows = _run(conn, "SELECT version()")
        print("  " + rows[0][0].split(" on ")[0])
        print("  " + f"{details.user}@{details.host}:{details.port}/{details.dbname}")

        print(f"\n{BOLD}extensions{RESET}")
        cols, rows = _run(
            conn,
            """
            SELECT e.name AS extension,
                   COALESCE(x.extversion, '-') AS installed,
                   e.default_version AS available
              FROM pg_available_extensions e
              LEFT JOIN pg_extension x ON x.extname = e.name
             WHERE e.name IN ('postgis', 'vector', 'pg_trgm', 'pg_stat_statements')
             ORDER BY e.name
            """,
        )
        print(_table(cols, rows))
        missing = [r[0] for r in rows if r[1] == "-"]
        if missing:
            print(f"  {RED}not installed: {', '.join(missing)}{RESET} — run `db.py init`")

        # One block per medallion schema, in the order data moves through them.
        # `p` — a partitioned table — is listed as such rather than as a table:
        # every silver/gold table is one, and its own row holds nothing, so
        # seeing "0 rows" next to a partitioned parent should not read as a
        # load that failed. The leaves are counted under `partitions` below.
        for schema, source in (
            ("rag", "the spatial working set and the corpus"),
            ("silver", "one table per silver asset"),
            ("gold", "one table per gold asset"),
        ):
            print(f"\n{BOLD}{schema} schema{RESET} {DIM}({source}){RESET}")
            cols, rows = _run(
                conn,
                """
                SELECT c.relname AS object,
                       CASE c.relkind
                            WHEN 'r' THEN 'table'
                            WHEN 'p' THEN 'partitioned'
                            WHEN 'v' THEN 'view'
                            ELSE c.relkind::text END AS kind,
                       COALESCE(s.n_live_tup, 0) AS rows,
                       pg_size_pretty(pg_total_relation_size(c.oid)) AS size
                  FROM pg_class c
                  JOIN pg_namespace n ON n.oid = c.relnamespace
                  LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
                 WHERE n.nspname = %s
                   AND c.relkind IN ('r', 'p', 'v')
                   -- Leaves are listed by `partitions` below, at the grain
                   -- they are actually managed at.
                   AND NOT EXISTS (
                       SELECT 1 FROM pg_inherits i WHERE i.inhrelid = c.oid
                   )
                 ORDER BY c.relkind, c.relname
                """,
                (schema,),
            )
            print(
                _table(cols, rows)
                if rows
                else f"  {DIM}empty — run `db.py init`{RESET}"
            )

        # What `warehouse.ensure_partition` has created so far: one row per
        # (table, borough, month) that has ever been written. The read to run
        # before detaching or dropping anything.
        _, exists = _run(conn, "SELECT to_regclass('warehouse.partitions')")
        if exists and exists[0][0] is not None:
            print(f"\n{BOLD}partitions{RESET} {DIM}(silver + gold leaves){RESET}")
            cols, rows = _run(
                conn,
                """
                SELECT table_schema, table_name, partition, rows,
                       pg_size_pretty(bytes) AS size
                  FROM warehouse.partitions
                """,
            )
            print(
                _table(cols, rows)
                if rows
                else f"  {DIM}none yet — the pipeline creates one per borough-month "
                f"on its first write{RESET}"
            )

        print(f"\n{BOLD}dagster schema{RESET}")
        cols, rows = _run(
            conn,
            """
            SELECT c.relname AS object,
                   CASE c.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view' ELSE c.relkind::text END AS kind,
                   COALESCE(s.n_live_tup, 0) AS rows,
                   pg_size_pretty(pg_total_relation_size(c.oid)) AS size
              FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
              LEFT JOIN pg_stat_user_tables s ON s.relid = c.oid
             WHERE n.nspname = 'dagster' AND c.relkind IN ('r', 'v', 'i', 'S')
             ORDER BY c.relkind, c.relname
            """,
        )
        print(
            _table(cols, rows)
            if rows
            else f"  {DIM}empty - first Dagster start creates its tables{RESET}"
        )

        # rag.chunks and rag.corpus_status are created by the dataplatform's
        # first load, not by this repo, so their absence is a stage of setup
        # rather than a fault.
        _, exists = _run(conn, "SELECT to_regclass('rag.corpus_status')")
        if exists and exists[0][0] is not None:
            print(f"\n{BOLD}corpus{RESET}")
            cols, rows = _run(conn, "SELECT * FROM rag.corpus_status")
            print(_table(cols, rows))

            # The vector width and the model that produced it live here,
            # written by the dataplatform on load. This is the only place they
            # are recorded, on purpose: a second copy in SSM or in a config
            # file is a second thing that can disagree with the vectors.
            _, meta = _run(conn, "SELECT to_regclass('rag.chunks_meta')")
            if meta and meta[0][0] is not None:
                cols, rows = _run(conn, "SELECT key, value FROM rag.chunks_meta ORDER BY key")
                print(f"\n{BOLD}index metadata{RESET}")
                print(_table(cols, rows))
        else:
            print(
                f"\n{DIM}rag.chunks not created yet — the dataplatform's document_index"
                f" asset creates it on first load, then `db-init` adds the spatial"
                f" search functions over it.{RESET}"
            )
    return 0


def cmd_query(args) -> int:
    sql = Path(args.file).read_text(encoding="utf-8") if args.file else args.sql
    if not sql:
        raise DbError("give a statement, or -f FILE")
    with connect(env=args.env, region=args.region) as conn:
        cols, rows = _run(conn, sql)
    if args.json:
        print(json.dumps([dict(zip(cols, r)) for r in rows], default=str, indent=2))
    else:
        print(_table(cols, rows))
    return 0


def cmd_shell(args) -> int:
    details = resolve(args.env, region=args.region)
    psql = shutil.which("psql")
    if psql:
        env = {**os.environ, "PGPASSWORD": details.password}
        return subprocess.call(
            [
                psql,
                f"--host={details.host}",
                f"--port={details.port}",
                f"--dbname={details.dbname}",
                f"--username={details.user}",
                "--set=sslmode=require",
            ],
            env=env,
        )

    print(f"{DIM}psql not found — using the built-in REPL. ';' ends a statement, Ctrl-D exits.{RESET}")
    with connect(connection=details) as conn:
        buffer: list[str] = []
        while True:
            try:
                line = input("... " if buffer else f"{details.dbname}=# ")
            except (EOFError, KeyboardInterrupt):
                print()
                return 0
            buffer.append(line)
            if not line.rstrip().endswith(";"):
                continue
            statement = "\n".join(buffer).rstrip().rstrip(";")
            buffer = []
            if not statement.strip():
                continue
            try:
                cols, rows = _run(conn, statement)
                print(_table(cols, rows))
            except Exception as exc:
                print(f"{RED}{exc}{RESET}")


def cmd_wait(args) -> int:
    """Poll until the database accepts a connection, or report why it will not."""
    import socket
    import time

    details = resolve(args.env, region=args.region)
    deadline = time.monotonic() + args.timeout
    attempt = 0

    while time.monotonic() < deadline:
        attempt += 1
        try:
            with socket.create_connection((details.host, details.port), timeout=5):
                print(f"{GREEN}{details.host}:{details.port} is accepting connections{RESET}")
                return 0
        except OSError as exc:
            remaining = int(deadline - time.monotonic())
            print(f"{DIM}attempt {attempt}: {exc.__class__.__name__} — {remaining}s left{RESET}")
            # A timeout on a public endpoint is almost always one of two things,
            # and guessing wrong costs ten minutes, so check rather than guess.
            if attempt == 3:
                _diagnose(details, args.region)
            time.sleep(5)

    raise DbError(f"{details.host}:{details.port} did not come up within {args.timeout}s")


def _diagnose(details: Connection, region: str) -> None:
    if not details.instance_id:
        return
    try:
        rds = _aws("rds", region)
        instance = rds.describe_db_instances(DBInstanceIdentifier=details.instance_id)["DBInstances"][0]
        status = instance["DBInstanceStatus"]
        if status != "available":
            print(f"  {RED}instance status is '{status}'{RESET}", end="")
            print(" — `db.py start` if it was stopped on schedule" if status == "stopped" else "")
            return
        if not instance.get("PubliclyAccessible"):
            print(f"  {RED}instance has no public endpoint{RESET} — connect through the bastion (`make db-tunnel`)")
            return
        print(
            f"  {DIM}instance is available and public; the security group probably does not"
            f" list your current IP. Re-run `make apply` to refresh it.{RESET}"
        )
    except Exception:
        pass  # diagnosis is a courtesy, never the reason a command fails


def _instance_action(args, action: str) -> int:
    details = resolve(args.env, region=args.region)
    if not details.instance_id:
        raise DbError("no instance id published — is DATABASE_URL pointing somewhere local?")
    rds = _aws("rds", args.region)
    method = getattr(rds, f"{action}_db_instance")
    try:
        method(DBInstanceIdentifier=details.instance_id)
    except rds.exceptions.InvalidDBInstanceStateFault as exc:
        raise DbError(f"cannot {action} {details.instance_id}: {exc}") from exc
    print(f"{GREEN}{action}ing{RESET} {details.instance_id} — takes a few minutes")
    return 0


def cmd_start(args) -> int:
    return _instance_action(args, "start")


def cmd_stop(args) -> int:
    return _instance_action(args, "stop")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="db.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--env", default=DEFAULT_ENV, help=f"environment (default: {DEFAULT_ENV})")
    parser.add_argument("--region", default=DEFAULT_REGION, help=f"AWS region (default: {DEFAULT_REGION})")
    parser.add_argument(
        "--tunnel",
        nargs="?",
        const=5433,
        type=int,
        metavar="PORT",
        help="connect through an open `make db-tunnel` session on localhost:PORT (default: 5433)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("url", help="print the connection URL")
    p.add_argument("--hide-password", action="store_true", help="mask the password")
    p.set_defaults(func=cmd_url)

    sub.add_parser(
        "secret",
        help="print the RDS master secret with URL-safe fields",
    ).set_defaults(func=cmd_secret)

    p = sub.add_parser("env", help="print shell exports (PG* and URBAN_RAG_PG*)")
    p.add_argument("--app", action="store_true", help="the pipeline's role via Secrets Manager, not the master user")
    p.set_defaults(func=cmd_env)

    sub.add_parser("init", help="apply sql/*.sql (extensions + spatial schema)").set_defaults(func=cmd_init)

    p = sub.add_parser("bootstrap", help="apply sql/000_roles.sql and set the app role's password")
    p.add_argument("--app-user", default="urban_rag", help="role to set the password on (default: %(default)s)")
    p.add_argument("--app-password", help="password to set; generated when omitted")
    p.add_argument("--store-password", action="store_true", help="write it to the app secret instead of printing it")
    p.set_defaults(func=cmd_bootstrap)

    p = sub.add_parser("ca", help="download the RDS CA bundle for sslmode=verify-full")
    p.add_argument("-o", "--output", default=str(CA_BUNDLE), help="where to write it (default: %(default)s)")
    p.set_defaults(func=cmd_ca)
    sub.add_parser("check", help="extensions, tables and corpus status").set_defaults(func=cmd_check)
    sub.add_parser("shell", help="interactive SQL (psql if installed)").set_defaults(func=cmd_shell)

    p = sub.add_parser("query", help="run one statement")
    p.add_argument("sql", nargs="?", help="SQL to run")
    p.add_argument("-f", "--file", help="read SQL from a file instead")
    p.add_argument("--json", action="store_true", help="print rows as JSON")
    p.set_defaults(func=cmd_query)

    p = sub.add_parser("wait", help="block until the database accepts connections")
    p.add_argument("--timeout", type=int, default=900, help="seconds to wait (default: 900)")
    p.set_defaults(func=cmd_wait)

    sub.add_parser("start", help="start a stopped instance").set_defaults(func=cmd_start)
    sub.add_parser("stop", help="stop the instance").set_defaults(func=cmd_stop)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.tunnel:
        global _LOCAL_PORT
        _LOCAL_PORT = args.tunnel
    try:
        return args.func(args)
    except DbError as exc:
        print(f"{RED}error:{RESET} {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        # A driver error here is nearly always the network or the credentials,
        # not a bug in this script, and a traceback buries the one line that
        # says which.
        if type(exc).__module__.split(".")[0] not in {"psycopg", "psycopg2"}:
            raise
        print(f"{RED}error:{RESET} {_first_line(exc)}", file=sys.stderr)
        for hint in _hints(exc, args):
            print(f"  {DIM}{hint}{RESET}", file=sys.stderr)
        return 1


def _first_line(exc: Exception) -> str:
    return str(exc).strip().splitlines()[0] if str(exc).strip() else exc.__class__.__name__


def _hints(exc: Exception, args) -> list[str]:
    """The two or three things that actually cause each failure."""
    message = str(exc).lower()
    if "server does not support ssl" in message:
        return [
            "the server speaks no TLS — a local container, not RDS.",
            "add ?sslmode=disable to DATABASE_URL.",
        ]
    if "timeout" in message or "could not connect" in message or "no route" in message:
        return [
            f"the instance may have no public endpoint — open `make db-tunnel ENV={args.env}`",
            "  in another shell and re-run this with TUNNEL=1,",
            f"or the security group may not list your current IP — re-run `make apply ENV={args.env}`,",
            f"or the instance may be stopped — `make db-start ENV={args.env}`.",
        ]
    if "password authentication failed" in message:
        return ["the master password rotated — this script re-reads it each run, so retry once."]
    if "does not exist" in message and "database" in message:
        return ["the database name in the SSM contract does not match the instance."]
    return []


if __name__ == "__main__":
    sys.exit(main())
