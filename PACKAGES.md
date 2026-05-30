# Differential testing — package status

Tracks hex.pm packages run through girard's differential oracle. Each row is the
result of comparing girard's per-expression output to the real compiler's, using
a consistent, hex-resolved dependency closure:

```sh
bash scripts/sweep.sh <package>
```

`sweep.sh` resolves the package's full transitive dependency tree, exports the
oracle with the package as the build root, syncs those exact dependency versions
into `build/packages`, and runs `gleam run -m girard/diff <package> <oracle>`.

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
| acrostic | ⏭️ skip · resolve | not found / could not download. |
| act | ✅ clean |  |
| actorx | ⏭️ skip · resolve | not found / could not download. |
| acumen | 📝 note | All modules error `unbound variable: der`. Root cause: its dep `kryptos/internal/der` fails to **parse** in glance — a bit-array *pattern* segment with an arithmetic size, `<<v:bytes-size(len - 1)>>` (glance rejects the `-`; bare vars and construction-side arithmetic parse fine). A glance limitation, not girard inference; cascades to every module importing `der`. |
| adglent | ⏭️ skip · resolve | not found / could not download. |
| ag_html | ⏭️ skip · resolve | not found / could not download. |
| aham | ✅ clean |  |
| aide | ✅ clean |  |
| aide_generator | ✅ clean |  |
| akaridb | ✅ clean |  |
| alakazam | ✅ clean |  |
| alpacki | ✅ clean |  |
| amaro | ✅ clean |  |
| amber | ✅ clean |  |
| amf0 | ⏭️ skip · resolve | not found / could not download. |
| amnesiac | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| ankiconnect | ✅ clean |  |
| ansel | ✅ clean |  |
| anthropic_gleam | ✅ clean |  |
| antigone | ✅ clean |  |
| antimonia | ✅ clean |  |
| aoc_2024 | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| aonyx_graph | ⏭️ skip · resolve | not found / could not download. |
| apollo | ⏭️ skip · resolve | not found / could not download. |
| aragorn2 | ⏭️ skip · resolve | not found / could not download. |
| arcana_signals | ⏭️ skip · resolve | not found / could not download. |
| arctic | ⏭️ skip · resolve | not found / could not download. |
| arctic_plugin_diagram | ⏭️ skip · resolve | not found / could not download. |
| argamak | ⏭️ skip · resolve | not found / could not download. |
| argus | ⏭️ skip · resolve | not found / could not download. |
| argv | ✅ clean |  |
| ascii_fold | ⏭️ skip · resolve | not found / could not download. |
| ask | ⏭️ skip · resolve | not found / could not download. |
| assemblyai | ✅ clean |  |
| asset | ✅ clean |  |
| asterix | ✅ clean |  |
| atomb | ✅ clean | earlier `unbound`/over-unification cleared by the call-graph scoping fix (`e915817`). |
| atomic_array | ✅ clean |  |
| atto | ✅ clean |  |
| automata | ✅ clean |  |
| aws4_request | ✅ clean |  |
| aws_api | ⏭️ skip · resolve | not found / could not download. |
| aws_credentials_gleam | ⏭️ skip · resolve | not found / could not download. |
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
| based_sqlite | ⏭️ skip · resolve | not found / could not download. |
| bath | ✅ clean |  |
| battlesnake | ⏭️ skip · resolve | not found / could not download. |
| beach | ✅ clean |  |
| beecrypt | ✅ clean |  |
| beencode | ✅ clean |  |
| benedict | ✅ clean |  |
| bespoke | ✅ clean |  |
| bg_jobs | ⏭️ skip · resolve | not found / could not download. |
| bibi | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| bidict | ✅ clean |  |
| bigben | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| bigdecimal | ✅ clean |  |
| bigi | ✅ clean |  |
| binary_search | ✅ clean |  |
| birch | ✅ clean |  |
| birdie | 📝 note | `internal/diagnostic` fails to **parse** — a glance limitation (newer syntax), not girard inference. Cascades to `unbound variable: diagnostic`. |
| birl | ✅ clean |  |
| biscotto | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| bison | ⏭️ skip · build |  |
| bitsandbobs | ✅ clean |  |
| bitty | ✅ clean |  |
| blah | ✅ clean |  |
| blask | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| blimp | ✅ clean |  |
| bliss | ⏭️ skip · resolve | not found / could not download. |
| blogatto | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| blush | ⏭️ skip · resolve | not found / could not download. |
| booklet | ⏭️ skip · resolve | not found / could not download. |
| boyer_moore | ⏭️ skip · resolve | not found / could not download. |
| bravo | ⏭️ skip · resolve | not found / could not download. |
| bread | ⏭️ skip · resolve | not found / could not download. |
| bright | ⏭️ skip · resolve | not found / could not download. |
| brilo | ⏭️ skip · resolve | not found / could not download. |
| brioche | ⏭️ skip · resolve | not found / could not download. |
| brot | ⏭️ skip · resolve | not found / could not download. |
| bseal | ⏭️ skip · resolve | not found / could not download. |
| bsky_comments_widget | ✅ clean |  |
| bucket | ✅ clean |  |
| builder | ✅ clean |  |
| bummer | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| bungibindies | ⏭️ skip · resolve | not found / could not download. |
| bungle | ✅ clean |  |
| butterbee | ⏭️ skip · resolve | not found / could not download. |
| butterbidi | ✅ clean |  |
| butterlib | ⏭️ skip · resolve | not found / could not download. |
| bytes | ✅ clean |  |
| bytesize | ✅ clean |  |
| cachmere | ⏭️ skip · resolve | not found / could not download. |
| cactus | ✅ clean |  |
| caffeine_lang | ✅ clean |  |
| caffeine_query_language | ⏭️ skip · resolve | not found / could not download. |
| cake | ✅ clean |  |
| cake_gleam_pgo | ⏭️ skip · resolve | not found / could not download. |
| cake_gmysql | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| cake_pog | ✅ clean |  |
| cake_shork | ✅ clean |  |
| cake_sqlight | ⏭️ skip · resolve | not found / could not download. |
| caldav_gleam | ⏭️ skip · resolve | not found / could not download. |
| cangaroo | ⏭️ skip · resolve | not found / could not download. |
| capuchin_crypt | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| carotte | ⏭️ skip · resolve | not found / could not download. |
| carpenter | ⏭️ skip · resolve | not found / could not download. |
| casefold | ⏭️ skip · resolve | not found / could not download. |
| casper | ⏭️ skip · resolve | not found / could not download. |
| castor | ⏭️ skip · resolve | not found / could not download. |
| cat | ⏭️ skip · resolve | not found / could not download. |
| category_theory | ⏭️ skip · resolve | not found / could not download. |
| catppuccin | ⏭️ skip · resolve | not found / could not download. |
| cave3dplus | ⏭️ skip · resolve | not found / could not download. |
| cel | ⏭️ skip · resolve | not found / could not download. |
| cell | ⏭️ skip · resolve | not found / could not download. |
| cgi | ⏭️ skip · resolve | not found / could not download. |
| chaplin | ⏭️ skip · resolve | not found / could not download. |
| chatbot | ⏭️ skip · resolve | not found / could not download. |
| check_maybe_div_by_zero | ⏭️ skip · resolve | not found / could not download. |
| checkmark | ⏭️ skip · resolve | not found / could not download. |
| chic | ⏭️ skip · resolve | not found / could not download. |
| child_process | ⏭️ skip · resolve | not found / could not download. |
| chilli | ⏭️ skip · resolve | not found / could not download. |
| chilp | ⏭️ skip · resolve | not found / could not download. |
| chip | ⏭️ skip · resolve | not found / could not download. |
| choire | ⏭️ skip · resolve | not found / could not download. |
| chomp | ⏭️ skip · resolve | not found / could not download. |
| chrobot | ⏭️ skip · resolve | not found / could not download. |
| chrobot_extra | ⏭️ skip · resolve | not found / could not download. |
| chromatic | ⏭️ skip · resolve | not found / could not download. |
| cigogne | 🔧 fixed | `config.dependencies` field access on a local constant was dropped as a dependency edge → const inferred too late → unbound. Fixed: references split into values vs field-access qualifiers (`656e830`). |
| circuit | ⏭️ skip · resolve | not found / could not download. |
| circuit_breaker | ✅ clean |  |
| clad | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| clamav_client | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| classify | ⏭️ skip · resolve | not found / could not download. |
| claude_gleam | ✅ clean |  |
| cleam | ⏭️ skip · resolve | not found / could not download. |
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
| comparator | ⏭️ skip · resolve | not found / could not download. |
| compresso | ⏭️ skip · resolve | not found / could not download. |
| conllu | ⏭️ skip · resolve | not found / could not download. |
| contenty | ⏭️ skip · resolve | not found / could not download. |
| context_fp_gleam | ⏭️ skip · resolve | not found / could not download. |
| contour | ⏭️ skip · resolve | not found / could not download. |
| conversation | ✅ clean |  |
| convert | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| convert_http_query | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| convert_json | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| corrosion | ⏭️ skip · resolve | not found / could not download. |
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
| css_select | ⏭️ skip · resolve | not found / could not download. |
| cthulhu | 📝 note | bit-array segment with an arithmetic size (`size(is_dead * 32)`) fails to **parse** in glance — same parser gap as acumen, not girard inference. |
| cuid2_gleam | ✅ clean |  |
| cx | ✅ clean |  |
| cycle | ✅ clean |  |
| cymbal | ✅ clean |  |
| cynthia_websites_mini_client | ⏭️ skip · resolve | not found / could not download. |
| cynthia_websites_mini_server | ⏭️ skip · resolve | not found / could not download. |
| dachshund | ✅ clean |  |
| dag_json | ✅ clean |  |
| dagger_gleam | ✅ clean |  |
| dahlia | ⏭️ skip · resolve | not found / could not download. |
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
| dedent | ⏭️ skip · resolve | not found / could not download. |
| dee | ⏭️ skip · resolve | not found / could not download. |
| defangle | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| defer_g | ⏭️ skip · resolve | not found / could not download. |
| delay | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| delay_times | ⏭️ skip · resolve | not found / could not download. |
| deriv | ⏭️ skip · resolve | not found / could not download. |
| derived | ⏭️ skip · resolve | not found / could not download. |
| dew | ⏭️ skip · resolve | not found / could not download. |
| dewey | ⏭️ skip · resolve | not found / could not download. |
| dice_trio | ⏭️ skip · resolve | not found / could not download. |
| diced | ⏭️ skip · resolve | not found / could not download. |
| differance | ⏭️ skip · resolve | not found / could not download. |
| dig | ⏭️ skip · resolve | not found / could not download. |
| dijkstra | ⏭️ skip · resolve | not found / could not download. |
| dime | ⏭️ skip · resolve | not found / could not download. |
| dinostore | ⏭️ skip · resolve | not found / could not download. |
| directories | ✅ clean |  |
| dirtree | ⏭️ skip · resolve | not found / could not download. |
| dirty_deeds_done_dirt_cheap | ⏭️ skip · resolve | not found / could not download. |
| discord_gleam | ⏭️ skip · resolve | not found / could not download. |
| discord_gleam_stratus | ⏭️ skip · resolve | not found / could not download. |
| distribute | ⏭️ skip · resolve | not found / could not download. |
| dnalg | ⏭️ skip · resolve | not found / could not download. |
| dnd | ✅ clean |  |
| domu | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| dot_env | 🔧 fixed | `simplifile.do_file_info` is declared twice (`@target(erlang)` → `Result(_, FileError)`, `@target(javascript)` → `Result(_, String)`); girard ignored `@target` so the JS one shadowed the Erlang one → `String vs FileError`. Fixed: filter non-Erlang `@target` definitions (`dd501f2`). |
| dotenv_conf | ✅ clean |  |
| dotenv_gleam | ⏭️ skip · resolve | not found / could not download. |
| dove | ⏭️ skip · resolve | not found / could not download. |
| dream | ⏭️ skip · resolve | not found / could not download. |
| dream_config | ⏭️ skip · resolve | not found / could not download. |
| dream_ets | ✅ clean |  |
| dream_http_client | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| dream_json | ✅ clean |  |
| dream_mock_server | ⏭️ skip · resolve | not found / could not download. |
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
| ecoji | ⏭️ skip · resolve | not found / could not download. |
| edit_distance | ✅ clean |  |
| eensy | ⏭️ skip · resolve | not found / could not download. |
| eensy_dev_tools | ⏭️ skip · resolve | not found / could not download. |
| efetch | ⏭️ skip · resolve | not found / could not download. |
| effect | ⏭️ skip · resolve | not found / could not download. |
| either_or | ✅ clean |  |
| embeds | ⏭️ skip · resolve | not found / could not download. |
| emel | ⏭️ skip · resolve | not found / could not download. |
| emojindex | ⏭️ skip · resolve | not found / could not download. |
| emojindex_kitchen | ✅ clean |  |
| emojis | ✅ clean |  |
| ensaimada | ⏭️ skip · resolve | not found / could not download. |
| envie | ✅ clean |  |
| envoker | ✅ clean |  |
| envoy | ✅ clean |  |
| eparch | ✅ clean |  |
| escpos | ✅ clean |  |
| esdee | 🔧 fixed | a local `let try_find = fn(with: fn(_) -> Result(a, Nil), _) {..}` helper applied at two record types; girard treated the local binding as monomorphic. Fixed: generalize a let-bound function over its annotation type variables (`5362dfd`). |
| esgleam | ⏭️ skip · resolve | not found / could not download. |
| espresso | ⏭️ skip · resolve | not found / could not download. |
| espresso_pgo_wrapper | ⏭️ skip · resolve | not found / could not download. |
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
| exercism_test_runner | ⏭️ skip · resolve | not found / could not download. |
| expresso | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| eyg_analysis | ✅ clean |  |
| eyg_compiler | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| eyg_interpreter | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| eyg_ir | ⏭️ skip · resolve | not found / could not download. |
| eyg_parser | ⏭️ skip · resolve | not found / could not download. |
| ezconfig | ⏭️ skip · resolve | not found / could not download. |
| fabulous | ⏭️ skip · resolve | not found / could not download. |
| facet | ⏭️ skip · resolve | not found / could not download. |
| facquest | ⏭️ skip · resolve | not found / could not download. |
| falala | ⏭️ skip · resolve | not found / could not download. |
| falcon | ⏭️ skip · resolve | not found / could not download. |
| fcgi | ⏭️ skip · resolve | not found / could not download. |
| feather | ⏭️ skip · resolve | not found / could not download. |
| feature_flags | ⏭️ skip · resolve | not found / could not download. |
| feiertag | ⏭️ skip · resolve | not found / could not download. |
| felix | ⏭️ skip · resolve | not found / could not download. |
| fetch_event | ⏭️ skip · resolve | not found / could not download. |
| ffmpeg | ⏭️ skip · resolve | not found / could not download. |
| fhir | ⏭️ skip · resolve | not found / could not download. |
| fhir_client_httpc | ⏭️ skip · resolve | not found / could not download. |
| fhir_client_rsvp | ⏭️ skip · resolve | not found / could not download. |
| fibo | ⏭️ skip · resolve | not found / could not download. |
| fiction | ⏭️ skip · resolve | not found / could not download. |
| fiction_env | ⏭️ skip · resolve | not found / could not download. |
| fiction_toml | ⏭️ skip · resolve | not found / could not download. |
| file_streams | ⏭️ skip · resolve | not found / could not download. |
| filepath | ✅ clean |  |
| filespy | ⏭️ skip · resolve | not found / could not download. |
| finanza | ⏭️ skip · resolve | not found / could not download. |
| finch_gleam | ⏭️ skip · resolve | not found / could not download. |
| fio | ⏭️ skip · resolve | not found / could not download. |
| fireball | ⏭️ skip · resolve | not found / could not download. |
| fist | ⏭️ skip · resolve | not found / could not download. |
| flash | ⏭️ skip · resolve | not found / could not download. |
| flixi | ⏭️ skip · resolve | not found / could not download. |
| fluentci | ⏭️ skip · resolve | not found / could not download. |
| fluo | ⏭️ skip · resolve | not found / could not download. |
| fluoresce | ⏭️ skip · resolve | not found / could not download. |
| flwr_oauth2 | ⏭️ skip · resolve | not found / could not download. |
| fmglee | ⏭️ skip · resolve | not found / could not download. |
| fmt | ⏭️ skip · resolve | not found / could not download. |
| for_the_crows | ⏭️ skip · resolve | not found / could not download. |
| form_coder | ⏭️ skip · resolve | not found / could not download. |
| formal | ✅ clean |  |
| format | ⏭️ skip · resolve | not found / could not download. |
| formz | ⏭️ skip · resolve | not found / could not download. |
| formz_lustre | ⏭️ skip · resolve | not found / could not download. |
| formz_nakai | ⏭️ skip · resolve | not found / could not download. |
| formz_string | ⏭️ skip · resolve | not found / could not download. |
| fp | ⏭️ skip · resolve | not found / could not download. |
| fp2 | ⏭️ skip · resolve | not found / could not download. |
| fp2_gleam | ⏭️ skip · resolve | not found / could not download. |
| fp_gl | ⏭️ skip · resolve | not found / could not download. |
| fp_utils | ⏭️ skip · resolve | not found / could not download. |
| frac | ⏭️ skip · resolve | not found / could not download. |
| fractional_indexing | ⏭️ skip · resolve | not found / could not download. |
| fragmentation | ⏭️ skip · resolve | not found / could not download. |
| franz | ⏭️ skip · resolve | not found / could not download. |
| fresnel | ⏭️ skip · resolve | not found / could not download. |
| friendly_id | ⏭️ skip · resolve | not found / could not download. |
| frontmatter | ⏭️ skip · resolve | not found / could not download. |
| fswalk | ⏭️ skip · resolve | not found / could not download. |
| ftpasta | ⏭️ skip · resolve | not found / could not download. |
| functx | ⏭️ skip · resolve | not found / could not download. |
| funsies | ⏭️ skip · resolve | not found / could not download. |
| funtil | ⏭️ skip · resolve | not found / could not download. |
| fused | ⏭️ skip · resolve | not found / could not download. |
| future | ⏭️ skip · resolve | not found / could not download. |
| fyni | ⏭️ skip · resolve | not found / could not download. |
| g18n | ⏭️ skip · resolve | not found / could not download. |
| g18n_dev | ⏭️ skip · resolve | not found / could not download. |
| gacache | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gai | ✅ clean |  |
| galant | ⏭️ skip · resolve | not found / could not download. |
| galchemy | ✅ clean |  |
| gap | ⏭️ skip · resolve | not found / could not download. |
| garnet_tool | ⏭️ skip · resolve | not found / could not download. |
| gary | ✅ clean |  |
| gauth | ✅ clean |  |
| gauzy | ✅ clean |  |
| gel | ⏭️ skip · resolve | source not downloaded. |
| given | 🔧 fixed | self-recursive `partition_loop` using imported constructors wasn't generalized → monomorphic across uses. Fixed: quantified scheme variables treated as opaque in `env_free_vars`. |
| gladvent | ⏭️ skip · build | a transitive `decode` version is broken against the resolved stdlib. |
| glam | ✅ clean |  |
| glance | ✅ clean |  |
| glance_printer | ✅ clean |  |
| gleam_community_ansi | ✅ clean |  |
| gleam_community_colour | ✅ clean |  |
| gleam_community_maths | ✅ clean |  |
| gleam_crypto | ✅ clean |  |
| gleam_deque | ✅ clean |  |
| gleam_erlang | ✅ clean |  |
| gleam_fetch | ✅ clean |  |
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
| gleamy_bench | ✅ clean |  |
| gleamy_structures | ✅ clean |  |
| glearray | ✅ clean |  |
| glector | ✅ clean |  |
| glen | ✅ clean |  |
| glexer | ✅ clean |  |
| glint | ✅ clean |  |
| glinter | ✅ clean |  |
| glisten | 🔧 fixed | `Socket` (local alias) vs `InternalSocket` (`type Socket as InternalSocket` import). Fixed: renamed type imports hydrate to their origin name (`9e5833b`). |
| gluid | ✅ clean |  |
| gramps | ✅ clean | earlier `Header` error was a missing `gleam_http` dependency, not a girard bug. |
| gsv | ✅ clean |  |
| gtempo | ✅ clean |  |
| gxml | ⏭️ skip · resolve |  |
| houdini | ✅ clean |  |
| iv | ✅ clean |  |
| jot | 🔧 fixed | `"a" as c <> rest` string-prefix pattern dropped the prefix `as` binding → `c` unbound. Fixed in `PatternConcatenate` (`1cfb3a2`). |
| justin | ✅ clean |  |
| logging | ✅ clean |  |
| lustre | 🔧 fixed | multiple: inferred-variant field access (`Element.attributes`), multi-variant record update, cross-module generalization (`74a3278`); `cache.events(cache)` module-vs-field by call position (`8693b66`). |
| lustre_dev_tools | 🔧 fixed | `import gleam.{Error as Err}` (via polly) — prelude module not resolvable (`07129a2`); `string.trim` qualified access wrongly grouped `flag`/`string` → `Int vs String` (`3209cb8`/`656e830`). |
| lustre_http | ⏭️ skip · build |  |
| lustre_websocket | ⏭️ skip · build |  |
| marceau | ✅ clean |  |
| mat | ⏭️ skip · build |  |
| mist | 🔧 fixed | `compression.deflate` module-vs-field (`8693b66`); `import gleam/http as _ghttp` discarded alias shadowed `mist/internal/http` (`1b35463`); exponential transitive re-inference hang fixed by interface memoization (`bcd20f4`). |
| modem | ✅ clean |  |
| mug | ✅ clean |  |
| mungo | ⏭️ skip · build |  |
| nakai | ✅ clean |  |
| non_empty_list | ✅ clean |  |
| oas | ✅ clean |  |
| outil | ⏭️ skip · resolve |  |
| parallel_map | ⏭️ skip · build | uses the old `gleam/otp/actor` API (`actor.Stop`/`actor.Next`), incompatible with the resolved gleam_otp. |
| pevensie | ⏭️ skip · resolve |  |
| pgo | ✅ clean |  |
| platform | ✅ clean |  |
| pog | ✅ clean |  |
| polly | 🔧 fixed | dep of lustre_dev_tools; `import gleam.{Error as Err}` prelude import — see lustre_dev_tools (`07129a2`). |
| prng | 📝 note | one expression mismatch at a polymorphic function reference (`fixed_size_dict`): the compiler's signature is tied like girard's; the oracle snapshots the reference pre-unification. girard is correct. |
| qcheck | ✅ clean |  |
| ranger | ✅ clean |  |
| redraw | ✅ clean | JS-target package. |
| repeatedly | ✅ clean |  |
| shellout | ✅ clean |  |
| shore | 🔧 fixed | `let focused = FocusedInput(..)` then `focused.offset` — variant narrowing from a constructor in a let binding (`1796ffb`). |
| simplifile | ✅ clean |  |
| sketch | ✅ clean | JS-target package. |
| snag | ✅ clean |  |
| spinner | ✅ clean |  |
| splitter | ✅ clean |  |
| squirrel | 🔧 fixed | `QueryFileHasInvalidName(file:, reason: _, suggested_name:)` — labelled function-capture hole placed positionally instead of by label (`ab80771`). |
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
