"""Sonarr config sync module.

Same *arr API as Radarr — just different URLs, keys, and download client category.
"""

from configs.sync.modules.radarr import RadarrModule


class SonarrModule(RadarrModule):
    name = "sonarr"
    url_env = "SONARR_URL"
    key_env = "SONARR_API_KEY"
    default_url = "http://sonarr:8989"
    config_xml_path = "/sonarr-config/config.xml"

    import_category_field = "tvImportedCategory"
    import_category_value = "tv-imported"
