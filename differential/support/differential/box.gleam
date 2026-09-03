//// A generic wrapper, for the row that pins where a variant is *erased*:
//// putting a constructed value into `Box(a)` binds it to a type variable, and
//// the compiler forgets which variant it was built with there.
////
//// It lives here rather than in the fixture because a fixture declaring two
//// custom types leaves which one the receiver has ambiguous, which
//// `differential_test` rejects.
////
//// It imports nothing, for the same reason `differential/io` does not.

pub type Box(a) {
  Box(inner: a)
}
