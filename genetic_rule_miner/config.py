# config.py
import os
from dataclasses import dataclass


@dataclass
class APIConfig:
     """
    Configuration parameters for external API services.

    Attributes:
        base_url (str): Base URL of the API.
        max_retries (int): Maximum number of retry attempts for failed requests.
        timeout (float): Timeout in seconds for API requests.
        request_delay (float): Delay between consecutive requests in seconds.
        rate_limit (int): Maximum number of requests allowed per unit time.
    """
    """Configuration for external API services"""

    base_url: str = "https://api.jikan.moe/v4/"
    max_retries: int = 3
    timeout: float = 10.0
    request_delay: float = 0.35
    rate_limit: int = 3

    def __post_init__(self) -> None:
        """Validate configuration values to ensure time settings are non-negative."""
        """Validate configuration values."""
        if any(val < 0 for val in (self.timeout, self.request_delay)):
            raise ValueError("Negative values not allowed for time settings")


@dataclass
class DBConfig:
     """
    Configuration parameters for database connections.

    Attributes:
        host (str): Database host address.
        port (int): Database port number.
        database (str): Name of the database.
        user (str): Database username.
        password (str): Database password.
    """
    """Configuration for database connections"""

    host: str = os.getenv("DB_HOST", "postgres")
    port: int = int(os.getenv("DB_PORT", 5432))
    database: str = os.getenv("DB_NAME", "mydatabase")
    user: str = os.getenv("DB_USER", "postgres")
    password: str = os.getenv("DB_PASS", "postgres")

    def __post_init__(self) -> None:
         """Validate that the port number is within the valid TCP range."""
        """Validate database configuration."""
        if self.port <= 0 or self.port > 65535:
            raise ValueError("Invalid port number")
