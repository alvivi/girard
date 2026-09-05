# Differential testing — package status

Tracks hex.pm packages run through girard's differential oracle. Each row is the
result of comparing girard's per-expression output to the real compiler's, using
a consistent, hex-resolved dependency closure:

```sh
bash scripts/sweep.sh <package>
```

`sweep.sh` resolves the package's full transitive dependency tree, exports the
oracle with the package as the build root, stages those exact dependency
versions in a separate packages root, and passes that root to `girard/diff`.

## Legend

| Status | Meaning |
| --- | --- |
| ✅ clean | 0 errored modules, 0 expression mismatches |
| 🔧 fixed | a discrepancy was found and fixed in girard (commit noted) |
| ⏭️ skip · build | the package or a dependency does not compile with current tooling (the compiler can't type it either) |
| ⏭️ skip · resolve | could not resolve/download from hex (not found, or a version conflict) |
| 📝 note | tested, with a remark |

Adding a row: run `sweep.sh`, then record the result here alphabetically. When a
fix is required, add a regression test and link the commit.

## Packages

| Package | Status | Notes |
| --- | --- | --- |
| abair | ✅ clean |  |
| acrostic | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| act | ✅ clean |  |
| actorx | ⏭️ skip · resolve | not found / could not download. |
| acumen | ✅ clean | was glance kind A (arithmetic in a bit-array *pattern* segment size, via dep `kryptos/internal/der` `bytes-size(len - 1)`); parses since glance 7.0.0. |
| adglent | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| ag_html | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| aham | ✅ clean |  |
| aide | ✅ clean |  |
| aide_generator | ✅ clean |  |
| akaridb | ✅ clean |  |
| alakazam | ✅ clean |  |
| alpacki | ✅ clean |  |
| amaro | ✅ clean |  |
| amber | ✅ clean |  |
| amf0 | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| amnesiac | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| ankiconnect | ✅ clean |  |
| ansel | ✅ clean |  |
| anthropic_gleam | ✅ clean |  |
| antigone | ✅ clean |  |
| antimonia | ✅ clean |  |
| aoc_2024 | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| aonyx_graph | ✅ clean |  |
| apollo | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| aragorn2 | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| arcana_signals | ✅ clean |  |
| arctic | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| arctic_plugin_diagram | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| argamak | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| argus | ✅ clean |  |
| argv | ✅ clean |  |
| ascii_fold | ✅ clean |  |
| ask | ✅ clean |  |
| assemblyai | ✅ clean |  |
| asset | ✅ clean |  |
| asterix | ✅ clean |  |
| atomb | ✅ clean | earlier `unbound`/over-unification cleared by the call-graph scoping fix (`e915817`). |
| atomic_array | ✅ clean |  |
| atto | ✅ clean |  |
| automata | ✅ clean |  |
| aws4_request | ✅ clean |  |
| aws_api | ⏭️ skip · resolve | not found / could not download. |
| aws_credentials_gleam | ✅ clean |  |
| aws_gleam_api_gateway | ✅ clean |  |
| aws_gleam_dynamodb | ✅ clean |  |
| aws_gleam_rds | ✅ clean |  |
| aws_gleam_runtime | ✅ clean |  |
| aws_gleam_s3 | ✅ clean |  |
| aws_gleam_sesv2 | ✅ clean |  |
| aws_gleam_sqs | ✅ clean |  |
| babble | ✅ clean |  |
| balanced_tree_gleam | ✅ clean |  |
| barnacle | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| base_emoji | ✅ clean |  |
| base_x_gleam | ✅ clean |  |
| based | ✅ clean |  |
| based_pg | ✅ clean |  |
| based_sqlite | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| bath | ✅ clean |  |
| battlesnake | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| beach | ✅ clean |  |
| beecrypt | ✅ clean |  |
| beencode | ✅ clean |  |
| benedict | ✅ clean |  |
| bespoke | ✅ clean |  |
| bg_jobs | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| bibi | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| bidict | ✅ clean |  |
| bigben | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| bigdecimal | ✅ clean |  |
| bigi | ✅ clean |  |
| binary_search | ✅ clean |  |
| birch | ✅ clean |  |
| birdie | ✅ clean | was glance kind A (arithmetic in a bit-array *pattern* segment size `size(end - start)` in `internal/diagnostic`); parses since glance 7.0.0. |
| birl | ✅ clean |  |
| biscotto | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| bison | ⏭️ skip · build |  |
| bitsandbobs | ✅ clean |  |
| bitty | ✅ clean |  |
| blah | ✅ clean |  |
| blask | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| blimp | ✅ clean |  |
| bliss | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| blogatto | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| blush | ✅ clean |  |
| booklet | ✅ clean |  |
| boyer_moore | ✅ clean |  |
| bravo | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| bread | ✅ clean |  |
| bright | ✅ clean |  |
| brilo | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| brioche | ✅ clean |  |
| brot | ✅ clean |  |
| bseal | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| bsky_comments_widget | ✅ clean |  |
| bucket | ✅ clean |  |
| builder | ✅ clean |  |
| bummer | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| bungibindies | ✅ clean |  |
| bungle | ✅ clean |  |
| butterbee | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| butterbidi | ✅ clean |  |
| butterlib | ⏭️ skip · resolve | not found / could not download. |
| bytes | ✅ clean |  |
| bytesize | ✅ clean |  |
| cachmere | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| cactus | ✅ clean |  |
| caffeine_lang | ✅ clean |  |
| caffeine_query_language | ✅ clean |  |
| cake | ✅ clean |  |
| cake_gleam_pgo | ⏭️ skip · resolve | not found / could not download. |
| cake_gmysql | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| cake_pog | ✅ clean |  |
| cake_shork | ✅ clean |  |
| cake_sqlight | ✅ clean |  |
| caldav_gleam | ✅ clean |  |
| cangaroo | ✅ clean |  |
| capuchin_crypt | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| carotte | ✅ clean |  |
| carpenter | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| casefold | ✅ clean |  |
| casper | ✅ clean |  |
| castor | ✅ clean |  |
| cat | ✅ clean |  |
| category_theory | ⏭️ skip · resolve | not found / could not download. |
| catppuccin | ✅ clean |  |
| cave3dplus | ⏭️ skip · resolve | not found / could not download. |
| cel | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| cell | ✅ clean |  |
| cgi | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| chaplin | ✅ clean |  |
| chatbot | ✅ clean |  |
| check_maybe_div_by_zero | ✅ clean |  |
| checkmark | ✅ clean |  |
| chic | ✅ clean |  |
| child_process | ✅ clean |  |
| chilli | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| chilp | ✅ clean |  |
| chip | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| choire | ✅ clean |  |
| chomp | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| chrobot | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| chrobot_extra | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| chromatic | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| cigogne | 🔧 fixed | `config.dependencies` field access on a local constant was dropped as a dependency edge → const inferred too late → unbound. Fixed: references split into values vs field-access qualifiers (`656e830`). |
| circuit | ✅ clean |  |
| circuit_breaker | ✅ clean |  |
| clad | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| clamav_client | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| classify | ⏭️ skip · resolve | not found / could not download. |
| claude_gleam | ✅ clean |  |
| cleam | ✅ clean |  |
| clip | ✅ clean |  |
| cloak_wrapper | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| clockwork | ✅ clean |  |
| clockwork_schedule | ✅ clean |  |
| cmp_gleam | ✅ clean |  |
| cnocco | ✅ clean |  |
| coffee | ✅ clean |  |
| cog | ✅ clean |  |
| coinglecko | ✅ clean |  |
| collatz | ✅ clean |  |
| collie | ✅ clean |  |
| colored | ✅ clean |  |
| colorhash | ✅ clean |  |
| colours | ✅ clean |  |
| comet | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| common_sql | ✅ clean |  |
| common_sql_postgresql | ✅ clean |  |
| common_sql_sqlite | ✅ clean |  |
| commonmark | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| comparator | ✅ clean |  |
| compresso | ✅ clean |  |
| conllu | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| contenty | ✅ clean |  |
| context_fp_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| contour | ✅ clean |  |
| conversation | ✅ clean |  |
| convert | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| convert_http_query | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| convert_json | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| corrosion | ✅ clean |  |
| cors_builder | 🔧 fixed | `res \|> set_allowed_origin(cors, origin)` — pipe into a *saturated* call applies the value to the result (`f(args)(left)`); girard always inserted it as the first argument → wrong arity. Fixed in `infer_pipe` (`6a58010`). |
| cosepo | ✅ clean |  |
| cosmo_cli | ✅ clean |  |
| cosmos | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| counter | ✅ clean |  |
| country | ✅ clean |  |
| cowl | ✅ clean |  |
| cp1250 | ✅ clean |  |
| cquill | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| crabbucket_pgo | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| crabbucket_redis | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| crew | 🔧 fixed | a parameter named `pool` shadowing a top-level `pool` created a spurious call-graph edge, merging `worker_loop` into `pool`'s component so it never generalized; `worker`'s call then over-unified its `PoolMsg`/`Work` type params. Fixed: lexical scoping in reference collection (`e915817`). |
| crossbar | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| css_select | ✅ clean |  |
| cthulhu | ✅ clean | was glance kind A (arithmetic in a bit-array *pattern* segment size `little-signed-size(is_dead * 32)`); parses since glance 7.0.0. |
| cuid2_gleam | ✅ clean |  |
| cx | ✅ clean |  |
| cycle | ✅ clean |  |
| cymbal | ✅ clean |  |
| cynthia_websites_mini_client | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| cynthia_websites_mini_server | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| dachshund | ✅ clean |  |
| dag_json | ✅ clean |  |
| dagger_gleam | ✅ clean |  |
| dahlia | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| database | ✅ clean |  |
| datadog_client | ✅ clean |  |
| datadog_query | ✅ clean |  |
| dataprep | ✅ clean |  |
| datastar | ✅ clean |  |
| datastar_gleam | ✅ clean |  |
| datastar_lustre | ✅ clean |  |
| datastar_wisp | ✅ clean |  |
| datastream | ✅ clean |  |
| datebook | ✅ clean |  |
| dateformat | ✅ clean |  |
| datetime_iso8601 | ✅ clean |  |
| db_pool | ✅ clean |  |
| dbots | ✅ clean |  |
| decepticon | ✅ clean |  |
| decipher | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| decode | ⏭️ skip · build | an old `decode` version does not compile against the resolved newer `gleam_stdlib`. |
| dedent | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| dee | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| defangle | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| defer_g | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| delay | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| delay_times | ✅ clean |  |
| deriv | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| derived | ✅ clean |  |
| dew | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| dewey | ✅ clean |  |
| dice_trio | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| diced | ✅ clean |  |
| differance | ✅ clean |  |
| dig | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| dijkstra | ✅ clean |  |
| dime | ✅ clean |  |
| dinostore | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| directories | ✅ clean |  |
| dirtree | ✅ clean |  |
| dirty_deeds_done_dirt_cheap | ✅ clean |  |
| discord_gleam | ✅ clean |  |
| discord_gleam_stratus | ✅ clean |  |
| distribute | ✅ clean |  |
| dnalg | ✅ clean |  |
| dnd | ✅ clean |  |
| domu | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| dot_env | 🔧 fixed | `simplifile.do_file_info` is declared twice (`@target(erlang)` → `Result(_, FileError)`, `@target(javascript)` → `Result(_, String)`); girard ignored `@target` so the JS one shadowed the Erlang one → `String vs FileError`. Fixed: filter non-Erlang `@target` definitions (`dd501f2`). |
| dotenv_conf | ✅ clean |  |
| dotenv_gleam | ✅ clean |  |
| dove | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| dream | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| dream_config | ✅ clean |  |
| dream_ets | ✅ clean |  |
| dream_http_client | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| dream_json | ✅ clean |  |
| dream_mock_server | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| dream_opensearch | ✅ clean |  |
| dream_postgres | ✅ clean |  |
| dream_test | ✅ clean |  |
| drift | ✅ clean |  |
| drift_actor | ✅ clean |  |
| drift_js | ✅ clean |  |
| drift_record | ✅ clean |  |
| ducky | ✅ clean |  |
| dunji | ✅ clean |  |
| duration_format | ✅ clean |  |
| dysmal | ✅ clean |  |
| easings_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| ecoji | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| edit_distance | ✅ clean |  |
| eensy | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| eensy_dev_tools | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| efetch | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| effect | ✅ clean |  |
| either_or | ✅ clean |  |
| embeds | ✅ clean |  |
| emel | ⏭️ skip · resolve | not found / could not download. |
| emojindex | ✅ clean |  |
| emojindex_kitchen | ✅ clean |  |
| emojis | ✅ clean |  |
| ensaimada | ✅ clean |  |
| envie | ✅ clean |  |
| envoker | ✅ clean |  |
| envoy | ✅ clean |  |
| eparch | ✅ clean |  |
| escpos | ✅ clean |  |
| esdee | 🔧 fixed | a local `let try_find = fn(with: fn(_) -> Result(a, Nil), _) {..}` helper applied at two record types; girard treated the local binding as monomorphic. Fixed: generalize a let-bound function over its annotation type variables (`5362dfd`). |
| esgleam | ✅ clean |  |
| espresso | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| espresso_pgo_wrapper | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| etch | ✅ clean |  |
| etch_erlang | ✅ clean |  |
| etch_javascript | ✅ clean |  |
| etf_js | ✅ clean |  |
| etui | ✅ clean |  |
| eval | ✅ clean |  |
| event_hub | ✅ clean |  |
| eventsourcing | ✅ clean |  |
| eventsourcing_glyn | ✅ clean |  |
| eventsourcing_inmemory | ⏭️ skip · resolve | not found / could not download. |
| eventsourcing_postgres | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| eventsourcing_sqlite | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| ewe | ✅ clean |  |
| exception | ✅ clean |  |
| exercism_test_runner | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| expresso | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| eyg_analysis | ✅ clean |  |
| eyg_compiler | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| eyg_interpreter | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| eyg_ir | ✅ clean |  |
| eyg_parser | ✅ clean | was a glance bit-array *pattern* size parse gap in `eyg/parser/lexer` (had cascaded to `unbound variable: lexer`); parses since glance 7.0.0. |
| ezconfig | ✅ clean |  |
| fabulous | ✅ clean |  |
| facet | ✅ clean |  |
| facquest | ⏭️ skip · resolve | not found / could not download. |
| falala | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| falcon | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| fcgi | ✅ clean |  |
| feather | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| feature_flags | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| feiertag | ✅ clean |  |
| felix | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| fetch_event | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| ffmpeg | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| fhir | ✅ clean |  |
| fhir_client_httpc | ✅ clean |  |
| fhir_client_rsvp | ✅ clean |  |
| fibo | ✅ clean |  |
| fiction | ✅ clean |  |
| fiction_env | ✅ clean |  |
| fiction_toml | ✅ clean |  |
| file_streams | ✅ clean |  |
| filepath | ✅ clean |  |
| filespy | ✅ clean |  |
| finanza | ✅ clean |  |
| finch_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| fio | ✅ clean |  |
| fireball | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| fist | ✅ clean |  |
| flash | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| flixi | ✅ clean |  |
| fluentci | ✅ clean |  |
| fluo | ✅ clean |  |
| fluoresce | ✅ clean |  |
| flwr_oauth2 | ✅ clean |  |
| fmglee | ✅ clean |  |
| fmt | ✅ clean |  |
| for_the_crows | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| form_coder | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| formal | ✅ clean |  |
| format | ✅ clean |  |
| formz | ✅ clean |  |
| formz_lustre | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| formz_nakai | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| formz_string | ✅ clean |  |
| fp | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| fp2 | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| fp2_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| fp_gl | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| fp_utils | ✅ clean |  |
| frac | ✅ clean |  |
| fractional_indexing | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| fragmentation | ✅ clean |  |
| franz | ✅ clean |  |
| fresnel | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| friendly_id | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| frontmatter | ✅ clean |  |
| fswalk | ✅ clean |  |
| ftpasta | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| functx | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| funsies | ⏭️ skip · resolve | not found / could not download. |
| funtil | ✅ clean |  |
| fused | ✅ clean |  |
| future | ✅ clean |  |
| fyni | ✅ clean |  |
| g18n | ✅ clean |  |
| g18n_dev | ✅ clean |  |
| gacache | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gai | ✅ clean |  |
| galant | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| galchemy | ✅ clean |  |
| gap | ✅ clean |  |
| garnet_tool | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gary | ✅ clean |  |
| gauth | ✅ clean |  |
| gauzy | ✅ clean |  |
| gaveta | ✅ clean |  |
| gbase32_clockwork | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gblake2 | ✅ clean |  |
| gblake3 | ✅ clean |  |
| gbor | ✅ clean |  |
| gbr_disk_log | ✅ clean |  |
| gbr_erl | ✅ clean |  |
| gbr_gh | ✅ clean |  |
| gbr_js | ✅ clean |  |
| gbr_md_lustre | ✅ clean |  |
| gbr_msal | ✅ clean |  |
| gbr_shared | ✅ clean |  |
| gbr_ui | ✅ clean |  |
| gcalc | ✅ clean |  |
| gchess | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gclog | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gcourier | ✅ clean |  |
| gdo | ✅ clean |  |
| geckolex | ✅ clean |  |
| ged25519 | ✅ clean |  |
| gel | ⏭️ skip · resolve | not found / could not download. |
| gelman | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gemo | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gemqtt | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gen_core_erlang | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gen_gleam | ✅ clean |  |
| gens | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| genserver | ✅ clean |  |
| geny | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| geokit | ✅ clean |  |
| germinal | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gexcept | ⏭️ skip · resolve | not found / could not download. |
| gextra | ✅ clean |  |
| gflambe | ✅ clean |  |
| gftp | ✅ clean |  |
| ggleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| ghtml | ✅ clean |  |
| gild | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gild_frontend | ✅ clean |  |
| gilly | ✅ clean |  |
| ginger | ✅ clean |  |
| gip | ✅ clean |  |
| git_store | ✅ clean |  |
| github_sdk | ✅ clean |  |
| given | 🔧 fixed | self-recursive `partition_loop` using imported constructors wasn't generalized → monomorphic across uses. Fixed: quantified scheme variables treated as opaque in `env_free_vars`. |
| gjwt | ✅ clean |  |
| gl | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gl_dfjson | ✅ clean |  |
| gl_gtin | ✅ clean |  |
| gl_wasm | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glace | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glacier | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glacier_gleeunit | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gladvent | ⏭️ skip · build | a transitive `decode` version is broken against the resolved stdlib. |
| glailglind | ✅ clean |  |
| glailwind_merge | ✅ clean |  |
| glam | ✅ clean |  |
| glambda | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glame | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glaml | ✅ clean |  |
| glamour | ✅ clean |  |
| glance | ✅ clean |  |
| glance_armstrong | ✅ clean |  |
| glance_printer | ✅ clean |  |
| glanoid | ✅ clean |  |
| glap | ✅ clean |  |
| glare | ✅ clean |  |
| glat | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glatch | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glatistics | ✅ clean |  |
| glats | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glatus | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glaze_basecoat | ✅ clean |  |
| glaze_oat | ✅ clean |  |
| glazed_corn | ✅ clean |  |
| glbencode | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glcode | ✅ clean |  |
| gleaf | ✅ clean |  |
| gleaflet | ✅ clean |  |
| gleam_bitwise | ✅ clean |  |
| gleam_community_ansi | ✅ clean |  |
| gleam_community_colour | ✅ clean |  |
| gleam_community_maths | ✅ clean |  |
| gleam_community_path | ✅ clean |  |
| gleam_cowboy | ✅ clean |  |
| gleam_crypto | ✅ clean |  |
| gleam_deque | ✅ clean |  |
| gleam_elli | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleam_erlang | ✅ clean |  |
| gleam_fetch | ✅ clean |  |
| gleam_hackney | ✅ clean |  |
| gleam_hexpm | ✅ clean |  |
| gleam_http | ✅ clean |  |
| gleam_httpc | ✅ clean |  |
| gleam_javascript | ✅ clean | JS-target package. |
| gleam_json | ✅ clean |  |
| gleam_otp | ✅ clean |  |
| gleam_package_interface | ✅ clean |  |
| gleam_pgo | ⏭️ skip · build |  |
| gleam_regexp | ✅ clean |  |
| gleam_stdlib | ✅ clean |  |
| gleam_time | ✅ clean |  |
| gleam_yaml | ✅ clean |  |
| gleam_yielder | ✅ clean |  |
| gleambox | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleameter | ✅ clean |  |
| gleamgen | 🔧 fixed | girard pinned a phantom signature type variable (`Expression(Dynamic)`) where the compiler keeps it polymorphic (`Expression($0)`). Fixed: rigid (skolemized) type variables for annotated functions, kept polymorphic across their SCC (`7d7eab0`). |
| gleamix | ✅ clean |  |
| gleamlz_string | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleamoire | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleamql | ✅ clean |  |
| gleamrpc | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleamrpc_http_client | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleamrpc_http_server | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleamstar | ✅ clean |  |
| gleamstral | ✅ clean |  |
| gleamsver | ✅ clean |  |
| gleamx | ✅ clean |  |
| gleamy_bench | ✅ clean |  |
| gleamy_lights | ✅ clean |  |
| gleamy_structures | ✅ clean |  |
| gleamy_zipper | ✅ clean |  |
| gleamyshell | ✅ clean |  |
| glean | ✅ clean |  |
| gleanix | ✅ clean |  |
| gleaph | ✅ clean |  |
| glearray | ✅ clean |  |
| gleastsq | ✅ clean |  |
| gleatfy | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleative | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleatter | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleatter_lustre | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleave | ✅ clean |  |
| gleb128 | ✅ clean |  |
| glebs | ✅ clean |  |
| glector | ✅ clean |  |
| glecuid | ✅ clean |  |
| gledis | ⏭️ skip · resolve | not found / could not download. |
| gledo | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glee | ✅ clean |  |
| glee_gd | ✅ clean |  |
| gleeam_code | ✅ clean |  |
| gleebor | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleedoc | ✅ clean |  |
| gleem | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleemenu | ✅ clean |  |
| gleenix | ✅ clean |  |
| gleepl | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleeps | ✅ clean |  |
| gleeps_dev_tools | ✅ clean |  |
| gleeps_stdlib | ⏭️ skip · resolve | not found / could not download. |
| gleerup | ✅ clean |  |
| gleescript | ✅ clean |  |
| gleesend | ✅ clean |  |
| gleeth | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleetube | ✅ clean |  |
| gleeunit | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleewhois | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleez | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleither | ✅ clean |  |
| glelm | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glemcached | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glemini | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glemo | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glemplate | ✅ clean |  |
| glemtext | ✅ clean |  |
| glen | ✅ clean |  |
| glen_node | ✅ clean |  |
| glency | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glendix | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glentities | ✅ clean |  |
| glenv | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glenvy | ✅ clean |  |
| gleojson | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glepack | ✅ clean |  |
| glerd | ✅ clean |  |
| glerd_json | ✅ clean |  |
| glerd_valid | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glerm | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleroglero | ✅ clean |  |
| glerror | ✅ clean |  |
| glesha | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glesha2 | ⏭️ skip · resolve | not found / could not download. |
| glethers | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glevatar | ✅ clean |  |
| glevenshtein | ✅ clean |  |
| glex | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glexec | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glexer | ✅ clean |  |
| glexif | ✅ clean |  |
| gleyre | ✅ clean |  |
| glib | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gliberapay | ✅ clean |  |
| glibsql | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glidicon | ✅ clean |  |
| glidna | ✅ clean |  |
| gliew | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gliff | ✅ clean |  |
| glight | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glimit | ✅ clean |  |
| glimiter | ✅ clean |  |
| glimmer | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glimp | ✅ clean |  |
| glimpse | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glimpse_log | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glimr | ✅ clean |  |
| glimr_auth | ✅ clean |  |
| glimr_postgres | ✅ clean |  |
| glimr_redis | ✅ clean |  |
| glimr_sqlite | ✅ clean |  |
| glimra | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glimt | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glindex | ✅ clean |  |
| glindo | ✅ clean |  |
| gling | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glink | ✅ clean |  |
| glint | ✅ clean |  |
| glinter | ✅ clean |  |
| glip | ✅ clean |  |
| glipt | ✅ clean |  |
| glisbn | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glisdigit | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glisp | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glisten | 🔧 fixed | `Socket` (local alias) vs `InternalSocket` (`type Socket as InternalSocket` import). Fixed: renamed type imports hydrate to their origin name (`9e5833b`). |
| glistix_birl | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glistix_gleeunit | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glistix_json | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glistix_nix | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glistix_stdlib | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glitch | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glite | ✅ clean |  |
| glitr | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glitr_convert | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glitr_convert_cake | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glitr_convert_sql | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glitr_lustre | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glitr_wisp | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glitzer | ✅ clean |  |
| gliua | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glixir | ✅ clean |  |
| glizzy | ✅ clean |  |
| gllm | ✅ clean |  |
| glm_cidr | ✅ clean |  |
| glm_encrypted_file | ✅ clean |  |
| glm_freebsd | ✅ clean |  |
| glm_vault | ✅ clean |  |
| global_value | ✅ clean |  |
| globe | ✅ clean |  |
| globlin | ✅ clean |  |
| globlin_fs | ✅ clean |  |
| glodbc | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glog | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glogg | ✅ clean |  |
| glome | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gloml | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glomp | ✅ clean |  |
| glon | ✅ clean |  |
| gloo | 🔧 fixed | a record reached through a helper in another module (`schema.users().decoder`, `Table` from `gloo/schema`) failed field access because an alias collision evicted the origin module; resolve accessors through the transitive interface graph (`ce69a55`). |
| gloom | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gloop | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glopenai | ✅ clean |  |
| gloq | ✅ clean |  |
| glor | ✅ clean |  |
| glorage | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glormat | ✅ clean |  |
| gloss | ✅ clean |  |
| glotel | ✅ clean |  |
| glove | ✅ clean |  |
| glow | ✅ clean |  |
| glow_auth | ✅ clean |  |
| glqr | ✅ clean |  |
| glriff | ✅ clean |  |
| glrss_parser | ✅ clean |  |
| glua | ✅ clean |  |
| glubs | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glubsub | ✅ clean |  |
| glucose | ✅ clean |  |
| glue | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glugify | ✅ clean |  |
| gluid | ✅ clean |  |
| glum | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gluon | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glupbit | ✅ clean | was glance kind A via its kryptos `der` dependency (bit-array pattern segment size arithmetic); parses since glance 7.0.0. |
| gluple | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gluri | ✅ clean |  |
| glurp6 | ✅ clean |  |
| glv8 | ✅ clean |  |
| glwav | ✅ clean |  |
| glx | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glychee | ✅ clean |  |
| glyn | ✅ clean |  |
| glyph | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glyph_codegen | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glypst | ⏭️ skip · resolve | not found / could not download. |
| glzoneinfo | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gmsg | ✅ clean |  |
| gmysql | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| go_over | ✅ clean |  |
| gond | ✅ clean |  |
| goose | ✅ clean |  |
| gopenai | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gorrion | ✅ clean |  |
| gose | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gossamer | ✅ clean |  |
| gpkm | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gpop | ✅ clean |  |
| gpsd_json | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gpxb | ✅ clean |  |
| gquery | ✅ clean |  |
| graded | ✅ clean |  |
| grammy | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gramps | ✅ clean | earlier `Header` error was a missing `gleam_http` dependency, not a girard bug. |
| graph | ✅ clean |  |
| grille_pain | ✅ clean |  |
| gripe | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| grom | ✅ clean |  |
| grom_stratus | ✅ clean |  |
| group_registry | ✅ clean |  |
| gs | 🔧 fixed | an annotated actor handler lambda `fn(state, msg: Message(a, b)) -> Next(_, Message(a, b))`: girard hydrated each annotation independently, so the param's `a` and the return's `a` drifted to distinct vars since the body left the returned message type free. Fixed: share one fresh var per annotation type-variable name across a lambda's params and return (`c385042`). |
| gserde | ✅ clean |  |
| gsiphash | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gsmtp | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gssg | ✅ clean |  |
| gstripe | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gsv | ✅ clean |  |
| gtabler | ✅ clean |  |
| gtemplate | ✅ clean |  |
| gtempo | ✅ clean |  |
| gtfs_gleam | ✅ clean |  |
| gtfs_rt_nyct | ✅ clean |  |
| gtransducer | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gts | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gtui | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gtz | ✅ clean |  |
| gu | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| guddle | ✅ clean |  |
| gulid | ✅ clean |  |
| gva | ✅ clean |  |
| gvarint | ✅ clean |  |
| gwg_pathfinding | ✅ clean |  |
| gwg_rng | ✅ clean |  |
| gwi | ✅ clean |  |
| gwitch | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gwr | ✅ clean |  |
| gwt | ✅ clean |  |
| gxid | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gxml | ⏭️ skip · resolve | not found / could not download. |
| gxyz | ✅ clean |  |
| gzlib | ✅ clean |  |
| gzxcvbn | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gzxcvbn_common | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gzxcvbn_en | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| h2_frame | ✅ clean | was glance kind A (arithmetic in a bit-array *pattern* segment size `pad_length:size(8 * padded)`); parses since glance 7.0.0. |
| halo | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| handles | ✅ clean |  |
| handles_foxed | ✅ clean |  |
| hanguleam | ✅ clean |  |
| hardcache | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| hello_joe | ✅ clean |  |
| hexdocs_offline | ✅ clean |  |
| high_mountains | ✅ clean |  |
| hoist | ✅ clean |  |
| honk | ✅ clean |  |
| houdini | ✅ clean |  |
| howdy | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| howdy_authentication_cookies | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| howdy_uuid | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| hstack | ✅ clean |  |
| htmb | ✅ clean |  |
| htmgrrrl | ✅ clean |  |
| html_components | ✅ clean |  |
| html_dsl | ✅ clean |  |
| html_lustre_converter | ✅ clean |  |
| html_parser | ✅ clean |  |
| htmz | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| http_server_mock | ✅ clean |  |
| http_server_mock_erlang | ✅ clean |  |
| http_server_mock_js | ✅ clean |  |
| httpp | ✅ clean |  |
| hug | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| humanise | ✅ clean |  |
| humanize | ✅ clean |  |
| hx | ✅ clean |  |
| hypersig | ✅ clean |  |
| hyphenation | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| idb | ✅ clean |  |
| ids | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| ieee_float | ✅ clean |  |
| illustrious | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| immutable_lru | ✅ clean |  |
| in | ✅ clean |  |
| inertia_wisp | ✅ clean |  |
| inertia_wisp_ssr | ✅ clean |  |
| infiniyield | ✅ clean |  |
| inlay | ✅ clean |  |
| input | ✅ clean |  |
| integer_complexity | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| interior | ✅ clean |  |
| intldate | ✅ clean |  |
| ior | ✅ clean |  |
| iox | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| iso_8859 | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| iterators | ✅ clean |  |
| iv | ✅ clean |  |
| ivy | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| jackson | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| jasper | ✅ clean |  |
| javascript_dom_parser | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| javascript_mutable_reference | ✅ clean |  |
| jbs | ⏭️ skip · resolve | not found / could not download. |
| jelly | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| jokeapi | ✅ clean |  |
| jot | 🔧 fixed | `"a" as c <> rest` string-prefix pattern dropped the prefix `as` binding → `c` unbound. Fixed in `PatternConcatenate` (`1cfb3a2`). |
| jot_to_lustre | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| jotkey | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| js_parser | ✅ clean |  |
| jscheam | ✅ clean |  |
| json_blueprint | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| json_canvas | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| json_typedef | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| json_value | ✅ clean |  |
| jsonlogic | ✅ clean |  |
| jsonrpc | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| jsonrpcx | ✅ clean |  |
| julienne | ✅ clean |  |
| juno | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| just | ✅ clean |  |
| justin | ✅ clean |  |
| kafein | ✅ clean |  |
| kata | ✅ clean |  |
| kata_env | 🔧 fixed | `schema.decode(schema, value)` where a `schema` parameter shadows the `kata/schema` module alias and `Schema` is `opaque`: the opaque `decode` field (1-arg) is inaccessible externally, so the module's 2-arg `decode` function must win. girard exported opaque types' accessors, so the callable-field rule picked the 1-arg field → `wrong number of arguments`. Fixed: don't expose opaque types' accessors beyond their module (`8b4b07a`). |
| kata_form | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| kata_json | 🔧 fixed | same opaque-field-vs-module-call case as kata_env (kata's opaque `Schema` with a `decode` field beside a `decode` function). Fixed by not exposing opaque types' accessors beyond their module (`8b4b07a`). |
| keccak_gleam | ✅ clean |  |
| keyboard_shortcuts | ✅ clean |  |
| keystore | ✅ clean |  |
| kicad_sexpr | 🔧 fixed | a parser combinator's generic var pinned to a concrete type (`Result(#(Symbol, ...))` vs `Result(#($0, ...))`). Fixed by rigid type variables (`7d7eab0`). |
| kick | ✅ clean |  |
| kielet | ✅ clean |  |
| kielet_gen | ✅ clean |  |
| kindly | ✅ clean |  |
| kirala_bbmarkdown | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| kirala_l4u | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| kirala_markdown | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| kitazith | ✅ clean |  |
| kitten | ✅ clean |  |
| klubok_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| kmh | ✅ clean |  |
| knit_string | ✅ clean |  |
| kreator | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| kryptos | ✅ clean | was glance kind A (`kryptos/internal/der` arithmetic in a bit-array *pattern* segment size `bytes-size(len - 1)`); parses since glance 7.0.0. |
| kv_sessions | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| kv_sessions_postgres_adapter | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| kvite | ✅ clean |  |
| lamb | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lancaster_stemmer | ✅ clean | was glance kind B (string-prefix concat with discarded rest, `"a" as letter <> _`); parses since glance 6.1.0. |
| lang | ✅ clean |  |
| langfuse_client | ✅ clean |  |
| lanyard | ✅ clean |  |
| lap | ✅ clean |  |
| lattice_core | ✅ clean |  |
| lattice_counters | ✅ clean |  |
| lattice_crdt | ✅ clean |  |
| lattice_maps | ✅ clean |  |
| lattice_presence | ✅ clean |  |
| lattice_registers | ✅ clean |  |
| lattice_sets | ✅ clean |  |
| lazy_const | ✅ clean |  |
| le_ids | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| legos | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lenient_parse | ✅ clean |  |
| leviathan | ✅ clean |  |
| libero | ✅ clean |  |
| libsql | ✅ clean |  |
| libsql_gleam | ✅ clean |  |
| lifeguard | ✅ clean |  |
| lightbulb | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lightspeed | ✅ clean |  |
| lily | 🔧 fixed | a JavaScript-targeted package: `ServerHandle`/topic-handle type aliases are defined per `@target`, so typing them as Erlang mismatched the compiler on every expression using them (plus a module-vs-field arity error in `lily/topic`). Fixed: honor `@target` for both targets, reading the package target from gleam.toml (`0671d7d`); callable-field shadowing (`6d5006f`). |
| lite_fs | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| llmgleam | ✅ clean |  |
| loan | ✅ clean |  |
| local_time_utils | ✅ clean |  |
| logging | ✅ clean |  |
| lorem_ipsum | ✅ clean |  |
| lotta | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lucid | ✅ clean |  |
| lucide_lustre | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| luciole | ✅ clean |  |
| lumenmail | ✅ clean |  |
| lumi | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| luminite | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre | 🔧 fixed | multiple: inferred-variant field access (`Element.attributes`), multi-variant record update, cross-module generalization (`74a3278`); `cache.events(cache)` module-vs-field by call position (`8693b66`). |
| lustre_alpine | ⏭️ skip · resolve | not found / could not download. |
| lustre_animation | ✅ clean |  |
| lustre_carousel | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_dev_tools | 🔧 fixed | `import gleam.{Error as Err}` (via polly) — prelude module not resolvable (`07129a2`); `string.trim` qualified access wrongly grouped `flag`/`string` → `Int vs String` (`3209cb8`/`656e830`). |
| lustre_hash_state | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_http | ⏭️ skip · build |  |
| lustre_http_lib | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_hx | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_kakaomap | ✅ clean |  |
| lustre_limiter | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_omnistate | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_pipes | ✅ clean |  |
| lustre_platform | ⏭️ skip · resolve | not found / could not download. |
| lustre_platform_opentui | ⏭️ skip · resolve | not found / could not download. |
| lustre_portal | ✅ clean |  |
| lustre_prefab | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_routed | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_ssg | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_stylish | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_tauri | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_touch_events | ✅ clean |  |
| lustre_transition | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_ui | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_virtual_list | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_websocket | ⏭️ skip · build |  |
| lustremail | ⏭️ skip · resolve | not found / could not download. |
| lww_register | ✅ clean |  |
| lzf_gleam | ✅ clean |  |
| m25 | ✅ clean |  |
| m3e | ✅ clean |  |
| mala | ✅ clean |  |
| malgleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| mapped | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| marceau | ✅ clean |  |
| marmot | ✅ clean |  |
| mascarpone | ✅ clean |  |
| mat | ⏭️ skip · build |  |
| matrix_gleam | ✅ clean |  |
| maud | 🔧 fixed | two bugs: `let assert Delim(..) = x` didn't narrow `x` to the variant, so `x.len` failed (`NoSuchField`); and a `components` parameter shadowing the `components` module alias resolved `components.hr()` to the module's `hr` function not the param's callable `hr` field (arity mismatch). Fixed: let-pattern variant narrowing + callable-field shadowing in call position (`6d5006f`). |
| mcp_client | ✅ clean |  |
| mcp_toolkit | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| meadow | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| melon | ✅ clean |  |
| memo_gleam | ✅ clean |  |
| mendix_widget_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| mendraw | ✅ clean |  |
| messua | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| metamon | ✅ clean |  |
| midas | ✅ clean |  |
| midas_beam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| midas_browser | ✅ clean |  |
| midas_node | ✅ clean |  |
| midas_sdk | ✅ clean |  |
| migrant | ✅ clean |  |
| mimetype | ✅ clean |  |
| mineflayer | ✅ clean |  |
| miniflare | ✅ clean |  |
| miniflux_sdk | ✅ clean |  |
| minigen | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| mist | 🔧 fixed | `compression.deflate` module-vs-field (`8693b66`); `import gleam/http as _ghttp` discarded alias shadowed `mist/internal/http` (`1b35463`); exponential transitive re-inference hang fixed by interface memoization (`bcd20f4`). |
| mist_reload | ✅ clean |  |
| mochi | ✅ clean |  |
| mockth | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| modem | ✅ clean |  |
| mon | ⏭️ skip · resolve | not found / could not download. |
| money_pattern | ✅ clean |  |
| monies | ✅ clean |  |
| monks_of_style | ✅ clean |  |
| mork | ✅ clean |  |
| mork_to_lustre | ✅ clean |  |
| morse_code_translator | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| morsey | ✅ clean |  |
| mote | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| mug | ✅ clean |  |
| multiformats | ✅ clean |  |
| multipart_form | ✅ clean |  |
| multipartkit | ✅ clean |  |
| mumu | ✅ clean |  |
| mungo | ⏭️ skip · build |  |
| murmur3a | ✅ clean |  |
| mut_cell | ✅ clean |  |
| mysig | ✅ clean |  |
| nakai | ✅ clean |  |
| nanoworker | ✅ clean |  |
| nbeet | ✅ clean |  |
| neon | ✅ clean |  |
| nephrotoma | ✅ clean |  |
| nerf | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| nessie | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| nessie_2 | ✅ clean |  |
| nessie_cluster | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| netlify | ✅ clean |  |
| netpbm | ✅ clean |  |
| netstring | ✅ clean |  |
| next_door | ✅ clean |  |
| ngs | ✅ clean |  |
| nibble | ✅ clean |  |
| niji | ✅ clean |  |
| nimiq_address | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| nimiq_blake2b | ✅ clean |  |
| nimiq_bls | ✅ clean |  |
| nimiq_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| nimiq_rpc | ✅ clean |  |
| nimiq_serde | ✅ clean |  |
| node_pg | ✅ clean |  |
| node_socket_client | ✅ clean |  |
| node_tags | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| non_empty_list | ✅ clean |  |
| nori | ✅ clean |  |
| novdom | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| novdom_dev_tools | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| novdom_testing | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| oas | ✅ clean |  |
| oas_generator | ✅ clean |  |
| oas_generator_utils | ✅ clean |  |
| oaspec | ✅ clean |  |
| oaspec_fetch | ✅ clean |  |
| oaspec_httpc | ✅ clean |  |
| observatory | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| ocular | ✅ clean |  |
| odysseus | ✅ clean |  |
| off_topic | ✅ clean |  |
| og_image | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| ogre | ✅ clean |  |
| okay | ✅ clean |  |
| olive | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| ollama_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| omnimessage_lustre | 📝 note | Same confirmed oracle-numbering artifact as prng: girard reports the resolved type (`#($0, Effect($1))`) where the oracle numbers a reference-node variable distinctly (`#($2, ...)`). `lustre.application` ties `compose`'s returned update fn's input/output model, so the tie is real and girard is correct. |
| omnimessage_server | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| on | ✅ clean |  |
| onigleam | ✅ clean |  |
| opaq | ⏭️ skip · resolve | not found / could not download. |
| open_color | ✅ clean |  |
| open_props | ✅ clean |  |
| opener | ✅ clean |  |
| openfeature | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| opengleametry | ✅ clean |  |
| opengleametry_test | ✅ clean |  |
| openrouter_client | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| operating_system | ✅ clean |  |
| opt_args_with_defs_for_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| optimist | ✅ clean |  |
| or_error | ✅ clean |  |
| orbital | ✅ clean |  |
| ordered_dict | ✅ clean |  |
| ormlette | ⏭️ skip · resolve | not found / could not download. |
| oteap | ✅ clean |  |
| outcome | ✅ clean |  |
| outil | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| outkeep | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| owoify_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| p5js_gleam | ✅ clean |  |
| pack | ✅ clean |  |
| packkit | ✅ clean |  |
| paddlefish | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| paint | ✅ clean |  |
| palabres | ✅ clean |  |
| palabres_wisp | ✅ clean |  |
| palindrome | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| panel | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| parallel_map | ⏭️ skip · build | uses the old `gleam/otp/actor` API (`actor.Stop`/`actor.Next`), incompatible with the resolved gleam_otp. |
| parrot | ✅ clean |  |
| parsed_it | ✅ clean |  |
| parser_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| parsley | ✅ clean |  |
| party | ✅ clean |  |
| parz | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| passwd_gen | ⏭️ skip · resolve | not found / could not download. |
| pathern | ✅ clean |  |
| pb_lite | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| pcl | ✅ clean |  |
| pearl | ✅ clean |  |
| pears | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| pegasus_crypto | ✅ clean |  |
| peggy | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| persevero | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| pevensie | ✅ clean |  |
| pevensie_postgres | ✅ clean |  |
| pevensie_redis | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| pg_value | ✅ clean |  |
| pgl | ✅ clean |  |
| pgo | ✅ clean |  |
| pharos | ✅ clean |  |
| phonetic_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| phony | ✅ clean |  |
| phosphor_lustre | ✅ clean |  |
| pickle | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| pify | ✅ clean |  |
| pika_id | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| pine | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| pink | ✅ clean |  |
| pinkdf2 | ✅ clean |  |
| platform | ✅ clean |  |
| playground | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| plex_pin_auth | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| plinth | ✅ clean |  |
| plinth_cloudflare | ✅ clean |  |
| plume | ✅ clean |  |
| plunk | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| plushie_gleam | ✅ clean |  |
| pngleam | ✅ clean | was a glance bit-array segment parse gap (`<<chunk:bytes-8192, rest:bits>>`, `<<bit_array.byte_size(data):32, ..>>`); parses since glance 7.0.0. |
| pocket_watch | ✅ clean |  |
| pocketenv | ✅ clean |  |
| pog | ✅ clean |  |
| pojo | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| pokemon_names | ✅ clean |  |
| pollux | ✅ clean |  |
| polly | 🔧 fixed | dep of lustre_dev_tools; `import gleam.{Error as Err}` prelude import — see lustre_dev_tools (`07129a2`). |
| pona | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| pontil | ✅ clean |  |
| pontil_build | ✅ clean |  |
| pontil_context | ✅ clean |  |
| pontil_core | ✅ clean |  |
| pontil_platform | ✅ clean |  |
| pontil_summary | ✅ clean |  |
| popcicle | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| poreader | ✅ clean |  |
| porter_stemmer | ✅ clean |  |
| postgleam | ✅ clean |  |
| postglide | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| postgresql_protocol | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| pprint | ✅ clean |  |
| precious | ✅ clean |  |
| prequel | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| presentable_soup | ✅ clean |  |
| pretty_diff | 🔧 fixed | annotated generic vars pinned to `Dynamic` (`Dict($0, Diff)` shown as `Dict(Dynamic, Diff)`). Fixed by rigid type variables (`7d7eab0`). |
| priorityq | ✅ clean |  |
| prng | 📝 note | **Confirmed oracle artifact, girard correct.** girard infers the `fixed_size_dict` reference as `... -> Generator(Dict($0, $1))` (Dict tied to the generators) vs the oracle's `Dict($2, $3)`. Proven: the patched compiler *rejects* `fixed_size_dict(int(0,1), int(0,1), 5)` (= `Generator(Dict(Int, Int))`) assigned to `Generator(Dict(Bool, Float))` — so the type genuinely ties Dict to the generators. The oracle's per-expression export numbers the *reference node*'s variable cells with fresh ids; the call result `fixed_size_dict(...)` itself is `Dict($0, $1)` (tied) in both. |
| problem | ✅ clean |  |
| probly | ✅ clean |  |
| process_file | ✅ clean |  |
| process_waiter | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| processgroups | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| promgleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| promptly | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| protobin | ✅ clean |  |
| protozoa | ✅ clean |  |
| protozoa_dev | ✅ clean |  |
| psg | ✅ clean |  |
| psl | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| pturso | ✅ clean |  |
| pubgrub | ✅ clean |  |
| publicsuffix_gleam | ⏭️ skip · resolve | not found / could not download. |
| puddle | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| punycode | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| qcheck | ✅ clean |  |
| qcheck_gleeunit_utils | ✅ clean |  |
| qol_gleam | ✅ clean |  |
| qrkit | ✅ clean |  |
| qs | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| quaterni | ✅ clean |  |
| quaternion | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| queryb | ✅ clean |  |
| question | ✅ clean |  |
| rad | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| rada | ✅ clean |  |
| radiant | ✅ clean |  |
| radiate | ✅ clean |  |
| radish | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| radish_fork | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| rally | ✅ clean |  |
| ramble | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| randomlib | ✅ clean |  |
| ranged_int | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| ranger | ✅ clean |  |
| rank | ✅ clean |  |
| rasa | ✅ clean |  |
| ratioed | ✅ clean |  |
| rcade_inputs | ✅ clean |  |
| react_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| reactive_signal | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| ream | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| rectify | ✅ clean |  |
| recursive | ✅ clean |  |
| redact | ✅ clean |  |
| redraw | ✅ clean | JS-target package. |
| redraw_batteries | ✅ clean |  |
| redraw_dom | ✅ clean |  |
| ref | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| reference_this | ✅ clean |  |
| refrakt | ✅ clean |  |
| reki | ✅ clean |  |
| releam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| rememo | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| rememo_erlang | ✅ clean |  |
| rememo_javascript | ✅ clean |  |
| remote_data | ✅ clean |  |
| render_md | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| repeatedly | ✅ clean |  |
| report | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| rexen | ✅ clean |  |
| rizzo | ⏭️ skip · resolve | not found / could not download. |
| roar | ✅ clean |  |
| rockbox | ✅ clean |  |
| roman_gleam | ✅ clean |  |
| rosetta | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| roundabout | ✅ clean |  |
| rsa_keys | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| rsvp | ✅ clean |  |
| runetracer | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| sara | ✅ clean |  |
| savoiardi | ✅ clean |  |
| scaffold_gleam | ✅ clean |  |
| scamper | ✅ clean |  |
| sceall | ✅ clean |  |
| scrapbook | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| scriptorium | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| search_algorithms_gleam | 🔧 fixed | `get_steps` in `internal/generalized_search` returned `List(#(Int, $2))` vs the compiler's `$1`. Root cause (not the alias — verified by inlining): variant narrowing is keyed by variable name, and the outer `let search_state = SearchState(..)` recorded a narrowing for `search_state` that the inner lambda's parameter (also named `search_state`) inherited, so `search_state.paths` read the outer value's field, untied from the parameter. Fixed: `bind_value` clears stale variant narrowing for a shadowed name (`ee9fcb0`). |
| secp256k1_gleam | ✅ clean |  |
| sendgriddle | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| sextant | ✅ clean |  |
| shakespeare | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| shamir | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| shcribe | ✅ clean |  |
| sheen | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| shelf | ✅ clean |  |
| shellout | ✅ clean |  |
| shimmer | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| shimmy | ✅ clean |  |
| shine_tree | 🔧 fixed | a finger tree: `fold_l`/`fold_l_root` are mutually recursive, `fold_l_root` calling `fold_l` at `ShineTree(Node(u))` with an unannotated accumulator. NOT polymorphic recursion (the compiler rejects that too); the compiler types it by letting a reference see the type a sibling's already-inferred body has settled (shared mutable cells). girard froze SCC schemes up front, so the absorbed accumulator leaked a rigid into a sibling → `type mismatch: a vs a`, failing the module. Fixed: mark component members `live` and resolve a reference to one through the current substitution before instantiating, typing members with an unannotated part first (`60e3223`). The 5 residual diffs are the prng/omnimessage oracle-numbering artifact — girard is the more-resolved, correct view. |
| shiny | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| shopify_draft_proxy | ✅ clean |  |
| shore | 🔧 fixed | `let focused = FocusedInput(..)` then `focused.offset` — variant narrowing from a constructor in a let binding (`1796ffb`). |
| shork | ✅ clean |  |
| showtime | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| sidereal | ✅ clean |  |
| sift | ✅ clean |  |
| sigmal | ✅ clean |  |
| signal | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| signal_pgo | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| silk | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| simple_pubsub | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| simplejson | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| simplifile | ✅ clean |  |
| singleflight | ✅ clean |  |
| singularity | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| sixtytwo | ✅ clean |  |
| sketch | ✅ clean | JS-target package. |
| sketch_css | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| sketch_lustre | ✅ clean |  |
| sketch_lustre_experimental | ⏭️ skip · resolve | not found / could not download. |
| sketch_redraw | ✅ clean |  |
| skir_client | ✅ clean |  |
| slabs | ✅ clean |  |
| slack_webhook_client | ✅ clean |  |
| slackin | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| slate | ✅ clean |  |
| smail | ✅ clean |  |
| smalto | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| smalto_lustre | ✅ clean |  |
| smalto_lustre_themes | ✅ clean |  |
| smol | ✅ clean |  |
| smut | ✅ clean |  |
| snag | ✅ clean |  |
| snowball_stemmer | ✅ clean |  |
| snowglake | ✅ clean |  |
| snowgleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| sol | ✅ clean |  |
| solc | ✅ clean |  |
| sonatina | ✅ clean |  |
| sorbet | ✅ clean |  |
| spacetraders_api | ✅ clean |  |
| spacetraders_api_fetch | ✅ clean |  |
| spacetraders_api_httpc | ✅ clean |  |
| spacetraders_models | ✅ clean |  |
| spacetraders_sdk | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| sparkle | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| sparkleplug | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| sparklinekit | ✅ clean |  |
| sparkling | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| sparx | ✅ clean |  |
| spatial | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| spectator | ✅ clean |  |
| speedbump | ⏭️ skip · resolve | not found / could not download. |
| spell_out | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| spinner | ✅ clean |  |
| splash | ⏭️ skip · resolve | not found / could not download. |
| splines | ✅ clean |  |
| splitter | ✅ clean |  |
| spoke | ⏭️ skip · resolve | not found / could not download. |
| spoke_core | ✅ clean |  |
| spoke_mqtt | ✅ clean |  |
| spoke_mqtt_actor | ✅ clean |  |
| spoke_mqtt_js | ✅ clean |  |
| spoke_packet | ✅ clean |  |
| spoke_tcp | ✅ clean |  |
| spotify_client | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| spotless | ✅ clean |  |
| sprinkle | ✅ clean |  |
| sprocket | ✅ clean |  |
| sprocket_mist | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| sqid | ✅ clean |  |
| sqlc_gen_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| sqlight | ✅ clean |  |
| sqlode | ✅ clean |  |
| squall | ✅ clean |  |
| squeal | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| squirrel | 🔧 fixed | `QueryFileHasInvalidName(file:, reason: _, suggested_name:)` — labelled function-capture hole placed positionally instead of by label (`ab80771`). |
| squirtle | ✅ clean |  |
| ssevents | ✅ clean |  |
| ssg | ⏭️ skip · resolve | not found / could not download. |
| stacky | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| staff_ai | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| star | ✅ clean |  |
| stardate | ✅ clean |  |
| starfeeds | ✅ clean |  |
| storail | ✅ clean |  |
| tempo | ⏭️ skip · build |  |
| term_size | ✅ clean |  |
| tobble | ✅ clean |  |
| tom | ✅ clean |  |
| tote | ✅ clean |  |
| valid | ✅ clean |  |
| vleam | ✅ clean | JS-target package. |
| wisp | ✅ clean |  |
| xmleam | ⏭️ skip · build |  |
| youid | ✅ clean |  |
