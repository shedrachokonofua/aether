# Dev retains the read-only ClickStack grant and rogue holds qBittorrent;
# chart-owned Orion grants ship in the Orion chart. Tool names must match
# Meridian's exactly: `<source>_<tool>` (meridian.tf).
locals {
  orion_gateway_tools = {
    # HyperDX's built-in MCP (meridian.tf `clickstack` source): homelab
    # logs/traces/metrics. Meridian serves only its read tools.
    clickstack = {
      allow = [
        "clickstack_list_sources", "clickstack_describe_source",
        "clickstack_list_metrics", "clickstack_describe_metric",
        "clickstack_get_alert", "clickstack_get_dashboard",
        "clickstack_get_dashboard_tile", "clickstack_search_dashboards",
        "clickstack_query_tile", "clickstack_query_tiles",
        "clickstack_get_saved_search", "clickstack_timeseries",
        "clickstack_table", "clickstack_search",
        "clickstack_event_patterns", "clickstack_event_deltas",
        "clickstack_emerging_signals", "clickstack_sql",
        "clickstack_trace_waterfall",
        "clickstack_trace_top_time_consuming_operations",
      ]
      ask = []
    }
    # qbittorrent-mcp-rs (litellm_config.yaml.tftpl qbittorrent, reached
    # through Meridian's `qbittorrent` source); LiteLLM's allowlist already
    # hides shutdown, preference writes and plugin installs. Ask
    # before anything that deletes data or files, or rewrites names.
    qbittorrent = {
      allow = [
        "qbittorrent_list_torrents", "qbittorrent_inspect_torrent",
        "qbittorrent_get_torrent_files", "qbittorrent_get_categories",
        "qbittorrent_find_duplicates", "qbittorrent_wait_for_torrent_status",
        "qbittorrent_get_system_info", "qbittorrent_get_main_log",
        "qbittorrent_get_peer_log", "qbittorrent_search_torrents",
        "qbittorrent_get_search_plugins", "qbittorrent_get_rss_feeds",
        "qbittorrent_get_rss_rules", "qbittorrent_add_torrent",
        "qbittorrent_manage_torrents", "qbittorrent_set_file_priority",
        "qbittorrent_add_trackers", "qbittorrent_update_search_plugins",
        "qbittorrent_enable_search_plugin", "qbittorrent_add_rss_feed",
        "qbittorrent_set_rss_rule", "qbittorrent_move_rss_item",
      ]
      ask = [
        "qbittorrent_delete_torrent", "qbittorrent_cleanup_completed",
        "qbittorrent_mass_rename", "qbittorrent_rename_folder",
        "qbittorrent_edit_tracker", "qbittorrent_remove_trackers",
        "qbittorrent_uninstall_search_plugin", "qbittorrent_ban_peers",
      ]
    }
  }
}
