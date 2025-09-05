import ast
import csv
import uuid
from collections import namedtuple
from contextlib import contextmanager
from io import BytesIO, StringIO
from typing import Generator, Optional

import numpy as np
from sqlalchemy import Connection, bindparam, create_engine, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.engine import Engine
from sqlalchemy.exc import IntegrityError

from genetic_rule_miner.config import DBConfig
from genetic_rule_miner.utils.exceptions import DatabaseError
from genetic_rule_miner.utils.logging import LogManager
from genetic_rule_miner.utils.rule import Rule

logger = LogManager.get_logger(__name__)


RuleWithID = namedtuple("RuleWithID", ["rule_id", "rule_obj"])


class DatabaseManager:
    """
    Singleton class for managing PostgreSQL database operations.

    Attributes:
        config (DBConfig): Database configuration settings.
        _engine (Engine, optional): SQLAlchemy engine instance.
    """
    _instance = None

    _engine: Optional[Engine] = None

    def __new__(
        cls, config: Optional[DBConfig] = DBConfig()
    ) -> "DatabaseManager":
        """
        Implement singleton pattern.

        Args:
            config (DBConfig, optional): Configuration for database connection.

        Returns:
            DatabaseManager: Single instance of the class.
        """
        if cls._instance is None:
            cls._instance = super(DatabaseManager, cls).__new__(cls)
            cls._instance._initialized = False
        return cls._instance

    def __init__(self, config: Optional[DBConfig] = DBConfig()) -> None:
        """
        Initialize the database manager.

        Args:
            config (DBConfig, optional): Configuration for database connection.
        """
        if self._initialized:
            return
        self.config = config
        self._engine = None
        self._session_factory = None
        self.initialize()
        self._initialized = True

    def __del__(self) -> None:
        if self._engine:
            logger.info("SQLAlchemy engine closed")

    @contextmanager
    def connection(self) -> Generator[Connection, None, None]:
        """
        Context manager for database connections.

        Yields:
            Connection: SQLAlchemy database connection.

        Raises:
            DatabaseError: If the engine is not initialized or connection fails.
        """
        connection = None
        try:
            if self._engine:
                connection = self._engine.connect()
                yield connection
                connection.commit()  # Commit to persist changes
            else:
                raise DatabaseError("Database engine not initialized")
        except Exception as e:
            logger.error("Database connection error", exc_info=True)
            raise DatabaseError("Connection failed") from e
        finally:
            if connection:
                connection.close()

    def initialize(self) -> None:
        self._init_sqlalchemy_engine()

    def _init_sqlalchemy_engine(self) -> None:
        """Set up the SQLAlchemy engine based on DBConfig."""

        try:
            if (
                self.config
                and self.config.password
                and self.config.user
                and self.config.host
                and self.config.port
                and self.config.database
            ):
                conn_str = (
                    f"postgresql+psycopg2://{self.config.user}:{self.config.password}"
                    f"@{self.config.host}:{self.config.port}/{self.config.database}"
                )
                self._engine = create_engine(conn_str)
                logger.info("SQLAlchemy engine initialized")
            else:
                logger.error("Config is empty")
        except Exception as e:
            logger.critical(
                "Failed to initialize SQLAlchemy engine", exc_info=True
            )
            raise DatabaseError(
                "SQLAlchemy engine initialization failed"
            ) from e

    def _construct_sql(
        self,
        table,
        columns,
        conflict_columns,
        conflict_action,
        update_clause=None,
    ) -> str:
        """
        Construct SQL insert statement with optional conflict handling.

        Args:
            table (str): Table name.
            columns (list[str]): Column names.
            conflict_columns (list[str]): Columns to check for conflict.
            conflict_action (str): Action to take on conflict ("DO UPDATE", "DO NOTHING").
            update_clause (str, optional): Custom update clause for conflicts.

        Returns:
            str: SQL statement.
        """
        placeholders = ", ".join([f":{col}" for col in columns])

        if conflict_columns:
            conflict_str = f"ON CONFLICT ({', '.join(conflict_columns)})"
            if conflict_action == "DO UPDATE":
                update_clause = update_clause or ", ".join(
                    [
                        f"{col} = EXCLUDED.{col}"
                        for col in columns
                        if col not in conflict_columns
                    ]
                )
                sql = f"""
                    INSERT INTO {table} ({', '.join(columns)})
                    VALUES ({placeholders})
                    {conflict_str} DO UPDATE SET {update_clause}
                """
            else:
                sql = f"""
                    INSERT INTO {table} ({', '.join(columns)})
                    VALUES ({placeholders})
                    {conflict_str} {conflict_action}
                """
        else:
            sql = f"""
                INSERT INTO {table} ({', '.join(columns)})
                VALUES ({placeholders})
            """
        return sql

    def copy_from_buffer(
        self,
        conn: Connection,
        buffer: StringIO,
        table: str,
        conflict_action="DO UPDATE",
    ) -> bool:
        """
        Bulk insert data from a CSV buffer into a PostgreSQL table.

        Args:
            conn (Connection): Active database connection.
            buffer (StringIO): CSV data buffer.
            table (str): Target table name.
            conflict_action (str): Conflict handling strategy.

        Returns:
            bool: True if data loaded, False otherwise.
        """
        def to_pg_array(arr):
            def escape_element(el):
                el = str(el).replace("\\", "\\\\").replace('"', '\\"')
                if any(c in el for c in [",", " ", "{", "}", '"']):
                    return f'"{el}"'
                return el

            return "{" + ",".join(escape_element(e) for e in arr) + "}"

        buffer.seek(0)
        reader = csv.DictReader(buffer)
        columns = reader.fieldnames
        table_conflict_columns = self._get_conflict_columns(table)

        array_columns = [
            "genres",
            "keywords",
            "producers",
        ]

        rows_to_insert = []
        for row in reader:
            cleaned_row = {
                key: None if value == "\\N" else value
                for key, value in row.items()
            }
            for col in array_columns:
                if col in cleaned_row and cleaned_row[col]:
                    try:
                        value = cleaned_row[col]
                        if isinstance(value, str):
                            lst = ast.literal_eval(value)
                            if isinstance(lst, list):
                                cleaned_row[col] = to_pg_array(lst)
                    except Exception:
                        pass
            rows_to_insert.append(cleaned_row)

        if not rows_to_insert:
            logger.info("No data loaded (empty or all rows skipped)")
            return False

        sql = self._construct_sql(
            table, columns, table_conflict_columns, conflict_action
        )
        try:
            conn.execute(text(sql), rows_to_insert)
            conn.commit()
            logger.info("✅ Data loading completed successfully")
            return True
        except IntegrityError as e:
            logger.error(f"Database error: {e}")
            raise

    def _get_conflict_columns(self, table: str) -> list:
        """
        Get columns to check for conflict based on table name.

        Args:
            table (str): Table name.

        Returns:
            list: List of conflict columns.
        """
        if table == "user_score":
            return ["user_id", "anime_id"]
        elif table == "anime_dataset":
            return ["anime_id"]
        elif table == "user_details":
            return ["mal_id"]
        else:
            return []

    def export_users_to_csv_buffer(
        self, table: str = "user_details"
    ) -> BytesIO:
        """
        Export user details to a CSV buffer.

        Args:
            table (str): Source table name.

        Returns:
            BytesIO: CSV buffer containing mal_id, username, and user_url.
        """
        columns = ["mal_id", "username"]
        query = f"SELECT {', '.join(columns)} FROM {table}"

        buffer = StringIO()
        writer = csv.writer(buffer)
        writer.writerow(["mal_id", "username", "user_url"])

        with self.connection() as conn:
            result = conn.execute(text(query))
            for row in result.mappings():
                mal_id = row.get("mal_id")
                username = row.get("username")

                user_url = f"https://myanimelist.net/profile/{username}"
                writer.writerow([mal_id, username, user_url])

        buffer.seek(0)
        return BytesIO(buffer.getvalue().encode("utf-8"))

    def get_anime_ids_without_rules(self) -> Optional[list[int]]:

        # Nueva consulta: reglas cuyo target_value tenga <= 250 reglas
        query_rules_targets = """
            SELECT r.rule_id, r.target_value
            FROM rules r
            JOIN (
                SELECT target_value
                FROM rules
                GROUP BY target_value
                HAVING COUNT(*) <= 250
            ) AS t ON r.target_value = t.target_value;
        """
        with self.connection() as conn:
            # IDs de target_value en rules
            result = conn.execute(text(query_rules_targets))
            # Usar set comprehension directamente para eliminar duplicados
            rule_targets = {row["target_value"] for row in result.mappings()}

            # Retornar lista vacía si no hay elementos
            return list(rule_targets)


    def save_rules(self, rules: list[Rule], table: str = "rules") -> None:
        """
        Save Rule objects to the PostgreSQL database using normalized structure.
        """
        with self.connection() as conn:
            try:
                # Preparar datos para insertar en la tabla rules
                rules_data = []
                conditions_data = []

                for rule in rules:
                    rule_id = str(uuid.uuid4())

                    # Datos para la tabla rules
                    rules_data.append(
                        {
                            "rule_id": rule_id,
                            "target_value": (
                                int(rule.target.item())
                                if hasattr(rule.target, "item")
                                else int(rule.target)
                            ),
                        }
                    )

                    # Procesar user_conditions
                    for col, (op, value) in rule.conditions[0]:
                        condition_data = {
                            "condition_id": str(uuid.uuid4()),
                            "rule_id": rule_id,
                            "table_name": "user_details",
                            "column_name": col,
                            "operator": op,
                            "value_text": None,
                            "value_numeric": None,
                        }

                        # Determinar el tipo de valor y asignarlo correctamente
                        if isinstance(value, (int, float)):
                            condition_data["value_numeric"] = value
                        else:
                            condition_data["value_text"] = str(value)

                        conditions_data.append(condition_data)

                    # Procesar other_conditions (anime_dataset)
                    for col, (op, value) in rule.conditions[1]:
                        condition_data = {
                            "condition_id": str(uuid.uuid4()),
                            "rule_id": rule_id,
                            "table_name": "anime_dataset",
                            "column_name": col,
                            "operator": op,
                            "value_text": None,
                            "value_numeric": None,
                        }

                        # Determinar el tipo de valor y asignarlo correctamente
                        if isinstance(value, (int, float)):
                            condition_data["value_numeric"] = value
                        else:
                            condition_data["value_text"] = str(value)

                        conditions_data.append(condition_data)

                # Insertar reglas
                if rules_data:
                    conn.execute(
                        text(
                            f"""
                            INSERT INTO {table} (rule_id, target_value)
                            VALUES (:rule_id, :target_value)
                        """
                        ),
                        rules_data,
                    )

                # Insertar condiciones
                if conditions_data:
                    conn.execute(
                        text(
                            """
                            INSERT INTO rule_conditions 
                            (condition_id, rule_id, table_name, column_name, operator, 
                            value_text, value_numeric)
                            VALUES (:condition_id, :rule_id, :table_name, :column_name, 
                                    :operator, :value_text, :value_numeric)
                        """
                        ),
                        conditions_data,
                    )

                conn.commit()
                logger.info(
                    f"Guardadas {len(rules)} reglas con {len(conditions_data)} condiciones"
                )

            except Exception as e:
                conn.rollback()
                logger.error(f"Error guardando reglas: {e}")
                raise

    def get_rules_by_target_value_paginated(
        self, target_value: int, offset: int = 0, limit: int = 500
    ) -> list[RuleWithID]:
        """
        Devuelve todas las reglas asociadas a un target_value específico,
        en forma de lista de namedtuples con rule_id y objeto Rule.
        """
        with self.connection() as conn:
            try:
                result = (
                    conn.execute(
                        text(
                            """
                            SELECT 
                                r.rule_id, 
                                r.target_value,
                                rc.table_name,
                                rc.column_name,
                                rc.operator,
                                rc.value_text,
                                rc.value_numeric
                            FROM rules r
                            LEFT JOIN rule_conditions rc ON r.rule_id = rc.rule_id
                            WHERE r.target_value = :target_value
                            ORDER BY r.rule_id, rc.condition_id
                            OFFSET :offset LIMIT :limit
                        """
                        ),
                        {
                            "target_value": target_value,
                            "offset": offset,
                            "limit": limit,
                        },
                    )
                    .mappings()
                    .all()
                )

                # Agrupar condiciones por regla
                rules_dict = {}
                for row in result:
                    rule_id = row["rule_id"]

                    if rule_id not in rules_dict:
                        rules_dict[rule_id] = {
                            "target_value": row["target_value"],
                            "user_conditions": [],
                            "other_conditions": [],
                        }

                    # Si hay condiciones (LEFT JOIN puede devolver None)
                    if row["column_name"]:
                        # Determinar el valor según el tipo
                        if row["value_numeric"] is not None:
                            value = row["value_numeric"]
                        else:
                            value = row["value_text"]

                        condition = (
                            row["column_name"],
                            (row["operator"], value),
                        )

                        # Clasificar la condición según la tabla
                        if row["table_name"] == "user_details":
                            rules_dict[rule_id]["user_conditions"].append(
                                condition
                            )
                        else:  # anime_dataset
                            rules_dict[rule_id]["other_conditions"].append(
                                condition
                            )

                # Convertir a objetos RuleWithID
                rules_with_id = []
                for rule_id, rule_data in rules_dict.items():
                    try:
                        conditions = {
                            "user_conditions": rule_data["user_conditions"],
                            "other_conditions": rule_data["other_conditions"],
                        }
                        rule = Rule(
                            columns=[],  # No se usa en la nueva implementación
                            conditions=conditions,
                            target=np.int64(rule_data["target_value"]),
                        )
                        rules_with_id.append(
                            RuleWithID(rule_id=rule_id, rule_obj=rule)
                        )

                    except Exception as e:
                        logger.warning(
                            f"No se pudo construir Rule para target {target_value}: {e}"
                        )

                return rules_with_id

            except Exception as e:
                logger.error(
                    f"Error obteniendo reglas para target {target_value}: {e}"
                )
                return []

    def get_rules_series_by_json(self, json_objeto: dict):
        """
        Executes the SQL function get_rules_series by passing the full JSON obtained from the API.

        :param json_object: Complete dictionary of the JSON received from the API.
        :return: List of dictionaries with the results.
        """


        def clean_nans(obj):
            if isinstance(obj, dict):
                return {k: clean_nans(v) for k, v in obj.items()}
            elif isinstance(obj, list):
                return [clean_nans(elem) for elem in obj]
            elif isinstance(obj, float) and np.isnan(obj):
                return None
            return obj

        cleaned_data = clean_nans(json_objeto)
        with self.connection() as conn:
            result = conn.execute(
                text("SELECT * FROM get_rules_series(:input_json)").bindparams(
                    bindparam("input_json", type_=JSONB)
                ),
                {"input_json": cleaned_data},
            ).fetchall()

            if not result:
                return []

            columns = (
                result[0]._fields
                if hasattr(result[0], "_fields")
                else ["id", "nombre", "cantidad"]
            )
            return [dict(zip(columns, row)) for row in result]
