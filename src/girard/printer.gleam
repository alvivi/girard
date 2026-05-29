//// Render an internal `Type` to a Gleam-syntax string, e.g.
//// `fn(Int, String) -> Bool` or `fn(a) -> List(a)`. Unbound/quantified type
//// variables are named `a`, `b`, `c`, ... consistently within a `Names`
//// context, mirroring the compiler's `type_/printer.rs`.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/string
import girard/types.{type Type, Fn, Named, Tuple, Var}

pub type Names {
  Names(map: Dict(Int, String), next: Int)
}

pub fn new_names() -> Names {
  Names(map: dict.new(), next: 0)
}

/// Print a type within a naming context, returning the updated context so a
/// caller can keep variable names stable across several related types.
pub fn print(names: Names, type_: Type) -> #(String, Names) {
  case type_ {
    Named(_module, name, []) -> #(name, names)

    Named(_module, name, args) -> {
      let #(rendered, names) = print_list(names, args)
      #(name <> "(" <> rendered <> ")", names)
    }

    Fn(args, ret) -> {
      let #(rendered_args, names) = print_list(names, args)
      let #(rendered_ret, names) = print(names, ret)
      #("fn(" <> rendered_args <> ") -> " <> rendered_ret, names)
    }

    Tuple(elements) -> {
      let #(rendered, names) = print_list(names, elements)
      #("#(" <> rendered <> ")", names)
    }

    Var(id) -> var_name(names, id)
  }
}

/// Convenience wrapper for a single, standalone type.
pub fn to_string(type_: Type) -> String {
  print(new_names(), type_).0
}

fn print_list(names: Names, types_: List(Type)) -> #(String, Names) {
  let #(rev, names) =
    list.fold(types_, #([], names), fn(acc, t) {
      let #(rendered, names) = acc
      let #(s, names) = print(names, t)
      #([s, ..rendered], names)
    })
  #(string.join(list.reverse(rev), ", "), names)
}

fn var_name(names: Names, id: Int) -> #(String, Names) {
  case dict.get(names.map, id) {
    Ok(name) -> #(name, names)
    Error(_) -> {
      let name = letters(names.next)
      #(
        name,
        Names(map: dict.insert(names.map, id, name), next: names.next + 1),
      )
    }
  }
}

/// 0 -> "a", 25 -> "z", 26 -> "aa", 27 -> "ab", ...
fn letters(n: Int) -> String {
  let letter = string.utf_codepoint(97 + n % 26)
  let prefix = case n / 26 {
    0 -> ""
    higher -> letters(higher - 1)
  }
  case letter {
    Ok(codepoint) -> prefix <> string.from_utf_codepoints([codepoint])
    Error(_) -> "t" <> int.to_string(n)
  }
}
