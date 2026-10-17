# Schema to presentation mapping

`../schema.sql` is the contract. The UI uses illustrative fixtures, not schema migrations or proposed API endpoints.

| Screen | Stored source | Derived or local values |
| --- | --- | --- |
| Fixtures / match | `scoring_matches` match_id, league_id, sport_id, home, away, scheduled_at; `scoring_leagues` name | Scores/status project `scoring_events` (ADR-3). No venue, referee, clock or matchday column is assumed. |
| Sports / leagues | `sports.sport_id`, config; `scoring_leagues.sport_id` | Four sample display labels. Replace with configured leagues/sports and format scoring controls according to config (ADR-4). |
| Match timeline / draft | `scoring_events` sequence, type, payload, compensates | Generic sample labels and a local draft; no real signature, event payload or score mutation generated. |
| Standings | `scoring_leagues` teams, points, tie_break_order, spots plus scoring events | Played, W/D/L, points/rank are server projections. The illustrative table is not recomputed from the few sample fixtures. |
| Club overview | `roster_clubs` name/profile; `roster_squads` name/club_id/league_id | Biography is possible profile JSON, not a dedicated column; define that JSON shape during integration. Hero artwork is local. |
| Roster / player | `roster_players` id/name/position; `roster_registrations` reg_type, squad_id, parent_squad_id, start_date, loan_end_date, role | Count is an aggregate. Human-readable labels need mapping to actual backend enums. No jersey numbers, player performance statistics, injury status or staff qualifications assumed. |
| Roster action | `roster_leagues` window dates, max_squad_size, required_positions; `roster_requests`, `roster_audit` | Local draft only. Server validates capacity, dates, tenant, role and eligibility (ADR-6/8). |
| Store / product | `store_products` name/category/description; `store_variants` id/label/size/color/price_minor/currency/stock/reserved | Local artwork. Integer minor-unit prices in PKR. No product image column, reviews, favorites or shipping table assumed. |
| Bag / checkout | `store_discount_codes` code/percent; `store_orders` customer_id/request/status/response | Ephemeral cart. WELCOME10 is a sample 10% code. Total = subtotal − discount. No delivery fees, tax, saved cards or address contract invented. Server remains authoritative for reservations/prices/totals (ADR-5). |
| Receipt | `store_orders` order_id, status, response, created_at | PREVIEW-001 and local line snapshots are explicitly samples. Future response JSON needs definition. No PDF or tracking implied. |
| Profile / sign-in | `rbac_users` email/display_name/role/scoped IDs; `rbac_tenants` branding | Role selector only previews UI. Password is not saved/sent. Server must authenticate and authorize. |
| Sync | `sync_actions` device_id/action_id/result | Pending queue is client state. Simulate sync only toggles sample display; integrate real queue/replay/deduplication/results later (ADR-8). |

## Integration boundary

Introduce FastAPI repositories returning typed view models and inject them into screen controllers. Retain static fixtures for tests. Replace PreviewState inputs with your application state when connecting the API. Explicitly map IDs, enums, currency, profile JSON, score projections, standings, transfer validation and order response fields.

No schema.sql or Python backend changes were made. Unsupported parts of Stitch were omitted. A/B screen variants were consolidated into one mobile flow per feature.
