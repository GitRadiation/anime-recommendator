import csv
import json
import logging
import random
import time
from io import BytesIO, StringIO
from typing import List, Optional

import pandas as pd
import requests
from bs4 import BeautifulSoup

from genetic_rule_miner.config import APIConfig
from genetic_rule_miner.utils.logging import LogManager

LogManager.configure()
logger = logging.getLogger(__name__)


class ScoreService:
    """
    Service class for scraping and processing MyAnimeList user scores.

    Attributes:
        config (APIConfig): Configuration for requests, retries, and delays.
        status_code (int): MAL status code to filter completed anime.
        batch_size (int): Number of users to process per batch.
        min_delay (int): Minimum delay between batches (seconds).
        max_delay (int): Maximum delay between batches (seconds).
    """

    def __init__(self, config: APIConfig = APIConfig()):
        """
        Initialize the ScoreService with default or custom configuration.

        Args:
            config (APIConfig, optional): Configuration object for retries,
                timeout, and request delays. Defaults to APIConfig().
        """
        self.config = config

        # Scraping configuration
        self.status_code = 7  # Completed anime
        self.batch_size = 50
        self.min_delay = 90
        self.max_delay = 120
        logger.info("ScoreService initialized with default configuration.")

    def _process_batch(self, users_batch: List[dict]) -> List[list]:
        """
        Process a batch of users and retrieve their scores.

        Args:
            users_batch (List[dict]): List of user dictionaries with 'username' and 'mal_id'.

        Returns:
            List[list]: List of score records for the batch.
        """
        logger.info(f"Processing batch of {len(users_batch)} users.")
        batch_data = []
        for user in users_batch:
            try:
                if data := self._scrape_user_scores(
                    user["username"], user["mal_id"]
                ):
                    batch_data.extend(data)
                    logger.info(f"Data retrieved for {user['username']}.")
                else:
                    logger.warning(f"No data for {user['username']}.")
            except Exception as e:
                logger.error(f"Error processing {user['username']}: {str(e)}")
        logger.info(
            f"Batch processed with {len(batch_data)} records retrieved."
        )
        return batch_data

    def _scrape_user_scores(
        self, username: str, user_id: int
    ) -> Optional[List[list]]:
        """
        Scrape scores for a user with retry logic and support for modern and legacy tables.

        Args:
            username (str): MyAnimeList username.
            user_id (int): MyAnimeList user ID.

        Returns:
            Optional[List[list]]: List of [user_id, username, anime_id, anime_title, score] records.
        """
        logger.debug(f"Starting scraping for user: {username}.")
        for attempt in range(self.config.max_retries):
            try:
                url = f"https://myanimelist.net/animelist/{username}?status={self.status_code}"
                response = requests.get(url, timeout=self.config.timeout)

                if response.status_code == 200:
                    logger.debug(
                        f"Successfully retrieved HTML for {username}."
                    )
                    soup = BeautifulSoup(response.content, "html.parser")
                    return self._parse_modern_table(
                        soup, user_id, username
                    ) or self._parse_legacy_tables(soup, user_id, username)

                if response.status_code == 404:
                    logger.info(
                        f"User not found: {username}. Skipping further attempts."
                    )
                    return None

                if response.status_code == 429:
                    logger.warning(
                        f"Rate limit exceeded for {username}. Retrying..."
                    )
                else:
                    return None
                time.sleep(2**attempt)

            except Exception as e:
                logger.error(
                    f"Error on attempt {attempt+1} for {username}: {str(e)}"
                )
                time.sleep(2**attempt)

        logger.error(f"All attempts to scrape data for {username} failed.")
        return None

    def _parse_modern_table(self, soup, user_id, username):
        """
        Parse modern MyAnimeList table with 'data-items'.

        Args:
            soup (BeautifulSoup): Parsed HTML of the user's animelist.
            user_id (int): MyAnimeList user ID.
            username (str): MyAnimeList username.

        Returns:
            Optional[List[list]]: Parsed score records or None.
        """
        logger.debug(f"Attempting to parse modern table for {username}.")
        if table := soup.find("table", {"data-items": True}):
            try:
                data = [
                    [
                        user_id,
                        username,
                        item["anime_id"],
                        item["anime_title"],
                        item["score"],
                    ]
                    for item in json.loads(table["data-items"])
                    if item["score"] > 0
                ]
                logger.debug(f"Modern table parsed with {len(data)} records.")
                return data
            except json.JSONDecodeError:
                logger.warning(
                    f"JSON decoding error in modern table for {username}."
                )
        return None

    def _parse_legacy_tables(self, soup, user_id, username):
        """
        Parse legacy MyAnimeList tables (traditional HTML structure).

        Args:
            soup (BeautifulSoup): Parsed HTML of the user's animelist.
            user_id (int): MyAnimeList user ID.
            username (str): MyAnimeList username.

        Returns:
            Optional[List[list]]: Parsed score records or None.
        """
        logger.debug(f"Attempting to parse legacy tables for {username}.")
        scores = []
        for table in soup.find_all(
            "table",
            {
                "border": "0",
                "cellpadding": "0",
                "cellspacing": "0",
                "width": "100%",
            },
        ):
            for row in table.find_all("tr"):
                cells = row.find_all("td")
                if len(cells) >= 5:
                    anime_data = self._extract_anime_data(cells[1])
                    score_data = self._extract_score_data(cells[2])
                    if anime_data and score_data:
                        scores.append(
                            [
                                user_id,
                                username,
                                anime_data[0],
                                anime_data[1],
                                score_data,
                            ]
                        )
        logger.debug(f"Legacy tables parsed with {len(scores)} records.")
        return scores if scores else None

    def _extract_anime_data(self, cell):
        """
        Extract anime ID and title from a table cell.

        Args:
            cell (bs4.element.Tag): Table cell containing anime information.

        Returns:
            Optional[tuple]: (anime_id, anime_title) or None.
        """
        if link := cell.find("a", class_="animetitle"):
            return (link["href"].split("/")[2], link.find("span").text.strip())
        return None

    def _extract_score_data(self, cell):
        """
        Extract the score from a table cell.

        Args:
            cell (bs4.element.Tag): Table cell containing the score.

        Returns:
            Optional[int]: Score value or None if unavailable.
        """
        if score_label := cell.find("span", class_="score-label"):
            return (
                int(score_label.text.strip())
                if score_label.text.strip() != "-"
                else None
            )
        return None

    def get_scores(self, users_buffer: BytesIO) -> BytesIO:
        """
        Generate a CSV file of user scores by processing batches.

        Args:
            users_buffer (BytesIO): CSV buffer containing users with 'username' and 'mal_id'.

        Returns:
            BytesIO: CSV data with columns: User ID, Username, Anime ID, Anime Title, Score.
        """
        logger.info("Starting user processing to generate CSV.")
        users_df = pd.read_csv(users_buffer)
        buffer = StringIO()
        writer = csv.writer(buffer)
        writer.writerow(
            ["User ID", "Username", "Anime ID", "Anime Title", "Score"]
        )

        total_users = len(users_df)
        logger.info(f"Total users to process: {total_users}.")
        processed = 0

        for i in range(0, total_users, self.batch_size):
            batch = users_df.iloc[i : i + self.batch_size].to_dict("records")
            logger.info(f"Processing batch {i // self.batch_size + 1}.")
            batch_data = self._process_batch(batch)

            if batch_data:
                writer.writerows(batch_data)
                processed += len(batch)
                logger.info(
                    f"Processed: {processed}/{total_users} ({processed/total_users:.1%})."
                )

            if i + self.batch_size < total_users:
                delay = random.randint(self.min_delay, self.max_delay)
                logger.info(f"Waiting {delay}s for the next batch...")
                time.sleep(delay)

        logger.info("Processing complete. Generating CSV file.")
        buffer.seek(0)
        return BytesIO(buffer.getvalue().encode("utf-8"))

    def get_user_anime_score(
        self, username: str, user_id: int, anime_id: int
    ) -> Optional[int]:
        """
        Retrieve the score a user gave to a specific anime.

        Args:
            username (str): MyAnimeList username.
            user_id (int): MyAnimeList user ID.
            anime_id (int): Anime ID.

        Returns:
            Optional[int]: Score if found, otherwise None.
        """
        scores = self._scrape_user_scores(username, user_id)
        if scores:
            for row in scores:
                if int(row[2]) == anime_id:
                    return int(row[4])
        return None

    def get_user_scores(self, username: str, user_id: int) -> Optional[list]:
        """
        Retrieve all anime scores for a user.

        Args:
            username (str): MyAnimeList username.
            user_id (int): MyAnimeList user ID.

        Returns:
            Optional[list]: List of score records or None if unavailable.
        """
        return self._scrape_user_scores(username, user_id)
