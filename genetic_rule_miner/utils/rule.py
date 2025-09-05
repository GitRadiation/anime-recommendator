from typing import TypedDict

import numpy as np


class Condition(TypedDict):
    """
    Represents an atomic condition in a rule.

    Attributes:
        column (str): Name of the column the condition applies to.
        operator (str): Comparison operator (e.g., '==', '>', '<=', 'in').
        value (str | int | float): Value to compare in the condition.
    """
    column: str
    operator: str
    value: str | int | float


class Rule:
    """
    Represents a classification rule based on conditions on columns.

    A rule contains conditions applied to user data and other data,
    and a target value (`target`) that is predicted when the conditions are met.

    Attributes:
        columns (list[str]): List of input column names (for compatibility only).
        conditions (tuple[list[tuple], list[tuple]]): Tuple of conditions:
            - user_conditions: list of tuples (column, (operator, value))
            - other_conditions: list of tuples (column, (operator, value))
        target (np.int64): Target value that the rule predicts.
    """
    """
    Represents a rule for classification based on conditions on columns.
    - columns: list of input column names (excluding target)
    - conditions: dict with keys "user_conditions" and "other_conditions", each a list of tuples (col, (op, value))
        or a list of Condition (TypedDict) for compatibility.
    - target: target value that the rule predicts
    """
    def __init__(
        self,
        columns: list[str],
        conditions: dict,
        target: np.int64,
    ):
        # columns is now just for compatibility, not used for logic
        self.columns = list(columns)

        def parse_conds(cond_list):
            parsed = []
            for cond in cond_list:
                if isinstance(cond, dict):
                    # Assume Condition TypedDict
                    parsed.append(
                        (cond["column"], (cond["operator"], cond["value"]))
                    )
                elif isinstance(cond, tuple) and isinstance(cond[1], tuple):
                    parsed.append(cond)
                else:
                    raise TypeError(f"Condición en formato inesperado: {cond}")
            return parsed

        user_conditions = parse_conds(conditions.get("user_conditions", []))
        other_conditions = parse_conds(conditions.get("other_conditions", []))
        self.conditions = (user_conditions, other_conditions)
        self.target = target

    def __repr__(self):
        user_conds = [
            f"{col} {op} {val!r}" for col, (op, val) in self.conditions[0]
        ]
        other_conds = [
            f"{col} {op} {val!r}" for col, (op, val) in self.conditions[1]
        ]
        conds = user_conds + other_conds
        return f"IF {' AND '.join(conds)} THEN target = {self.target!r}"

    def __len__(self):
        """
        Devuelve el número de condiciones en la regla.
        """
        return len(self.conditions[0]) + len(self.conditions[1])

    def _cond_key_set(self, conds):
        """
        Devuelve un frozenset de (columna, operador) para un bloque de condiciones.
        """
        return frozenset((col, op) for col, (op, _) in conds)

    @classmethod
    def from_dict(cls, data: dict) -> "Rule":
        """
        Construye una regla a partir de un diccionario.

        Args:
            data (dict): Diccionario con claves 'columns', 'conditions' y 'target'.

        Returns:
            Rule: Instancia de la regla.
        """
        return cls(
            columns=data.get("columns", []),
            conditions=data.get("conditions", {}),
            target=data["target"],
        )

    def cond_signature(self):
        """
        Devuelve la firma de la regla como frozensets de condiciones y target.

        Returns:
            tuple: (user_conditions_frozenset, other_conditions_frozenset, target)
        """
        """
        Devuelve la firma de la regla como dos frozensets: uno para user_conditions y otro para other_conditions.
        """
        return (
            self._cond_key_set(self.conditions[0]),
            self._cond_key_set(self.conditions[1]),
            self.target,
        )

    def __eq__(self, other):
        """Define igualdad basada en condiciones y target."""
        if not isinstance(other, Rule):
            return False
        # Igualdad: mismos pares (col, op) en ambos bloques y mismo target
        return self.cond_signature() == other.cond_signature()

    def __hash__(self):
        """Hash basado en la firma de condiciones y target."""
        return hash(self.cond_signature())

    def is_subset_of(self, other: "Rule") -> bool:
        """
        Devuelve True si esta regla es subconjunto de otra.

        Una regla es subconjunto si todas sus condiciones están contenidas en la otra
        y apuntan al mismo target.

        Args:
            other (Rule): Regla a comparar.

        Returns:
            bool: True si es subconjunto, False en caso contrario.
        """
        
        if self.target != other.target:
            return False
        user_self, other_self, _ = self.cond_signature()
        user_other, other_other, _ = other.cond_signature()
        return user_self.issubset(user_other) and other_self.issubset(
            other_other
        )

    def is_more_specific_than(self, other: "Rule") -> bool:
        """
        Devuelve True si esta regla es más específica que otra.

        Una regla es más específica si es subconjunto de otra y tiene más condiciones.

        Args:
            other (Rule): Regla a comparar.

        Returns:
            bool: True si es más específica, False en caso contrario.
        """
        
        if not self.is_subset_of(other):
            return False
        # Más específica si tiene más condiciones totales
        return len(self.conditions[0]) + len(self.conditions[1]) > len(
            other.conditions[0]
        ) + len(other.conditions[1])
