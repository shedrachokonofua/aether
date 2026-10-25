# Dev retains the read-only ClickStack grant; chart-owned Orion grants ship
# in the Orion chart. Tool names must match the gateway exactly.
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
  }
}
