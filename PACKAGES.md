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
| gaveta | ✅ clean |  |
| gbase32_clockwork | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gblake2 | ✅ clean |  |
| gblake3 | ✅ clean |  |
| gbor | ✅ clean |  |
| gbr_disk_log | ⏭️ skip · resolve | not found / could not download. |
| gbr_erl | ✅ clean |  |
| gbr_gh | ⏭️ skip · resolve | not found / could not download. |
| gbr_js | ⏭️ skip · resolve | not found / could not download. |
| gbr_md_lustre | ⏭️ skip · resolve | not found / could not download. |
| gbr_msal | ✅ clean |  |
| gbr_shared | ⏭️ skip · resolve | not found / could not download. |
| gbr_ui | ⏭️ skip · resolve | not found / could not download. |
| gcalc | ✅ clean |  |
| gchess | ⏭️ skip · resolve | not found / could not download. |
| gclog | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gcourier | ⏭️ skip · resolve | not found / could not download. |
| gdo | ✅ clean |  |
| geckolex | ✅ clean |  |
| ged25519 | ✅ clean |  |
| gel | ⏭️ skip · resolve | source not downloaded. |
| gelman | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gemo | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gemqtt | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gen_core_erlang | ⏭️ skip · resolve | not found / could not download. |
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
| gl_wasm | ⏭️ skip · resolve | not found / could not download. |
| glace | ⏭️ skip · resolve | not found / could not download. |
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
| glare | ⏭️ skip · resolve | not found / could not download. |
| glat | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glatch | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glatistics | ✅ clean |  |
| glats | ⏭️ skip · resolve | not found / could not download. |
| glatus | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glaze_basecoat | ✅ clean |  |
| glaze_oat | ✅ clean |  |
| glazed_corn | ✅ clean |  |
| glbencode | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glcode | ⏭️ skip · resolve | not found / could not download. |
| gleaf | ✅ clean |  |
| gleaflet | ✅ clean |  |
| gleam_bitwise | ✅ clean |  |
| gleam_community_ansi | ✅ clean |  |
| gleam_community_colour | ✅ clean |  |
| gleam_community_maths | ✅ clean |  |
| gleam_community_path | ⏭️ skip · resolve | not found / could not download. |
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
| gleamgen | 📝 note | girard pins a phantom type parameter (`Expression(type_.Dynamic)`) where the compiler keeps it polymorphic (`Expression($0)`): girard treats a function signature's type variables as flexible, not rigid/skolemized. A known inference-fidelity gap (rigid type variables), deferred — 34 expression mismatches, all of this shape. |
| gleamix | ✅ clean |  |
| gleamlz_string | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleamoire | ⏭️ skip · resolve | not found / could not download. |
| gleamql | ⏭️ skip · resolve | not found / could not download. |
| gleamrpc | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleamrpc_http_client | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleamrpc_http_server | ⏭️ skip · resolve | not found / could not download. |
| gleamstar | ✅ clean |  |
| gleamstral | ✅ clean |  |
| gleamsver | ✅ clean |  |
| gleamx | ⏭️ skip · resolve | not found / could not download. |
| gleamy_bench | ✅ clean |  |
| gleamy_lights | ✅ clean |  |
| gleamy_structures | ✅ clean |  |
| gleamy_zipper | ✅ clean |  |
| gleamyshell | ✅ clean |  |
| glean | ⏭️ skip · resolve | not found / could not download. |
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
| glee_gd | ⏭️ skip · resolve | not found / could not download. |
| gleeam_code | ✅ clean |  |
| gleebor | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleedoc | ✅ clean |  |
| gleem | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gleemenu | ⏭️ skip · resolve | not found / could not download. |
| gleenix | ⏭️ skip · resolve | not found / could not download. |
| gleepl | ⏭️ skip · resolve | not found / could not download. |
| gleeps | ⏭️ skip · resolve | not found / could not download. |
| gleeps_dev_tools | ⏭️ skip · resolve | not found / could not download. |
| gleeps_stdlib | ⏭️ skip · resolve | not found / could not download. |
| gleerup | ⏭️ skip · resolve | not found / could not download. |
| gleescript | ⏭️ skip · resolve | not found / could not download. |
| gleesend | ⏭️ skip · resolve | not found / could not download. |
| gleeth | ⏭️ skip · resolve | not found / could not download. |
| gleetube | ⏭️ skip · resolve | not found / could not download. |
| gleeunit | ⏭️ skip · resolve | not found / could not download. |
| gleewhois | ⏭️ skip · resolve | not found / could not download. |
| gleez | ⏭️ skip · resolve | not found / could not download. |
| gleither | ⏭️ skip · resolve | not found / could not download. |
| glelm | ⏭️ skip · resolve | not found / could not download. |
| glemcached | ⏭️ skip · resolve | not found / could not download. |
| glemini | ⏭️ skip · resolve | not found / could not download. |
| glemo | ⏭️ skip · resolve | not found / could not download. |
| glemplate | ⏭️ skip · resolve | not found / could not download. |
| glemtext | ⏭️ skip · resolve | not found / could not download. |
| glen | ✅ clean |  |
| glen_node | ⏭️ skip · resolve | not found / could not download. |
| glency | ⏭️ skip · resolve | not found / could not download. |
| glendix | ⏭️ skip · resolve | not found / could not download. |
| glentities | ⏭️ skip · resolve | not found / could not download. |
| glenv | ⏭️ skip · resolve | not found / could not download. |
| glenvy | ⏭️ skip · resolve | not found / could not download. |
| gleojson | ⏭️ skip · resolve | not found / could not download. |
| glepack | ⏭️ skip · resolve | not found / could not download. |
| glerd | ⏭️ skip · resolve | not found / could not download. |
| glerd_json | ⏭️ skip · resolve | not found / could not download. |
| glerd_valid | ⏭️ skip · resolve | not found / could not download. |
| glerm | ⏭️ skip · resolve | not found / could not download. |
| gleroglero | ⏭️ skip · resolve | not found / could not download. |
| glerror | ⏭️ skip · resolve | not found / could not download. |
| glesha | ⏭️ skip · resolve | not found / could not download. |
| glesha2 | ⏭️ skip · resolve | not found / could not download. |
| glethers | ⏭️ skip · resolve | not found / could not download. |
| glevatar | ⏭️ skip · resolve | not found / could not download. |
| glevenshtein | ⏭️ skip · resolve | not found / could not download. |
| glex | ⏭️ skip · resolve | not found / could not download. |
| glexec | ⏭️ skip · resolve | not found / could not download. |
| glexer | ✅ clean |  |
| glexif | ⏭️ skip · resolve | not found / could not download. |
| gleyre | ⏭️ skip · resolve | not found / could not download. |
| glib | ⏭️ skip · resolve | not found / could not download. |
| gliberapay | ⏭️ skip · resolve | not found / could not download. |
| glibsql | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glidicon | ⏭️ skip · resolve | not found / could not download. |
| glidna | ✅ clean |  |
| gliew | ⏭️ skip · resolve | not found / could not download. |
| gliff | ✅ clean |  |
| glight | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glimit | ✅ clean |  |
| glimiter | ✅ clean |  |
| glimmer | ⏭️ skip · resolve | not found / could not download. |
| glimp | ✅ clean |  |
| glimpse | ⏭️ skip · resolve | not found / could not download. |
| glimpse_log | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glimr | ✅ clean |  |
| glimr_auth | ⏭️ skip · resolve | not found / could not download. |
| glimr_postgres | ⏭️ skip · resolve | not found / could not download. |
| glimr_redis | ⏭️ skip · resolve | not found / could not download. |
| glimr_sqlite | ⏭️ skip · resolve | not found / could not download. |
| glimra | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glimt | ⏭️ skip · resolve | not found / could not download. |
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
| glisp | ⏭️ skip · resolve | not found / could not download. |
| glisten | 🔧 fixed | `Socket` (local alias) vs `InternalSocket` (`type Socket as InternalSocket` import). Fixed: renamed type imports hydrate to their origin name (`9e5833b`). |
| glistix_birl | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glistix_gleeunit | ⏭️ skip · resolve | not found / could not download. |
| glistix_json | ⏭️ skip · resolve | not found / could not download. |
| glistix_nix | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glistix_stdlib | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glitch | ⏭️ skip · resolve | not found / could not download. |
| glite | ⏭️ skip · resolve | not found / could not download. |
| glitr | ⏭️ skip · resolve | not found / could not download. |
| glitr_convert | ⏭️ skip · resolve | not found / could not download. |
| glitr_convert_cake | ⏭️ skip · resolve | not found / could not download. |
| glitr_convert_sql | ⏭️ skip · resolve | not found / could not download. |
| glitr_lustre | ⏭️ skip · resolve | not found / could not download. |
| glitr_wisp | ⏭️ skip · resolve | not found / could not download. |
| glitzer | ⏭️ skip · resolve | not found / could not download. |
| gliua | ⏭️ skip · resolve | not found / could not download. |
| glixir | ⏭️ skip · resolve | not found / could not download. |
| glizzy | ⏭️ skip · resolve | not found / could not download. |
| gllm | ⏭️ skip · resolve | not found / could not download. |
| glm_cidr | ⏭️ skip · resolve | not found / could not download. |
| glm_encrypted_file | ⏭️ skip · resolve | not found / could not download. |
| glm_freebsd | ⏭️ skip · resolve | not found / could not download. |
| glm_vault | ⏭️ skip · resolve | not found / could not download. |
| global_value | ✅ clean |  |
| globe | ⏭️ skip · resolve | not found / could not download. |
| globlin | ✅ clean |  |
| globlin_fs | ✅ clean |  |
| glodbc | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glog | ⏭️ skip · resolve | not found / could not download. |
| glogg | ✅ clean |  |
| glome | ⏭️ skip · resolve | not found / could not download. |
| gloml | ⏭️ skip · resolve | not found / could not download. |
| glomp | ✅ clean |  |
| glon | ✅ clean |  |
| gloo | 🔧 fixed | a record reached through a helper in another module (`schema.users().decoder`, `Table` from `gloo/schema`) failed field access because an alias collision evicted the origin module; resolve accessors through the transitive interface graph (`ce69a55`). |
| gloom | ⏭️ skip · resolve | not found / could not download. |
| gloop | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glopenai | ✅ clean |  |
| gloq | ✅ clean |  |
| glor | ✅ clean |  |
| glorage | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glormat | ✅ clean |  |
| gloss | ⏭️ skip · resolve | not found / could not download. |
| glotel | ✅ clean |  |
| glove | ✅ clean |  |
| glow | ⏭️ skip · resolve | not found / could not download. |
| glow_auth | ✅ clean |  |
| glqr | ✅ clean |  |
| glriff | ✅ clean |  |
| glrss_parser | ⏭️ skip · resolve | not found / could not download. |
| glua | ✅ clean |  |
| glubs | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glubsub | ✅ clean |  |
| glucose | ⏭️ skip · resolve | not found / could not download. |
| glue | ⏭️ skip · resolve | not found / could not download. |
| glugify | ✅ clean |  |
| gluid | ✅ clean |  |
| glum | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gluon | ⏭️ skip · resolve | not found / could not download. |
| glupbit | ⏭️ skip · resolve | not found / could not download. |
| gluple | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gluri | ✅ clean |  |
| glurp6 | ✅ clean |  |
| glv8 | ⏭️ skip · resolve | not found / could not download. |
| glwav | ✅ clean |  |
| glx | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| glychee | ✅ clean |  |
| glyn | ✅ clean |  |
| glyph | ⏭️ skip · resolve | not found / could not download. |
| glyph_codegen | ⏭️ skip · resolve | not found / could not download. |
| glypst | ⏭️ skip · resolve | not found / could not download. |
| glzoneinfo | ⏭️ skip · resolve | not found / could not download. |
| gmsg | ✅ clean |  |
| gmysql | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| go_over | ✅ clean |  |
| gond | ✅ clean |  |
| goose | ✅ clean |  |
| gopenai | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gorrion | ⏭️ skip · resolve | not found / could not download. |
| gose | ⏭️ skip · resolve | not found / could not download. |
| gossamer | ⏭️ skip · resolve | not found / could not download. |
| gpkm | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gpop | ⏭️ skip · resolve | not found / could not download. |
| gpsd_json | ⏭️ skip · resolve | not found / could not download. |
| gpxb | ⏭️ skip · resolve | not found / could not download. |
| gquery | ⏭️ skip · resolve | not found / could not download. |
| graded | ⏭️ skip · resolve | not found / could not download. |
| grammy | ⏭️ skip · resolve | not found / could not download. |
| gramps | ✅ clean | earlier `Header` error was a missing `gleam_http` dependency, not a girard bug. |
| graph | ⏭️ skip · resolve | not found / could not download. |
| grille_pain | ⏭️ skip · resolve | not found / could not download. |
| gripe | ⏭️ skip · resolve | not found / could not download. |
| grom | ⏭️ skip · resolve | not found / could not download. |
| grom_stratus | ⏭️ skip · resolve | not found / could not download. |
| group_registry | ⏭️ skip · resolve | not found / could not download. |
| gs | ⏭️ skip · resolve | not found / could not download. |
| gserde | ⏭️ skip · resolve | not found / could not download. |
| gsiphash | ⏭️ skip · resolve | not found / could not download. |
| gsmtp | ⏭️ skip · resolve | not found / could not download. |
| gssg | ⏭️ skip · resolve | not found / could not download. |
| gstripe | ⏭️ skip · resolve | not found / could not download. |
| gsv | ✅ clean |  |
| gtabler | ⏭️ skip · resolve | not found / could not download. |
| gtemplate | ⏭️ skip · resolve | not found / could not download. |
| gtempo | ✅ clean |  |
| gtfs_gleam | ⏭️ skip · resolve | not found / could not download. |
| gtfs_rt_nyct | ⏭️ skip · resolve | not found / could not download. |
| gtransducer | ⏭️ skip · resolve | not found / could not download. |
| gts | ⏭️ skip · resolve | not found / could not download. |
| gtui | ⏭️ skip · resolve | not found / could not download. |
| gtz | ⏭️ skip · resolve | not found / could not download. |
| gu | ⏭️ skip · resolve | not found / could not download. |
| guddle | ⏭️ skip · resolve | not found / could not download. |
| gulid | ⏭️ skip · resolve | not found / could not download. |
| gva | ⏭️ skip · resolve | not found / could not download. |
| gvarint | ⏭️ skip · resolve | not found / could not download. |
| gwg_pathfinding | ⏭️ skip · resolve | not found / could not download. |
| gwg_rng | ⏭️ skip · resolve | not found / could not download. |
| gwi | ⏭️ skip · resolve | not found / could not download. |
| gwitch | ⏭️ skip · resolve | not found / could not download. |
| gwr | ⏭️ skip · resolve | not found / could not download. |
| gwt | ⏭️ skip · resolve | not found / could not download. |
| gxid | ⏭️ skip · resolve | not found / could not download. |
| gxml | ⏭️ skip · resolve |  |
| gxyz | ⏭️ skip · resolve | not found / could not download. |
| gzlib | ⏭️ skip · resolve | not found / could not download. |
| gzxcvbn | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gzxcvbn_common | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| gzxcvbn_en | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| h2_frame | 📝 note | fails to **parse** in glance — a bit-array segment whose value is a qualified field access (`stream_priority.stream_dependency:size(31)`). A glance limitation, not girard inference. |
| halo | ⏭️ skip · resolve | not found / could not download. |
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
| howdy | ⏭️ skip · resolve | not found / could not download. |
| howdy_authentication_cookies | ⏭️ skip · resolve | not found / could not download. |
| howdy_uuid | ⏭️ skip · resolve | not found / could not download. |
| hstack | ✅ clean |  |
| htmb | ✅ clean |  |
| htmgrrrl | ✅ clean |  |
| html_components | ✅ clean |  |
| html_dsl | ✅ clean |  |
| html_lustre_converter | ✅ clean |  |
| html_parser | ✅ clean |  |
| htmz | ⏭️ skip · resolve | not found / could not download. |
| http_server_mock | ✅ clean |  |
| http_server_mock_erlang | ✅ clean |  |
| http_server_mock_js | ✅ clean |  |
| httpp | ⏭️ skip · resolve | not found / could not download. |
| hug | ⏭️ skip · resolve | not found / could not download. |
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
| integer_complexity | ⏭️ skip · resolve | not found / could not download. |
| interior | ✅ clean |  |
| intldate | ✅ clean |  |
| ior | ✅ clean |  |
| iox | ⏭️ skip · resolve | not found / could not download. |
| iso_8859 | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| iterators | ⏭️ skip · resolve | not found / could not download. |
| iv | ✅ clean |  |
| ivy | ⏭️ skip · resolve | not found / could not download. |
| jackson | ⏭️ skip · resolve | not found / could not download. |
| jasper | ⏭️ skip · resolve | not found / could not download. |
| javascript_dom_parser | ⏭️ skip · resolve | not found / could not download. |
| javascript_mutable_reference | ⏭️ skip · resolve | not found / could not download. |
| jbs | ⏭️ skip · resolve | not found / could not download. |
| jelly | ⏭️ skip · resolve | not found / could not download. |
| jokeapi | ⏭️ skip · resolve | not found / could not download. |
| jot | 🔧 fixed | `"a" as c <> rest` string-prefix pattern dropped the prefix `as` binding → `c` unbound. Fixed in `PatternConcatenate` (`1cfb3a2`). |
| jot_to_lustre | ⏭️ skip · resolve | not found / could not download. |
| jotkey | ⏭️ skip · resolve | not found / could not download. |
| js_parser | ⏭️ skip · resolve | not found / could not download. |
| jscheam | ⏭️ skip · resolve | not found / could not download. |
| json_blueprint | ⏭️ skip · resolve | not found / could not download. |
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
| kata_env | ✅ clean |  |
| kata_form | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| kata_json | ✅ clean |  |
| keccak_gleam | ✅ clean |  |
| keyboard_shortcuts | ✅ clean |  |
| keystore | ✅ clean |  |
| kicad_sexpr | 📝 note | girard pins a generic var to a concrete type where the compiler keeps it polymorphic (`Result(#(Symbol, ...), ...)` vs `Result(#($0, ...), ...)`) in a parser combinator — same over-resolution family as gleamgen/omnimessage_lustre (6 mismatches). |
| kick | ✅ clean |  |
| kielet | ⏭️ skip · resolve | not found / could not download. |
| kielet_gen | ⏭️ skip · resolve | not found / could not download. |
| kindly | ✅ clean |  |
| kirala_bbmarkdown | ⏭️ skip · resolve | not found / could not download. |
| kirala_l4u | ⏭️ skip · resolve | not found / could not download. |
| kirala_markdown | ⏭️ skip · resolve | not found / could not download. |
| kitazith | ✅ clean |  |
| kitten | ✅ clean |  |
| klubok_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| kmh | ✅ clean |  |
| knit_string | ✅ clean |  |
| kreator | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| kryptos | 📝 note | its `kryptos/internal/der` module fails to **parse** in glance (bit-array pattern segment with an arithmetic size); cascades to `unbound variable: der` in dependents. The same glance gap behind acumen — not girard inference. |
| kv_sessions | ⏭️ skip · resolve | not found / could not download. |
| kv_sessions_postgres_adapter | ⏭️ skip · resolve | not found / could not download. |
| kvite | ✅ clean |  |
| lamb | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lancaster_stemmer | 📝 note | fails to **parse** in glance — a parser limitation, not girard inference. |
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
| legos | ⏭️ skip · resolve | not found / could not download. |
| lenient_parse | ⏭️ skip · resolve | not found / could not download. |
| leviathan | ⏭️ skip · resolve | not found / could not download. |
| libero | ⏭️ skip · resolve | not found / could not download. |
| libsql | ⏭️ skip · resolve | not found / could not download. |
| libsql_gleam | ⏭️ skip · resolve | not found / could not download. |
| lifeguard | ⏭️ skip · resolve | not found / could not download. |
| lightbulb | ⏭️ skip · resolve | not found / could not download. |
| lightspeed | ⏭️ skip · resolve | not found / could not download. |
| lily | ⏭️ skip · resolve | not found / could not download. |
| lite_fs | ⏭️ skip · resolve | not found / could not download. |
| llmgleam | ⏭️ skip · resolve | not found / could not download. |
| loan | ⏭️ skip · resolve | not found / could not download. |
| local_time_utils | ⏭️ skip · resolve | not found / could not download. |
| logging | ✅ clean |  |
| lorem_ipsum | ⏭️ skip · resolve | not found / could not download. |
| lotta | ⏭️ skip · resolve | not found / could not download. |
| lucid | ⏭️ skip · resolve | not found / could not download. |
| lucide_lustre | ⏭️ skip · resolve | not found / could not download. |
| luciole | ⏭️ skip · resolve | not found / could not download. |
| lumenmail | ⏭️ skip · resolve | not found / could not download. |
| lumi | ⏭️ skip · resolve | not found / could not download. |
| luminite | ⏭️ skip · resolve | not found / could not download. |
| lustre | 🔧 fixed | multiple: inferred-variant field access (`Element.attributes`), multi-variant record update, cross-module generalization (`74a3278`); `cache.events(cache)` module-vs-field by call position (`8693b66`). |
| lustre_alpine | ⏭️ skip · resolve | not found / could not download. |
| lustre_animation | ⏭️ skip · resolve | not found / could not download. |
| lustre_carousel | ⏭️ skip · resolve | not found / could not download. |
| lustre_dev_tools | 🔧 fixed | `import gleam.{Error as Err}` (via polly) — prelude module not resolvable (`07129a2`); `string.trim` qualified access wrongly grouped `flag`/`string` → `Int vs String` (`3209cb8`/`656e830`). |
| lustre_hash_state | ⏭️ skip · resolve | not found / could not download. |
| lustre_http | ⏭️ skip · build |  |
| lustre_http_lib | ⏭️ skip · resolve | not found / could not download. |
| lustre_hx | ⏭️ skip · resolve | not found / could not download. |
| lustre_kakaomap | ⏭️ skip · resolve | not found / could not download. |
| lustre_limiter | ⏭️ skip · resolve | not found / could not download. |
| lustre_omnistate | ⏭️ skip · resolve | not found / could not download. |
| lustre_pipes | ⏭️ skip · resolve | not found / could not download. |
| lustre_platform | ⏭️ skip · resolve | not found / could not download. |
| lustre_platform_opentui | ⏭️ skip · resolve | not found / could not download. |
| lustre_portal | ⏭️ skip · resolve | not found / could not download. |
| lustre_prefab | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_routed | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_ssg | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_stylish | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_tauri | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_touch_events | ✅ clean |  |
| lustre_transition | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| lustre_ui | ⏭️ skip · resolve | not found / could not download. |
| lustre_virtual_list | ⏭️ skip · resolve | not found / could not download. |
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
| marmot | ⏭️ skip · resolve | not found / could not download. |
| mascarpone | ⏭️ skip · resolve | not found / could not download. |
| mat | ⏭️ skip · build |  |
| matrix_gleam | ⏭️ skip · resolve | not found / could not download. |
| maud | ⏭️ skip · resolve | not found / could not download. |
| mcp_client | ⏭️ skip · resolve | not found / could not download. |
| mcp_toolkit | ⏭️ skip · resolve | not found / could not download. |
| meadow | ⏭️ skip · resolve | not found / could not download. |
| melon | ⏭️ skip · resolve | not found / could not download. |
| memo_gleam | ⏭️ skip · resolve | not found / could not download. |
| mendix_widget_gleam | ⏭️ skip · resolve | not found / could not download. |
| mendraw | ⏭️ skip · resolve | not found / could not download. |
| messua | ⏭️ skip · resolve | not found / could not download. |
| metamon | ⏭️ skip · resolve | not found / could not download. |
| midas | ⏭️ skip · resolve | not found / could not download. |
| midas_beam | ⏭️ skip · resolve | not found / could not download. |
| midas_browser | ⏭️ skip · resolve | not found / could not download. |
| midas_node | ⏭️ skip · resolve | not found / could not download. |
| midas_sdk | ⏭️ skip · resolve | not found / could not download. |
| migrant | ⏭️ skip · resolve | not found / could not download. |
| mimetype | ⏭️ skip · resolve | not found / could not download. |
| mineflayer | ⏭️ skip · resolve | not found / could not download. |
| miniflare | ⏭️ skip · resolve | not found / could not download. |
| miniflux_sdk | ⏭️ skip · resolve | not found / could not download. |
| minigen | ⏭️ skip · resolve | not found / could not download. |
| mist | 🔧 fixed | `compression.deflate` module-vs-field (`8693b66`); `import gleam/http as _ghttp` discarded alias shadowed `mist/internal/http` (`1b35463`); exponential transitive re-inference hang fixed by interface memoization (`bcd20f4`). |
| mist_reload | ⏭️ skip · resolve | not found / could not download. |
| mochi | ⏭️ skip · resolve | not found / could not download. |
| mockth | ⏭️ skip · resolve | not found / could not download. |
| modem | ✅ clean |  |
| mon | ⏭️ skip · resolve | not found / could not download. |
| money_pattern | ⏭️ skip · resolve | not found / could not download. |
| monies | ⏭️ skip · resolve | not found / could not download. |
| monks_of_style | ⏭️ skip · resolve | not found / could not download. |
| mork | ⏭️ skip · resolve | not found / could not download. |
| mork_to_lustre | ⏭️ skip · resolve | not found / could not download. |
| morse_code_translator | ⏭️ skip · resolve | not found / could not download. |
| morsey | ⏭️ skip · resolve | not found / could not download. |
| mote | ⏭️ skip · resolve | not found / could not download. |
| mug | ✅ clean |  |
| multiformats | ⏭️ skip · resolve | not found / could not download. |
| multipart_form | ⏭️ skip · resolve | not found / could not download. |
| multipartkit | ⏭️ skip · resolve | not found / could not download. |
| mumu | ⏭️ skip · resolve | not found / could not download. |
| mungo | ⏭️ skip · build |  |
| murmur3a | ⏭️ skip · resolve | not found / could not download. |
| mut_cell | ⏭️ skip · resolve | not found / could not download. |
| mysig | ⏭️ skip · resolve | not found / could not download. |
| nakai | ✅ clean |  |
| nanoworker | ✅ clean |  |
| nbeet | ✅ clean |  |
| neon | ✅ clean |  |
| nephrotoma | ✅ clean |  |
| nerf | ⏭️ skip · resolve | not found / could not download. |
| nessie | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| nessie_2 | ✅ clean |  |
| nessie_cluster | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| netlify | ✅ clean |  |
| netpbm | ✅ clean |  |
| netstring | ✅ clean |  |
| next_door | ✅ clean |  |
| ngs | ✅ clean |  |
| nibble | ⏭️ skip · resolve | not found / could not download. |
| niji | ✅ clean |  |
| nimiq_address | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| nimiq_blake2b | ✅ clean |  |
| nimiq_bls | ✅ clean |  |
| nimiq_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| nimiq_rpc | ⏭️ skip · resolve | not found / could not download. |
| nimiq_serde | ✅ clean |  |
| node_pg | ✅ clean |  |
| node_socket_client | ✅ clean |  |
| node_tags | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| non_empty_list | ✅ clean |  |
| nori | ✅ clean |  |
| novdom | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| novdom_dev_tools | ⏭️ skip · resolve | not found / could not download. |
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
| olive | ⏭️ skip · resolve | not found / could not download. |
| ollama_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| omnimessage_lustre | 📝 note | type-variable identity differs only (`#($0, Effect($1))` vs `#($2, Effect($1))`): `lustre.application` later ties `compose`'s returned update fn's input/output model, and girard records the fully-resolved type while the compiler snapshots the call result before that back-propagation. Same class as prng; girard is the more-resolved view, not a bug. |
| omnimessage_server | ⏭️ skip · resolve | not found / could not download. |
| on | ✅ clean |  |
| onigleam | ✅ clean |  |
| opaq | ⏭️ skip · resolve | not found / could not download. |
| open_color | ✅ clean |  |
| open_props | ✅ clean |  |
| opener | ✅ clean |  |
| openfeature | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| opengleametry | ⏭️ skip · resolve | not found / could not download. |
| opengleametry_test | ⏭️ skip · resolve | not found / could not download. |
| openrouter_client | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| operating_system | ✅ clean |  |
| opt_args_with_defs_for_gleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| optimist | ✅ clean |  |
| or_error | ✅ clean |  |
| orbital | ✅ clean |  |
| ordered_dict | ✅ clean |  |
| ormlette | ⏭️ skip · resolve | not found / could not download. |
| oteap | ⏭️ skip · resolve | not found / could not download. |
| outcome | ✅ clean |  |
| outil | ⏭️ skip · resolve |  |
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
| panel | ⏭️ skip · resolve | not found / could not download. |
| parallel_map | ⏭️ skip · build | uses the old `gleam/otp/actor` API (`actor.Stop`/`actor.Next`), incompatible with the resolved gleam_otp. |
| parrot | ✅ clean |  |
| parsed_it | ✅ clean |  |
| parser_gleam | ⏭️ skip · resolve | not found / could not download. |
| parsley | ✅ clean |  |
| party | ⏭️ skip · resolve | not found / could not download. |
| parz | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| passwd_gen | ⏭️ skip · resolve | not found / could not download. |
| pathern | ✅ clean |  |
| pb_lite | ⏭️ skip · resolve | not found / could not download. |
| pcl | ⏭️ skip · resolve | not found / could not download. |
| pearl | ✅ clean |  |
| pears | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| pegasus_crypto | ✅ clean |  |
| peggy | ⏭️ skip · resolve | not found / could not download. |
| persevero | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| pevensie | ⏭️ skip · resolve |  |
| pevensie_postgres | ⏭️ skip · resolve | not found / could not download. |
| pevensie_redis | ⏭️ skip · resolve | not found / could not download. |
| pg_value | ✅ clean |  |
| pgl | ✅ clean |  |
| pgo | ✅ clean |  |
| pharos | ✅ clean |  |
| phonetic_gleam | ⏭️ skip · resolve | not found / could not download. |
| phony | ✅ clean |  |
| phosphor_lustre | ⏭️ skip · resolve | not found / could not download. |
| pickle | ⏭️ skip · resolve | not found / could not download. |
| pify | ⏭️ skip · resolve | not found / could not download. |
| pika_id | ⏭️ skip · resolve | not found / could not download. |
| pine | ⏭️ skip · resolve | not found / could not download. |
| pink | ⏭️ skip · resolve | not found / could not download. |
| pinkdf2 | ⏭️ skip · resolve | not found / could not download. |
| platform | ✅ clean |  |
| playground | ⏭️ skip · resolve | not found / could not download. |
| plex_pin_auth | ⏭️ skip · resolve | not found / could not download. |
| plinth | ⏭️ skip · resolve | not found / could not download. |
| plinth_cloudflare | ⏭️ skip · resolve | not found / could not download. |
| plume | ⏭️ skip · resolve | not found / could not download. |
| plunk | ⏭️ skip · resolve | not found / could not download. |
| plushie_gleam | ⏭️ skip · resolve | not found / could not download. |
| pngleam | ⏭️ skip · resolve | not found / could not download. |
| pocket_watch | ⏭️ skip · resolve | not found / could not download. |
| pocketenv | ⏭️ skip · resolve | not found / could not download. |
| pog | ✅ clean |  |
| pojo | ⏭️ skip · resolve | not found / could not download. |
| pokemon_names | ⏭️ skip · resolve | not found / could not download. |
| pollux | ⏭️ skip · resolve | not found / could not download. |
| polly | 🔧 fixed | dep of lustre_dev_tools; `import gleam.{Error as Err}` prelude import — see lustre_dev_tools (`07129a2`). |
| pona | ⏭️ skip · resolve | not found / could not download. |
| pontil | ⏭️ skip · resolve | not found / could not download. |
| pontil_build | ⏭️ skip · resolve | not found / could not download. |
| pontil_context | ⏭️ skip · resolve | not found / could not download. |
| pontil_core | ✅ clean |  |
| pontil_platform | ✅ clean |  |
| pontil_summary | ✅ clean |  |
| popcicle | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| poreader | ⏭️ skip · resolve | not found / could not download. |
| porter_stemmer | ✅ clean |  |
| postgleam | ✅ clean |  |
| postglide | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| postgresql_protocol | ⏭️ skip · resolve | not found / could not download. |
| pprint | ✅ clean |  |
| precious | ✅ clean |  |
| prequel | ⏭️ skip · resolve | not found / could not download. |
| presentable_soup | ✅ clean |  |
| pretty_diff | 📝 note | girard pins annotated generic vars to `Dynamic` where the compiler keeps them polymorphic (`Dict($0, Diff)` vs `Dict(Dynamic, Diff)`) — the same rigid-type-variable gap as gleamgen (25 mismatches, all this shape). |
| priorityq | ✅ clean |  |
| prng | 📝 note | one expression mismatch at a polymorphic function reference (`fixed_size_dict`): the compiler's signature is tied like girard's; the oracle snapshots the reference pre-unification. girard is correct. |
| problem | ✅ clean |  |
| probly | ✅ clean |  |
| process_file | ✅ clean |  |
| process_waiter | ⏭️ skip · resolve | not found / could not download. |
| processgroups | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| promgleam | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| promptly | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| protobin | ⏭️ skip · resolve | not found / could not download. |
| protozoa | ⏭️ skip · resolve | not found / could not download. |
| protozoa_dev | ⏭️ skip · resolve | not found / could not download. |
| psg | ⏭️ skip · resolve | not found / could not download. |
| psl | ⏭️ skip · resolve | not found / could not download. |
| pturso | ⏭️ skip · resolve | not found / could not download. |
| pubgrub | ⏭️ skip · resolve | not found / could not download. |
| publicsuffix_gleam | ⏭️ skip · resolve | not found / could not download. |
| puddle | ⏭️ skip · resolve | not found / could not download. |
| punycode | ⏭️ skip · resolve | not found / could not download. |
| qcheck | ✅ clean |  |
| qcheck_gleeunit_utils | ⏭️ skip · resolve | not found / could not download. |
| qol_gleam | ⏭️ skip · resolve | not found / could not download. |
| qrkit | ⏭️ skip · resolve | not found / could not download. |
| qs | ⏭️ skip · resolve | not found / could not download. |
| quaterni | ⏭️ skip · resolve | not found / could not download. |
| quaternion | ⏭️ skip · resolve | not found / could not download. |
| queryb | ⏭️ skip · resolve | not found / could not download. |
| question | ⏭️ skip · resolve | not found / could not download. |
| rad | ⏭️ skip · resolve | not found / could not download. |
| rada | ⏭️ skip · resolve | not found / could not download. |
| radiant | ⏭️ skip · resolve | not found / could not download. |
| radiate | ⏭️ skip · resolve | not found / could not download. |
| radish | ⏭️ skip · resolve | not found / could not download. |
| radish_fork | ⏭️ skip · resolve | not found / could not download. |
| rally | ⏭️ skip · resolve | not found / could not download. |
| ramble | ⏭️ skip · resolve | not found / could not download. |
| randomlib | ⏭️ skip · resolve | not found / could not download. |
| ranged_int | ⏭️ skip · resolve | not found / could not download. |
| ranger | ✅ clean |  |
| rank | ⏭️ skip · resolve | not found / could not download. |
| rasa | ⏭️ skip · resolve | not found / could not download. |
| ratioed | ⏭️ skip · resolve | not found / could not download. |
| rcade_inputs | ⏭️ skip · resolve | not found / could not download. |
| react_gleam | ⏭️ skip · resolve | not found / could not download. |
| reactive_signal | ⏭️ skip · resolve | not found / could not download. |
| ream | ⏭️ skip · resolve | not found / could not download. |
| rectify | ⏭️ skip · resolve | not found / could not download. |
| recursive | ⏭️ skip · resolve | not found / could not download. |
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
| rosetta | ⏭️ skip · resolve | not found / could not download. |
| roundabout | ⏭️ skip · resolve | not found / could not download. |
| rsa_keys | ⏭️ skip · build | a dependency or the package does not compile with current tooling. |
| rsvp | ⏭️ skip · resolve | not found / could not download. |
| runetracer | ⏭️ skip · resolve | not found / could not download. |
| sara | ⏭️ skip · resolve | not found / could not download. |
| savoiardi | ⏭️ skip · resolve | not found / could not download. |
| scaffold_gleam | ⏭️ skip · resolve | not found / could not download. |
| scamper | ⏭️ skip · resolve | not found / could not download. |
| sceall | ⏭️ skip · resolve | not found / could not download. |
| scrapbook | ⏭️ skip · resolve | not found / could not download. |
| scriptorium | ⏭️ skip · resolve | not found / could not download. |
| search_algorithms_gleam | ⏭️ skip · resolve | not found / could not download. |
| secp256k1_gleam | ⏭️ skip · resolve | not found / could not download. |
| sendgriddle | ⏭️ skip · resolve | not found / could not download. |
| sextant | ⏭️ skip · resolve | not found / could not download. |
| shakespeare | ⏭️ skip · resolve | not found / could not download. |
| shamir | ⏭️ skip · resolve | not found / could not download. |
| shcribe | ⏭️ skip · resolve | not found / could not download. |
| sheen | ⏭️ skip · resolve | not found / could not download. |
| shelf | ⏭️ skip · resolve | not found / could not download. |
| shellout | ✅ clean |  |
| shimmer | ⏭️ skip · resolve | not found / could not download. |
| shimmy | ⏭️ skip · resolve | not found / could not download. |
| shine_tree | ⏭️ skip · resolve | not found / could not download. |
| shiny | ⏭️ skip · resolve | not found / could not download. |
| shopify_draft_proxy | ⏭️ skip · resolve | not found / could not download. |
| shore | 🔧 fixed | `let focused = FocusedInput(..)` then `focused.offset` — variant narrowing from a constructor in a let binding (`1796ffb`). |
| shork | ⏭️ skip · resolve | not found / could not download. |
| showtime | ⏭️ skip · resolve | not found / could not download. |
| sidereal | ⏭️ skip · resolve | not found / could not download. |
| sift | ⏭️ skip · resolve | not found / could not download. |
| sigmal | ⏭️ skip · resolve | not found / could not download. |
| signal | ⏭️ skip · resolve | not found / could not download. |
| signal_pgo | ⏭️ skip · resolve | not found / could not download. |
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
| smalto_lustre | ⏭️ skip · resolve | not found / could not download. |
| smalto_lustre_themes | ⏭️ skip · resolve | not found / could not download. |
| smol | ⏭️ skip · resolve | not found / could not download. |
| smut | ⏭️ skip · resolve | not found / could not download. |
| snag | ✅ clean |  |
| snowball_stemmer | ⏭️ skip · resolve | not found / could not download. |
| snowglake | ⏭️ skip · resolve | not found / could not download. |
| snowgleam | ⏭️ skip · resolve | not found / could not download. |
| sol | ⏭️ skip · resolve | not found / could not download. |
| solc | ⏭️ skip · resolve | not found / could not download. |
| sonatina | ⏭️ skip · resolve | not found / could not download. |
| sorbet | ⏭️ skip · resolve | not found / could not download. |
| spacetraders_api | ⏭️ skip · resolve | not found / could not download. |
| spacetraders_api_fetch | ⏭️ skip · resolve | not found / could not download. |
| spacetraders_api_httpc | ⏭️ skip · resolve | not found / could not download. |
| spacetraders_models | ⏭️ skip · resolve | not found / could not download. |
| spacetraders_sdk | ⏭️ skip · resolve | not found / could not download. |
| sparkle | ⏭️ skip · resolve | not found / could not download. |
| sparkleplug | ⏭️ skip · resolve | not found / could not download. |
| sparklinekit | ⏭️ skip · resolve | not found / could not download. |
| sparkling | ⏭️ skip · resolve | not found / could not download. |
| sparx | ⏭️ skip · resolve | not found / could not download. |
| spatial | ⏭️ skip · resolve | not found / could not download. |
| spectator | ⏭️ skip · resolve | not found / could not download. |
| speedbump | ⏭️ skip · resolve | not found / could not download. |
| spell_out | ⏭️ skip · resolve | not found / could not download. |
| spinner | ✅ clean |  |
| splash | ⏭️ skip · resolve | not found / could not download. |
| splines | ⏭️ skip · resolve | not found / could not download. |
| splitter | ✅ clean |  |
| spoke | ⏭️ skip · resolve | not found / could not download. |
| spoke_core | ⏭️ skip · resolve | not found / could not download. |
| spoke_mqtt | ⏭️ skip · resolve | not found / could not download. |
| spoke_mqtt_actor | ⏭️ skip · resolve | not found / could not download. |
| spoke_mqtt_js | ⏭️ skip · resolve | not found / could not download. |
| spoke_packet | ⏭️ skip · resolve | not found / could not download. |
| spoke_tcp | ⏭️ skip · resolve | not found / could not download. |
| spotify_client | ⏭️ skip · resolve | not found / could not download. |
| spotless | ⏭️ skip · resolve | not found / could not download. |
| sprinkle | ⏭️ skip · resolve | not found / could not download. |
| sprocket | ⏭️ skip · resolve | not found / could not download. |
| sprocket_mist | ⏭️ skip · resolve | not found / could not download. |
| sqid | ⏭️ skip · resolve | not found / could not download. |
| sqlc_gen_gleam | ⏭️ skip · resolve | not found / could not download. |
| sqlight | ⏭️ skip · resolve | not found / could not download. |
| sqlode | ⏭️ skip · resolve | not found / could not download. |
| squall | ⏭️ skip · resolve | not found / could not download. |
| squeal | ⏭️ skip · resolve | not found / could not download. |
| squirrel | 🔧 fixed | `QueryFileHasInvalidName(file:, reason: _, suggested_name:)` — labelled function-capture hole placed positionally instead of by label (`ab80771`). |
| squirtle | ⏭️ skip · resolve | not found / could not download. |
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
