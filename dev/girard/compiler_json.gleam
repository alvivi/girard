//// The real compiler's JSON type representation, decoded into girard's `Type`.
////
//// `gleam export package-interface` and the patched compiler's
//// `gleam export expression-types` spell a type the same way, so one decoder
//// serves every tool that reads either: the oracle test, the per-expression
//// diff, and the resolution differential runner. Keeping it in one place is
//// what makes "the compiler said X" mean the same thing in all three.

import girard.{type Type, Fn, Named, Tuple, Var}
import gleam/dynamic/decode.{type Decoder}

/// Decode one `{"kind": …}` type object as the compiler writes it.
pub fn type_decoder() -> Decoder(Type) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "named" -> {
      use name <- decode.field("name", decode.string)
      use module <- decode.field("module", decode.string)
      use parameters <- decode.field("parameters", decode.list(type_decoder()))
      decode.success(Named(module, name, parameters))
    }
    "fn" -> {
      use parameters <- decode.field("parameters", decode.list(type_decoder()))
      use return <- decode.field("return", type_decoder())
      decode.success(Fn(parameters, return))
    }
    "tuple" -> {
      use elements <- decode.field("elements", decode.list(type_decoder()))
      decode.success(Tuple(elements))
    }
    "variable" -> {
      use id <- decode.field("id", decode.int)
      decode.success(Var(id))
    }
    other -> decode.failure(Var(0), "Type(kind=" <> other <> ")")
  }
}
