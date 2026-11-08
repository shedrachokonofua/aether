# Dev retains the read-only ClickStack grant and rogue holds qBittorrent;
# chart-owned Orion grants ship in the Orion chart. Tool names must match the
# gateway exactly.
locals {
  orion_gateway_tools = {
    # HyperDX's built-in MCP (litellm_config.yaml.tftpl clickstack): homelab
    # logs/traces/metrics. The gateway already exposes only read tools.
    clickstack = {
      allow = [
        "clickstack-clickstack_list_sources", "clickstack-clickstack_describe_source",
        "clickstack-clickstack_list_metrics", "clickstack-clickstack_describe_metric",
        "clickstack-clickstack_get_alert", "clickstack-clickstack_get_dashboard",
        "clickstack-clickstack_get_dashboard_tile", "clickstack-clickstack_search_dashboards",
        "clickstack-clickstack_query_tile", "clickstack-clickstack_query_tiles",
        "clickstack-clickstack_get_saved_search", "clickstack-clickstack_timeseries",
        "clickstack-clickstack_table", "clickstack-clickstack_search",
        "clickstack-clickstack_event_patterns", "clickstack-clickstack_event_deltas",
        "clickstack-clickstack_emerging_signals", "clickstack-clickstack_sql",
        "clickstack-clickstack_trace_waterfall",
        "clickstack-clickstack_trace_top_time_consuming_operations",
      ]
      ask = []
    }
    # qbittorrent-mcp-rs (litellm_config.yaml.tftpl qbittorrent); the gateway
    # already hides shutdown, preference writes and plugin installs. Ask
    # before anything that deletes data or files, or rewrites names.
    qbittorrent = {
      allow = [
        "qbittorrent-list_torrents", "qbittorrent-inspect_torrent",
        "qbittorrent-get_torrent_files", "qbittorrent-get_categories",
        "qbittorrent-find_duplicates", "qbittorrent-wait_for_torrent_status",
        "qbittorrent-get_system_info", "qbittorrent-get_main_log",
        "qbittorrent-get_peer_log", "qbittorrent-search_torrents",
        "qbittorrent-get_search_plugins", "qbittorrent-get_rss_feeds",
        "qbittorrent-get_rss_rules", "qbittorrent-add_torrent",
        "qbittorrent-manage_torrents", "qbittorrent-set_file_priority",
        "qbittorrent-add_trackers", "qbittorrent-update_search_plugins",
        "qbittorrent-enable_search_plugin", "qbittorrent-add_rss_feed",
        "qbittorrent-set_rss_rule", "qbittorrent-move_rss_item",
      ]
      ask = [
        "qbittorrent-delete_torrent", "qbittorrent-cleanup_completed",
        "qbittorrent-mass_rename", "qbittorrent-rename_folder",
        "qbittorrent-edit_tracker", "qbittorrent-remove_trackers",
        "qbittorrent-uninstall_search_plugin", "qbittorrent-ban_peers",
      ]
    }
  }
}
