# The `orion` agent's LiteLLM gateway grants (orion.tf builds one grant per
# server: /mcp/<server> with the agent's key). Names are exact because
# Daimyo's grant allowlist matches names exactly (daimyo
# bins/daimyo-sidecar/src/mcp.rs allowed()): a glob there forwards nothing.
# `ask` names get local.orion_ask (deleting, spending, publishing, admin).
# Taken from each server's tools/list through the gateway on 2026-10-19; a
# tool a server adds later stays hidden until it is listed here.
locals {
  orion_gateway_tools = {
    # Through the gateway's colony-litellm service account (realm admin,
    # keycloak.tf), so every change asks.
    colony = {
      allow = [
        "colony-colony_status", "colony-list_projects", "colony-list_scopes", "colony-get_scope",
        "colony-get_task", "colony-get_run", "colony-run_events", "colony-colony_guide",
      ]
      ask = [
        "colony-open_scope", "colony-approve_plan", "colony-replan", "colony-add_directive",
        "colony-scope_action", "colony-task_action",
      ]
    }
    affine = {
      allow = [
        "affine-list_workspaces", "affine-get_workspace", "affine-create_workspace",
        "affine-update_workspace", "affine-create_mindmap", "affine-get_mindmap",
        "affine-add_mindmap_node", "affine-update_mindmap_node", "affine-reparent_mindmap_node",
        "affine-set_mindmap_style", "affine-set_mindmap_lock", "affine-set_mindmap_layout",
        "affine-list_docs", "affine-search_docs", "affine-find_doc_by_title", "affine-list_tags",
        "affine-list_docs_by_tag", "affine-create_tag", "affine-add_tag_to_doc",
        "affine-remove_tag_from_doc", "affine-get_doc", "affine-read_doc", "affine-get_capabilities",
        "affine-analyze_doc_fidelity", "affine-move_doc", "affine-create_doc",
        "affine-create_semantic_page", "affine-append_semantic_section", "affine-append_block",
        "affine-export_doc_markdown", "affine-export_with_fidelity_report",
        "affine-create_doc_from_markdown", "affine-append_markdown", "affine-trash_doc",
        "affine-restore_doc", "affine-list_workspace_tree", "affine-get_orphan_docs",
        "affine-list_children", "affine-update_doc_title", "affine-inspect_template_structure",
        "affine-instantiate_template_native", "affine-add_database_row",
        "affine-read_database_cells", "affine-read_database_columns", "affine-update_database_row",
        "affine-compose_database_from_intent", "affine-add_database_column",
        "affine-add_surface_element", "affine-list_surface_elements",
        "affine-update_surface_element", "affine-update_frame_children",
        "affine-update_edgeless_block", "affine-update_block", "affine-update_table_cell",
        "affine-update_table_column_widths", "affine-move_block", "affine-get_edgeless_canvas",
        "affine-list_comments", "affine-create_comment", "affine-update_comment",
        "affine-resolve_comment", "affine-list_histories", "affine-list_collections",
        "affine-get_collection", "affine-create_collection", "affine-update_collection_rules",
        "affine-update_collection", "affine-add_doc_to_collection",
        "affine-remove_doc_from_collection", "affine-list_organize_nodes", "affine-create_folder",
        "affine-create_workspace_blueprint", "affine-rename_folder", "affine-move_organize_node",
        "affine-add_organize_link", "affine-set_doc_journal", "affine-list_doc_properties",
        "affine-create_custom_property", "affine-set_doc_property", "affine-clear_doc_property",
        "affine-update_doc_icon", "affine-update_folder_icon", "affine-get_doc_icon",
        "affine-get_folder_icon", "affine-current_user", "affine-update_profile",
        "affine-update_settings", "affine-sign_in", "affine-upload_blob",
        "affine-list_notifications", "affine-read_all_notifications",
      ]
      ask = [
        "affine-publish_doc", "affine-delete_workspace", "affine-delete_tag", "affine-revoke_doc",
        "affine-replace_doc_with_markdown", "affine-delete_doc", "affine-delete_database_row",
        "affine-delete_surface_element", "affine-delete_block", "affine-delete_comment",
        "affine-delete_collection", "affine-delete_folder", "affine-delete_organize_link",
        "affine-delete_custom_property", "affine-delete_blob", "affine-cleanup_blobs",
      ]
    }
    siren = {
      allow = [
        "siren-m9weby603s_ionService_DefaultQuantileRankAlbumAssessmentSettings",
        "siren-siren_AlbumService_FindSimilarAlbums", "siren-siren_AlbumService_FindSpotifyAlbum",
        "siren-siren_AlbumService_GetAlbum", "siren-siren_AlbumService_GetEmbeddingKeys",
        "siren-siren_AlbumService_GetManyAlbums", "siren-siren_AlbumService_GetMonitor",
        "siren-siren_AlbumService_SearchAlbums", "siren-siren_ArtistService_FindSimilarArtists",
        "siren-siren_ArtistService_GetArtist", "siren-siren_ArtistService_GetArtistOverview",
        "siren-siren_ArtistService_SearchArtists", "siren-siren_CrawlerService_Enqueue",
        "siren-siren_CrawlerService_GetMonitor", "siren-siren_EventService_GetMonitor",
        "siren-siren_FileService_GetFileContent", "siren-siren_FileService_GetFilePageType",
        "siren-siren_FileService_IsFileStale", "siren-siren_HealthCheck",
        "siren-siren_LookupService_GetAggregatedAlbumSearchStatuses",
        "siren-siren_LookupService_LookupAlbum", "siren-siren_OperationsService_CountKeysMatching",
        "siren-siren_OperationsService_GetEventKeyMigrationMonitor",
        "siren-siren_OperationsService_GetKeyValueStoreSize",
        "siren-siren_ParserService_GetAggregatedFailureErrors",
        "siren-siren_ProfileService_GetAllProfiles",
        "siren-siren_ProfileService_GetPendingSpotifyImports",
        "siren-siren_ProfileService_GetProfile", "siren-siren_ProfileService_GetProfileSummary",
        "siren-siren_ProfileService_ImportSavedSpotifyTracks",
        "siren-siren_ProfileService_ImportSpotifyPlaylistTracks",
        "siren-siren_ProfileService_PutAlbumOnProfile",
        "siren-siren_ProfileService_PutManyAlbumsOnProfile",
        "siren-siren_ProfileService_RemoveAlbumFromProfile",
        "siren-siren_RecommendationService_AssessAlbum",
        "siren-siren_RecommendationService_CreateSpotifyPlaylist",
        "siren-siren_RecommendationService_DraftSpotifyPlaylist",
        "siren-siren_RecommendationService_RecommendAlbums", "siren-siren_SchedulerService_GetJobs",
        "siren-siren_SchedulerService_GetSchedulerMonitor",
        "siren-siren_SpotifyService_GetAuthorizationUrl",
        "siren-siren_SpotifyService_GetPlaylistTracks", "siren-siren_SpotifyService_GetSavedTracks",
        "siren-siren_SpotifyService_IsAuthorized",
      ]
      ask = [
        "siren-siren_CrawlerService_Empty", "siren-siren_CrawlerService_RemoveThrottle",
        "siren-siren_CrawlerService_RequeueFailed", "siren-siren_CrawlerService_ResetLimiter",
        "siren-siren_CrawlerService_SetStatus", "siren-siren_EventService_DeleteCursor",
        "siren-siren_EventService_SetCursor", "siren-siren_EventService_SetSubscriberStatus",
        "siren-siren_FileService_DeleteFile", "siren-siren_FileService_PutFile",
        "siren-siren_LookupService_DeleteListLookup", "siren-siren_LookupService_PutListLookup",
        "siren-siren_OperationsService_ClearKeyValueStore",
        "siren-siren_OperationsService_ClearSearchStore",
        "siren-siren_OperationsService_CrawlParseFailedFiles",
        "siren-siren_OperationsService_DeleteKeysMatching",
        "siren-siren_OperationsService_MigrateSqlite",
        "siren-siren_OperationsService_MigrateSqliteToLatest",
        "siren-siren_OperationsService_ParseFileContentStore",
        "siren-siren_ParserService_EnqueueRetries",
        "siren-siren_ParserService_ParseFileOnContentStore",
        "siren-siren_ProfileService_ClearPendingSpotifyImports",
        "siren-siren_ProfileService_CreateProfile", "siren-siren_ProfileService_DeleteProfile",
        "siren-siren_SchedulerService_DeleteAllJobs", "siren-siren_SchedulerService_DeleteJob",
        "siren-siren_SchedulerService_PutJob", "siren-siren_SchedulerService_SetJobProcessorStatus",
        "siren-siren_SpotifyService_DeleteCredentials",
        "siren-siren_SpotifyService_HandleAuthorizationCode",
      ]
    }
    jellyfin = {
      allow = [
        "jellyfin-jellyfin_media", "jellyfin-jellyfin_library",
      ]
      ask = [
        "jellyfin-jellyfin_system",
      ]
    }
    comfyui = {
      allow = [
        "comfyui-server_info", "comfyui-run_workflow", "comfyui-generate_image",
        "comfyui-run_template", "comfyui-job", "comfyui-system_stats", "comfyui-free_memory",
        "comfyui-fetch_outputs", "comfyui-search_templates", "comfyui-get_template",
        "comfyui-fetch_template", "comfyui-nodes", "comfyui-search_models",
        "comfyui-validate_workflow", "comfyui-list_workflow_slots", "comfyui-list_workflow_notes",
        "comfyui-set_workflow_slot", "comfyui-vary_workflow",
      ]
      ask = []
    }
    espn = {
      allow = [
        "espn-list_competitions", "espn-list_teams", "espn-get_team", "espn-get_team_roster",
        "espn-find_player", "espn-get_player", "espn-get_team_schedule", "espn-get_scoreboard",
        "espn-get_standings", "espn-get_news", "espn-get_scores",
      ]
      ask = []
    }
    finviz = {
      allow = [
        "finviz-earnings_screener", "finviz-volume_surge_screener", "finviz-get_stock_fundamentals",
        "finviz-get_multiple_stocks_fundamentals", "finviz-trend_reversion_screener",
        "finviz-uptrend_screener", "finviz-dividend_growth_screener", "finviz-etf_screener",
        "finviz-earnings_premarket_screener", "finviz-earnings_afterhours_screener",
        "finviz-earnings_trading_screener", "finviz-get_stock_news", "finviz-get_market_news",
        "finviz-get_sector_news", "finviz-get_sector_performance", "finviz-get_industry_performance",
        "finviz-get_country_performance", "finviz-get_sector_specific_industry_performance",
        "finviz-get_capitalization_performance", "finviz-get_market_overview",
        "finviz-get_relative_volume_stocks", "finviz-technical_analysis_screener",
        "finviz-earnings_winners_screener", "finviz-upcoming_earnings_screener",
        "finviz-get_sec_filings", "finviz-get_major_sec_filings", "finviz-get_insider_sec_filings",
        "finviz-get_sec_filing_summary", "finviz-get_edgar_filing_content",
        "finviz-get_multiple_edgar_filing_contents", "finviz-get_edgar_company_filings",
        "finviz-get_edgar_company_facts", "finviz-get_edgar_company_concept",
        "finviz-list_available_fields", "finviz-get_field_categories", "finviz-describe_field",
        "finviz-search_fields", "finviz-validate_fields", "finviz-get_moving_average_position",
      ]
      ask = []
    }
    fm = {
      allow = [
        "fm-fm_status", "fm-fm_schema_search", "fm-fm_read", "fm-fm_read_list", "fm-fm_browse",
        "fm-fm_load_last_save", "fm-fm_search_players", "fm-fm_scan_records", "fm-fm_editor_fields",
        "fm-fm_edit_fields", "fm-fm_run_action", "fm-fm_move_person", "fm-fm_responsibilities",
        "fm-fm_set_responsibilities", "fm-fm_tactic", "fm-fm_set_tactic", "fm-fm_set_roles",
        "fm-fm_set_instructions", "fm-fm_pick_players", "fm-fm_send_event", "fm-fm_write",
        "fm-fm_inbox", "fm-fm_inbox_message", "fm-fm_inbox_mark_read", "fm-fm_match",
        "fm-fm_results", "fm-fm_fixtures", "fm-fm_league_table", "fm-fm_team_snapshot",
        "fm-fm_rivals",
      ]
      ask = []
    }
    google_maps = {
      allow = [
        "google_maps-maps_search_nearby", "google_maps-maps_place_details",
        "google_maps-maps_geocode", "google_maps-maps_reverse_geocode",
        "google_maps-maps_distance_matrix", "google_maps-maps_directions",
        "google_maps-maps_elevation", "google_maps-maps_search_places", "google_maps-maps_timezone",
        "google_maps-maps_weather", "google_maps-maps_explore_area", "google_maps-maps_plan_route",
        "google_maps-maps_compare_places", "google_maps-maps_air_quality",
        "google_maps-maps_static_map", "google_maps-maps_batch_geocode",
        "google_maps-maps_search_along_route", "google_maps-maps_local_rank_tracker",
      ]
      ask = []
    }
    time = {
      allow = [
        "time-add_time", "time-compare_time", "time-convert_timezone", "time-current_time",
        "time-relative_time",
      ]
      ask = []
    }
    tmdb = {
      allow = [
        "tmdb-tmdb_search_titles", "tmdb-tmdb_get_movie", "tmdb-tmdb_get_show",
        "tmdb-tmdb_get_season", "tmdb-tmdb_get_person", "tmdb-tmdb_discover_titles",
        "tmdb-tmdb_get_trending", "tmdb-tmdb_get_watch_providers",
      ]
      ask = []
    }
  }
}
