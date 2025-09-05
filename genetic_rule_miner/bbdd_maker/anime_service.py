import logging
import time
from io import BytesIO
from typing import Optional

import pandas as pd
import requests
from rake_nltk import Rake

from genetic_rule_miner.config import APIConfig
from genetic_rule_miner.utils.logging import LogManager

LogManager.configure()
logger = logging.getLogger(__name__)


class AnimeService:
    """
    Service for retrieving anime data from the external API.

    This service provides methods to fetch information for single or multiple
    anime by their MyAnimeList (MAL) IDs. It supports retries, exponential
    backoff, keyword extraction from anime synopses, and returns results
    either as dictionaries or CSV buffers.

    Attributes:
        config (APIConfig): Configuration object with API details such as
            base URL, timeout, and retry settings.
    """

    def __init__(self, config: APIConfig = APIConfig()):
        """
        Initialize the AnimeService with a given API configuration.

        Args:
            config (APIConfig, optional): Configuration for the API connection.
                Defaults to a new instance of APIConfig.
        """
        self.config = config
        logger.info("AnimeService initialized with config: %s", self.config)

    def _fetch_anime(self, anime_id: int) -> Optional[dict]:
        """
        Fetch anime data from the API by its ID.

        Implements retry logic with exponential backoff if the request fails.

        Args:
            anime_id (int): The MAL ID of the anime.

        Returns:
            Optional[dict]: Anime data as a dictionary, or None if not found
            or after exceeding the maximum retries.
        """
        for attempt in range(self.config.max_retries):
            try:
                logger.debug(
                    "Fetching anime with ID %d (Attempt %d)",
                    anime_id,
                    attempt + 1,
                )
                response = requests.get(
                    f"{self.config.base_url}anime/{anime_id}",
                    timeout=self.config.timeout,
                )
                if response.status_code == 404:
                    logger.warning(
                        "Anime with ID %d not found (404). Skipping further attempts.",
                        anime_id,
                    )
                    return None
                response.raise_for_status()
                logger.debug("Successfully fetched anime with ID %d", anime_id)
                return response.json().get("data")
            except requests.RequestException as e:
                logger.warning(
                    "Failed to fetch anime with ID %d on attempt %d: %s",
                    anime_id,
                    attempt + 1,
                    e,
                )

                if attempt < self.config.max_retries - 1:
                    logger.debug("Waiting before the next attempt...")
                    time.sleep(2**attempt)  # Exponential backoff
        logger.error(
            "Failed to fetch anime with ID %d after %d attempts",
            anime_id,
            self.config.max_retries,
        )
        return None

    def get_anime_by_id(self, mal_id: int) -> Optional[dict]:
        """
        Get the details of a single anime by its MAL ID.

        Args:
            mal_id (int): The MAL ID of the anime.

        Returns:
            Optional[dict]: Dictionary containing anime details, or None if
            the anime is not found.
        """
        return self._fetch_anime(mal_id)

    def get_anime_by_ids(self, mal_ids: list[int]) -> BytesIO:
        """
        Get details for multiple anime and return them as a CSV buffer.

        Each anime's details include metadata such as title, genres, score,
        production info, and extracted keywords from its synopsis.

        Args:
            mal_ids (list[int]): List of MAL IDs to fetch.

        Returns:
            BytesIO: A buffer containing the anime data in CSV format.
        """
        logger.info("Fetching anime data for %d IDs", len(mal_ids))
        buffer = BytesIO()
        records = []
        r = Rake()

        for anime_id in mal_ids:
            logger.debug("Processing anime ID %d", anime_id)
            data = self._fetch_anime(anime_id)
            if data:
                synopsis = data.get("synopsis", "")
                keywords = ""
                if synopsis:
                    try:
                        r.extract_keywords_from_text(synopsis)
                        keywords = ", ".join(r.get_ranked_phrases())
                    except Exception as e:
                        logger.error(
                            "Keyword extraction failed for anime ID %d: %s",
                            anime_id,
                            e,
                        )

                records.append(
                    {
                        "anime_id": anime_id,
                        "name": data.get("title"),
                        "english_name": data.get("title_english"),
                        "japanese_name": data.get("title_japanese"),
                        "score": data.get("score"),
                        "genres": ", ".join(
                            [g["name"] for g in data.get("genres", [])]
                        ),
                        "keywords": keywords,
                        "type": data.get("type"),
                        "episodes": data.get("episodes"),
                        "aired": data.get("aired", {}).get("string"),
                        "premiered": f"{data.get('season', '')} {data.get('year', '')}".strip(),
                        "status": data.get("status"),
                        "producers": ", ".join(
                            [p["name"] for p in data.get("producers", [])]
                        ),
                        "studios": ", ".join(
                            [s["name"] for s in data.get("studios", [])]
                        ),
                        "source": data.get("source"),
                        "duration": data.get("duration"),
                        "rating": data.get("rating"),
                        "rank": data.get("rank"),
                        "popularity": data.get("popularity"),
                        "favorites": data.get("favorites"),
                        "scored_by": data.get("scored_by"),
                        "members": data.get("members"),
                    }
                )

        df = pd.DataFrame(records)
        df.to_csv(buffer, index=False)
        buffer.seek(0)
        logger.info("Anime data written to buffer")
        return buffer

    def get_anime_data(self, start_id: int, end_id: int) -> BytesIO:
        """
        Get anime data for a range of MAL IDs.

        Internally calls `get_anime_by_ids`.

        Args:
            start_id (int): Starting MAL ID (inclusive).
            end_id (int): Ending MAL ID (inclusive).

        Returns:
            BytesIO: A buffer containing the anime data in CSV format.
        """
        return self.get_anime_by_ids(list(range(start_id, end_id + 1)))
