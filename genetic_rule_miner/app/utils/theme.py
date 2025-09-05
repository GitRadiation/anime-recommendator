from flet import Colors, ColorScheme, Page, Theme, ThemeMode


def setup_theme(page: Page):
    """
    Configure and apply custom themes to the Flet page.

    Sets the background color depending on the current theme mode,
    applies the light theme as default, and configures both light
    and dark themes for the application.

    Args:
        page (Page): The Flet page object to configure.

    Returns:
        None
    """
    page.bgcolor = "#282A36" if page.theme_mode == "dark" else Colors.WHITE
    page.theme_mode = ThemeMode.LIGHT
    page.theme = get_light_theme()
    page.dark_theme = get_dark_theme()
    page.update()


def get_light_theme() -> Theme:
    """
    Define and return a custom light theme.

    The light theme uses a white background, dark text,
    and purple as the primary/secondary accent color.

    Returns:
        Theme: A custom Flet Theme object for light mode.
    """
    return Theme(
        color_scheme=ColorScheme(  # type: ignore
            background="#FFFFFF",
            on_background=Colors.BLACK,
            surface="#FFFFFF",
            on_surface=Colors.BLACK,
            primary=Colors.PURPLE_400,
            secondary=Colors.PURPLE_400,
            surface_variant="#E0E0E0",
            on_surface_variant=Colors.BLACK,
            error=Colors.RED,
            on_error=Colors.WHITE,
            error_container=Colors.RED_200,
            on_error_container=Colors.WHITE,
        )
    )


def get_dark_theme() -> Theme:
    """
    Define and return a custom dark theme with improved contrast.

    The dark theme uses a dark background with light text
    and adjusted surface colors to ensure readability.

    Returns:
        Theme: A custom Flet Theme object for dark mode.
    """
    return Theme(
        color_scheme=ColorScheme(  # type: ignore
            background="#282A36",
            on_background="#FFFFFF",
            surface="#44475A",
            on_surface="#F0F0F0",
            primary=Colors.PURPLE_400,
            secondary="#B39DDB",
            surface_variant="#323450",
            on_surface_variant="#F0F0F0",
            error=Colors.RED,
            on_error="#FFFFFF",
            error_container=Colors.RED_200,
            on_error_container="#FFFFFF",
            outline_variant="#282A36",
        )
    )