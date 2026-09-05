//// The shadow module: a local module whose final path segment is `io`, so
//// `import differential/io` binds the name `io` and collides with any receiver
//// a fixture calls `io`.
////
//// It is local rather than `gleam/io` on purpose (PR 1, §3): the mechanism
//// needs to *choose* the export's type, and it must not depend on a hex
//// package version that the compiler and girard could resolve differently.
////
//// It imports nothing, deliberately, so it cannot drift. Every label a fixture
//// puts in contest needs an export here — miss one and the compiler reports an
//// unknown field instead of choosing a branch.

/// Contests the `println` field of a record variant, which is
/// `fn(String) -> Nil`. Same argument types, different return, so both readings
/// type-check and only the return distinguishes them.
pub fn println(message: String) -> Int {
  case message {
    "" -> 0
    _ -> 1
  }
}

/// Contests the `n` field of a record variant, which is `Int`.
pub const n: String = "module"

/// Contests the `y` field of the accessor-compatibility types, which is
/// `String`.
pub const y: Float = 1.0

/// Contests the `f` field of the accessor-compatibility types, which is
/// `fn(String) -> Nil` on one variant and `fn(Int) -> Nil` on the other.
pub fn f(message: String) -> Int {
  case message {
    "" -> 0
    _ -> 1
  }
}

/// Contests the `guard` field, for the `use` row. Deliberately monomorphic,
/// unlike `gleam/bool.guard`, so the row's return stays derivable from this
/// declaration.
pub fn guard(cond: Bool, fallback: Int, cb: fn() -> Int) -> Int {
  case cond {
    True -> fallback
    False -> cb()
  }
}

/// The one-sided control: no variant in the corpus declares `greet`, so every
/// reading of `io.greet()` is the module.
pub fn greet() -> Int {
  0
}
