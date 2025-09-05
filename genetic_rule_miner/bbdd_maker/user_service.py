import csv
import logging
import time
from io import BytesIO, StringIO
from typing import List, Optional

import requests

from genetic_rule_miner.config import APIConfig
from genetic_rule_miner.utils.logging import LogManager

LogManager.configure()
logger = logging.getLogger(__name__)


class UserService:
    """
    Service class for interacting with MyAnimeList users via the Jikan API.

    Attributes:
        config (APIConfig): Configuration for API requests, retries, and delays.
    """
    def __init__(self, config: APIConfig = APIConfig()):
        """
        Initialize the UserService with optional API configuration.

        Args:
            config (APIConfig, optional): Configuration object with timeout,
                retry count, and request delay. Defaults to APIConfig().
        """
        self.config = config
        logger.info(
            "UserService initialized with configuration: %s", self.config
        )

    def _request(self, endpoint: str) -> dict:
        """
        Perform a generic GET request with retries and error handling.

        Args:
            endpoint (str): API endpoint to query.

        Returns:
            dict: JSON response if successful, otherwise an empty dict.
        """
        url = f"https://api.jikan.moe/v4{endpoint}"
        for attempt in range(self.config.max_retries):
            try:
                logger.debug("Requesting %s (attempt %d)", url, attempt + 1)
                response = requests.get(url, timeout=self.config.timeout)
                if response.status_code == 200:
                    return response.json()
                elif response.status_code == 404:
                    logger.warning("Resource not found: %s", url)
                    return {}
                response.raise_for_status()
            except requests.RequestException as e:
                logger.warning(
                    "Error on attempt %d for %s: %s",
                    attempt + 1,
                    url,
                    str(e),
                )
                if attempt < self.config.max_retries - 1:
                    time.sleep(2**attempt)
        logger.error(
            "Failed to get resource: %s after %d attempts",
            url,
            self.config.max_retries,
        )
        return {}

    def _fetch_with_retry(self, user_id: int) -> Optional[dict]:
        """
        Fetch user data by ID with retry logic and error handling.

        Args:
            user_id (int): The MyAnimeList user ID to fetch.

        Returns:
            Optional[dict]: User data if successful, otherwise None.
        """
        logger.debug("Starting _fetch_with_retry for user_id: %d", user_id)
        for attempt in range(self.config.max_retries):
            try:
                logger.debug(
                    "Attempt %d for user_id: %d", attempt + 1, user_id
                )
                response = requests.get(
                    f"https://api.jikan.moe/v4/users/userbyid/{user_id}",
                    timeout=self.config.timeout,
                )

                if response.status_code == 200:
                    logger.info("User ID %d successfully found", user_id)
                    return response.json().get("data")
                elif response.status_code == 404:
                    logger.warning("User ID %d not found (404)", user_id)
                    return None

                response.raise_for_status()

            except requests.exceptions.RequestException as e:
                logger.error(
                    "Error on attempt %d for user_id %d: %s",
                    attempt + 1,
                    user_id,
                    str(e),
                )
                if attempt < self.config.max_retries - 1:
                    logger.debug("Waiting before the next attempt...")
                    time.sleep(2**attempt)  # Exponential backoff

        logger.error(
            "User ID %d unavailable after %d attempts",
            user_id,
            self.config.max_retries,
        )
        return None

    def generate_userlist(self, start_id: int, end_id: int) -> BytesIO:
        """
        Generate a CSV list of users by searching a range of IDs.

        Args:
            start_id (int): Starting user ID.
            end_id (int): Ending user ID.

        Returns:
            BytesIO: CSV data containing user_id, username, and user_url.
        """
        logger.info(
            "Starting user list generation for IDs %d to %d",
            start_id,
            end_id,
        )
        text_buffer = StringIO()
        writer = csv.DictWriter(
            text_buffer,
            fieldnames=["user_id", "username", "user_url"],
            extrasaction="ignore",
        )
        writer.writeheader()

        valid_users = 0
        total_processed = 0

        for user_id in range(start_id, end_id + 1):
            try:
                logger.debug("Processing user_id: %d", user_id)
                data = self._fetch_with_retry(user_id)
                user_record = {
                    "user_id": user_id,
                    "username": data.get("username") if data else None,
                    "user_url": data.get("url") if data else None,
                }

                if data:
                    writer.writerow(user_record)
                    valid_users += 1
                    logger.info("User ID %d added to the list", user_id)
                else:
                    logger.warning("User ID %d has no valid data", user_id)

                time.sleep(self.config.request_delay)

            except Exception as e:
                logger.error(
                    "Critical error processing ID %d: %s", user_id, str(e)
                )
            finally:
                total_processed += 1
                if total_processed % 100 == 0:
                    logger.info(
                        "Progress: %.1f%% (%d/%d)",
                        total_processed / (end_id - start_id + 1) * 100,
                        total_processed,
                        end_id - start_id + 1,
                    )

        # Convert to bytes before returning
        text_buffer.seek(0)
        byte_buffer = BytesIO(text_buffer.getvalue().encode("utf-8"))
        logger.info(
            "Generation completed. Valid users: %d/%d",
            valid_users,
            total_processed,
        )
        return byte_buffer

    def get_users(self, user_ids: List[int]) -> BytesIO:
        """
        Fetch multiple users and return as CSV.

        Args:
            user_ids (List[int]): List of MyAnimeList user IDs.

        Returns:
            BytesIO: CSV data containing user_id, username, and user_url.
        """
        logger.info("Starting user retrieval for IDs: %s", user_ids)
        text_buffer = StringIO()
        writer = csv.DictWriter(
            text_buffer, fieldnames=["user_id", "username", "user_url"]
        )
        writer.writeheader()

        for user_id in user_ids:
            logger.debug("Processing user_id: %d", user_id)
            data = self._fetch_with_retry(user_id)
            if data:
                record = {
                    "user_id": user_id,
                    "username": data.get("username"),
                    "user_url": data.get("url"),
                }
                writer.writerow(record)
                logger.info("User ID %d added to the file", user_id)
                time.sleep(self.config.request_delay)
            else:
                logger.warning("User ID %d has no valid data", user_id)

        text_buffer.seek(0)
        byte_buffer = BytesIO(text_buffer.getvalue().encode("utf-8"))
        logger.info("User retrieval completed")
        return byte_buffer

    def get_user_by_id(self, user_id: int) -> Optional[dict]:
        """
        Fetch a single user by ID.

        Args:
            user_id (int): The MyAnimeList user ID.

        Returns:
            Optional[dict]: User data if found, otherwise None.
        """
        return self._fetch_with_retry(user_id)

    def get_users_by_ids(self, user_ids: List[int]) -> list:
        """
        Fetch multiple users by their IDs.

        Args:
            user_ids (List[int]): List of user IDs.

        Returns:
            list: List of user data dictionaries (or None for missing users).
        """
        return [self._fetch_with_retry(uid) for uid in user_ids]

    def get_user_id_from_username(self, username: str) -> Optional[int]:
        """
        Fetch the MyAnimeList user ID for a given username.

        Args:
            username (str): The MyAnimeList username.

        Returns:
            Optional[int]: User ID if found, otherwise None.
        """
        try:
            response = requests.get(
                f"https://api.jikan.moe/v4/users/{username}", timeout=10
            )
            if response.status_code == 200:
                return response.json()["data"]["mal_id"]
            else:
                logger.warning(
                    "No se pudo obtener el ID para el usuario %s", username
                )
        except Exception as e:
            logger.error("Error obteniendo el ID de %s: %s", username, str(e))
        return None

    def get_user_id_by_username(self, username: str) -> Optional[int]:
        """
        Fetch the MyAnimeList user ID by username (alias method).

        Args:
            username (str): The MyAnimeList username.

        Returns:
            Optional[int]: User ID if found, otherwise None.
        """
        try:
            response = requests.get(
                f"https://api.jikan.moe/v4/users/{username}", timeout=10
            )
            if response.status_code == 200:
                return response.json()["data"]["mal_id"]
            else:
                logger.warning("No se pudo obtener el usuario %s", username)
        except Exception as e:
            logger.error(
                "Error obteniendo el usuario %s: %s", username, str(e)
            )
        return None

    def get_user_favorites(self, username: str) -> dict:
        """
        Fetch a user's favorites.

        Args:
            username (str): The MyAnimeList username.

        Returns:
            dict: JSON response containing favorites.
        """
        return self._request(f"/users/{username}/favorites")

    def get_user_updates(self, username: str) -> dict:
        """
        Fetch a user's updates.

        Args:
            username (str): The MyAnimeList username.

        Returns:
            dict: JSON response containing user updates.
        """
        return self._request(f"/users/{username}/userupdates")

    def get_user_history(self, username: str, type: str = "anime") -> dict:
        """
        Fetch a user's history for a specific type.

        Args:
            username (str): The MyAnimeList username.
            type (str, optional): 'anime' or 'manga'. Defaults to 'anime'.

        Returns:
            dict: JSON response containing user history.
        """
        return self._request(f"/users/{username}/history?type={type}")

    def get_user_reviews(self, username: str) -> dict:
        """
        Fetch a user's reviews.

        Args:
            username (str): The MyAnimeList username.

        Returns:
            dict: JSON response containing user reviews.
        """

        return self._request(f"/users/{username}/reviews")
