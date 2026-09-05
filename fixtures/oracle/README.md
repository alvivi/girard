# Compiler oracle fixtures

Each fixture has three files with the same base name:

- `<name>.gleam` is the source girard and the compiler both annotate.
- `<name>.interface.json` is the real compiler's `package-interface` export.
- `<name>.expr.json` is the patched compiler's `expression-types` export.

`test/oracle_test.gleam` decodes both JSON exports into girard's `Type`. It
compares every public function and constant, then compares expression types at
source spans reported by both implementations. The comparison canonicalises
type-variable names because equivalent variables may receive different ids.
Compiler desugaring can put several types on one span; those ambiguous overlays
are skipped so the test compares source expressions rather than synthetic ones.

Regenerate every JSON pair after adding or changing a `.gleam` fixture:

```sh
bash scripts/gen-oracle.sh
gleam test
```

The expression export requires the patched compiler from the
`expression-type-export` branch in `../gleam`. Set `GLEAM` to use another build:

```sh
GLEAM=/path/to/patched/gleam bash scripts/gen-oracle.sh
```

Changing fixture source shifts expression spans, even when its inferred types
stay the same, so always regenerate both JSON files together.
