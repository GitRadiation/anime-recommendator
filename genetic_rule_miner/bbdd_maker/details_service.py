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


class DetailsService:
    def __init__(self, config: APIConfig = APIConfig()):
        self.config = config
        """
        Initialize the DetailsService with default configuration.

        Args:
            config (APIConfig, optional): API configuration. Defaults to APIConfig().
        """
        # Parameter optimization
        self.batch_size = 3
        self.request_delay = 0.35
        self.batch_delay = 1.0
        self.max_retries = 3

        logger.info("DetailsService initialized with default configuration.")

    def get_user_details(self, usernames: List[str]) -> BytesIO:
        """
        Generate a CSV file with detailed user data.

        This method fetches details for multiple users, processes them in batches,
        applies rate limiting, and writes the results into a CSV buffer.

        Args:
            usernames (List[str]): List of MyAnimeList usernames.

        Returns:
            BytesIO: A buffer containing the CSV data.
        """
        logger.info(f"Starting processing for {len(usernames)} users.")
        buffer = StringIO()
        writer = csv.writer(buffer)
        writer.writerow(
            [
                "Mal ID",
                "Username",
                "Gender",
                "Birthday",
                "Location",
                "Joined",
                "Days Watched",
                "Mean Score",
                "Watching",
                "Completed",
                "On Hold",
                "Dropped",
                "Plan to Watch",
                "Total Entries",
                "Rewatched",
                "Episodes Watched",
            ]
        )

        total = len(usernames)
        start_time = time.time()

        for i in range(0, total, self.batch_size):
            batch = usernames[i : i + self.batch_size]
            logger.debug(
                f"Processing batch {i // self.batch_size + 1}: {batch}"
            )
            batch_data = []

            for username in batch:
                if data := self._fetch_user_data(username):
                    writer.writerow(data)
                    batch_data.append(data)
                else:
                    logger.warning(f"No data found for user: {username}")

            logger.info(f"Processed {min(i+self.batch_size, total)}/{total}")
            self._handle_rate_limits(len(batch_data))

        logger.info(f"Total processing time: {time.time()-start_time:.2f}s")
        buffer.seek(0)
        return BytesIO(buffer.getvalue().encode("utf-8"))

    def _fetch_user_data(self, username: str) -> Optional[list]:
        """
        Fetch user details from the API with retry logic.

        Args:
            username (str): The MyAnimeList username.

        Returns:
            Optional[list]: A list of user attributes (if found),
                or None if the user does not exist or all retries fail.
        """
        logger.debug(f"Requesting data for user: {username}")
        for attempt in range(self.max_retries):
            try:
                response = requests.get(
                    f"https://api.jikan.moe/v4/users/{username}/full",
                    timeout=self.config.timeout,
                )

                if response.status_code == 200:
                    logger.debug(
                        f"Successfully retrieved data for {username}."
                    )
                    return self._parse_response(response.json())

                if response.status_code == 404:
                    logger.info(
                        f"User not found: {username}. Skipping further attempts."
                    )
                    return None

                logger.warning(
                    f"Attempt {attempt+1} failed for {username} (HTTP {response.status_code})."
                )
                time.sleep(2**attempt)

            except Exception as e:
                logger.error(
                    f"Error on attempt {attempt+1} for {username}: {str(e)}"
                )
                time.sleep(2**attempt)

        logger.error(f"All attempts to fetch data for {username} failed.")
        return None

    def _parse_response(self, response: dict) -> list:
        """
        Parse the API response into a structured list.

        Args:
            response (dict): Raw JSON response from the API.

        Returns:
            list: Extracted fields including user profile details and anime stats.
        """        
        logger.debug("Parsing API response.")
        data = response.get("data", {})
        stats = data.get("statistics", {}).get("anime", {})

        return [
            data.get("mal_id"),
            data.get("username"),
            data.get("gender"),
            data.get("birthday"),
            data.get("location"),
            data.get("joined"),
            stats.get("days_watched"),
            stats.get("mean_score"),
            stats.get("watching"),
            stats.get("completed"),
            stats.get("on_hold"),
            stats.get("dropped"),
            stats.get("plan_to_watch"),
            stats.get("total_entries"),
            stats.get("rewatched"),
            stats.get("episodes_watched"),
        ]

    def _handle_rate_limits(self, batch_size: int):
        """
        Apply delays to respect API rate limits.

        Args:
            batch_size (int): Number of successfully processed users in the batch.
        """
        if batch_size > 0:
            logger.debug(
                f"Applying a delay of {self.batch_delay}s to respect API rate limits."
            )
            time.sleep(self.batch_delay)

    def get_user_detail(self, username: str) -> Optional[list]:
        """
        Get details for a single user.

        Args:
            username (str): The MyAnimeList username.

        Returns:
            Optional[list]: A list of user details, or None if the user is not found.
        """
        return self._fetch_user_data(username)

    def get_users_details(self, usernames: List[str]) -> list:
        """
        Get details for multiple users.

        Args:
            usernames (List[str]): List of MyAnimeList usernames.

        Returns:
            list: A list of user detail lists. Missing users will appear as None.
        """  
        return [self._fetch_user_data(u) for u in usernames]
