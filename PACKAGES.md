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
| abair | ✅ clean | |
| acrostic | ⏭️ skip · resolve | not found / could not download. |
| act | ✅ clean | |
| actorx | ⏭️ skip · resolve | not found / could not download. |
| acumen | 📝 note | All modules error `unbound variable: der`. Root cause: its dep `kryptos/internal/der` fails to **parse** in glance — a bit-array *pattern* segment with an arithmetic size, `<<v:bytes-size(len - 1)>>` (glance rejects the `-`; bare vars and construction-side arithmetic parse fine). A glance limitation, not girard inference; cascades to every module importing `der`. |
| adglent | ⏭️ skip · resolve | not found / could not download. |
| antigone | ✅ clean | |
| argv | ✅ clean | |
| bath | ✅ clean | |
| birdie | 📝 note | `internal/diagnostic` fails to **parse** — a glance limitation (newer syntax), not girard inference. Cascades to `unbound variable: diagnostic`. |
| birl | ✅ clean | |
| bison | ⏭️ skip · build | |
| cake | ✅ clean | |
| cigogne | 🔧 fixed | `config.dependencies` field access on a local constant was dropped as a dependency edge → const inferred too late → unbound. Fixed: references split into values vs field-access qualifiers (`656e830`). |
| clip | ✅ clean | |
| conversation | ✅ clean | |
| cors_builder | 🔧 fixed | `res \|> set_allowed_origin(cors, origin)` — pipe into a *saturated* call applies the value to the result (`f(args)(left)`); girard always inserted it as the first argument → wrong arity. Fixed in `infer_pipe` (`6a58010`). |
| counter | ✅ clean | |
| decode | ⏭️ skip · build | an old `decode` version does not compile against the resolved newer `gleam_stdlib`. |
| directories | ✅ clean | |
| edit_distance | ✅ clean | |
| envoy | ✅ clean | |
| eval | ✅ clean | |
| exception | ✅ clean | |
| filepath | ✅ clean | |
| formal | ✅ clean | |
| gel | ⏭️ skip · resolve | source not downloaded. |
| given | 🔧 fixed | self-recursive `partition_loop` using imported constructors wasn't generalized → monomorphic across uses. Fixed: quantified scheme variables treated as opaque in `env_free_vars`. |
| glam | ✅ clean | |
| glance | ✅ clean | |
| glance_printer | ⚪ retry | sweep produced no result line; re-run to classify. |
| glearray | ✅ clean | |
| gleam_community_ansi | ✅ clean | |
| gleam_community_colour | ✅ clean | |
| gleam_community_maths | ✅ clean | |
| gleam_crypto | ✅ clean | |
| gleam_deque | ✅ clean | |
| gleam_erlang | ✅ clean | |
| gleam_fetch | ✅ clean | |
| gleam_http | ✅ clean | |
| gleam_httpc | ✅ clean | |
| gleam_javascript | ✅ clean | JS-target package. |
| gleam_json | ✅ clean | |
| gleam_otp | ✅ clean | |
| gleam_package_interface | ✅ clean | |
| gleam_pgo | ⏭️ skip · build | |
| gleam_regexp | ✅ clean | |
| gleam_stdlib | ✅ clean | |
| gleam_time | ✅ clean | |
| gleam_yaml | ✅ clean | |
| gleam_yielder | ✅ clean | |
| gleamy_bench | ✅ clean | |
| gleamy_structures | ✅ clean | |
| glector | ✅ clean | |
| glen | ✅ clean | |
| glexer | ✅ clean | |
| glint | ✅ clean | |
| glinter | ✅ clean | |
| glisten | 🔧 fixed | `Socket` (local alias) vs `InternalSocket` (`type Socket as InternalSocket` import). Fixed: renamed type imports hydrate to their origin name (`9e5833b`). |
| gluid | ✅ clean | |
| gladvent | ⏭️ skip · build | a transitive `decode` version is broken against the resolved stdlib. |
| gramps | ✅ clean | earlier `Header` error was a missing `gleam_http` dependency, not a girard bug. |
| gsv | ✅ clean | |
| gtempo | ✅ clean | |
| gxml | ⏭️ skip · resolve | |
| houdini | ✅ clean | |
| iv | ✅ clean | |
| jot | 🔧 fixed | `"a" as c <> rest` string-prefix pattern dropped the prefix `as` binding → `c` unbound. Fixed in `PatternConcatenate` (`1cfb3a2`). |
| justin | ✅ clean | |
| logging | ✅ clean | |
| lustre | 🔧 fixed | multiple: inferred-variant field access (`Element.attributes`), multi-variant record update, cross-module generalization (`74a3278`); `cache.events(cache)` module-vs-field by call position (`8693b66`). |
| lustre_dev_tools | 🔧 fixed | `import gleam.{Error as Err}` (via polly) — prelude module not resolvable (`07129a2`); `string.trim` qualified access wrongly grouped `flag`/`string` → `Int vs String` (`3209cb8`/`656e830`). |
| lustre_http | ⏭️ skip · build | |
| lustre_websocket | ⏭️ skip · build | |
| marceau | ✅ clean | |
| mat | ⏭️ skip · build | |
| mist | 🔧 fixed | `compression.deflate` module-vs-field (`8693b66`); `import gleam/http as _ghttp` discarded alias shadowed `mist/internal/http` (`1b35463`); exponential transitive re-inference hang fixed by interface memoization (`bcd20f4`). |
| modem | ✅ clean | |
| mug | ✅ clean | |
| mungo | ⏭️ skip · build | |
| nakai | ✅ clean | |
| non_empty_list | ✅ clean | |
| oas | ✅ clean | |
| outil | ⏭️ skip · resolve | |
| parallel_map | ⏭️ skip · build | uses the old `gleam/otp/actor` API (`actor.Stop`/`actor.Next`), incompatible with the resolved gleam_otp. |
| pevensie | ⏭️ skip · resolve | |
| pgo | ✅ clean | |
| platform | ✅ clean | |
| pog | ✅ clean | |
| polly | 🔧 fixed | dep of lustre_dev_tools; `import gleam.{Error as Err}` prelude import — see lustre_dev_tools (`07129a2`). |
| prng | 📝 note | one expression mismatch at a polymorphic function reference (`fixed_size_dict`): the compiler's signature is tied like girard's; the oracle snapshots the reference pre-unification. girard is correct. |
| qcheck | ✅ clean | |
| ranger | ✅ clean | |
| redraw | ✅ clean | JS-target package. |
| repeatedly | ✅ clean | |
| shellout | ✅ clean | |
| shore | 🔧 fixed | `let focused = FocusedInput(..)` then `focused.offset` — variant narrowing from a constructor in a let binding (`1796ffb`). |
| simplifile | ✅ clean | |
| sketch | ✅ clean | JS-target package. |
| snag | ✅ clean | |
| spinner | ✅ clean | |
| splitter | ✅ clean | |
| squirrel | 🔧 fixed | `QueryFileHasInvalidName(file:, reason: _, suggested_name:)` — labelled function-capture hole placed positionally instead of by label (`ab80771`). |
| storail | ✅ clean | |
| tempo | ⏭️ skip · build | |
| term_size | ✅ clean | |
| tobble | ✅ clean | |
| tom | ✅ clean | |
| tote | ✅ clean | |
| valid | ✅ clean | |
| vleam | ✅ clean | JS-target package. |
| wisp | ✅ clean | |
| xmleam | ⏭️ skip · build | |
| youid | ✅ clean | |
