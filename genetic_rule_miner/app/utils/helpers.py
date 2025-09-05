def update_controls(query, full_series_list, checkbox_map, search_bar_ref):
    """
    Update the search bar controls based on a query.

    Filters a list of series names using the provided query (case-insensitive),
    updates the search bar with the first 10 matching results, and refreshes
    the displayed controls.

    Args:
        query (str): The text input used to filter the series list.
        full_series_list (list[str]): A list of all available series names.
        checkbox_map (dict): A mapping of series names to their corresponding
            checkbox controls (e.g., {"Series A": ft.Checkbox(...)}).
        search_bar_ref (ft.Ref): A reference to the search bar container,
            which will be updated with the filtered checkbox controls.

    Returns:
        None
    """
    lower_query = query.lower()
    filtered = [s for s in full_series_list if lower_query in s.lower()][:10]
    search_bar_ref.current.controls = [checkbox_map[s] for s in filtered]
    search_bar_ref.current.update()
