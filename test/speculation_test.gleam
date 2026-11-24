// Unification in the compiler's order: a pair of different lengths fails
// before any element is unified (`environment.rs:1147, 1163, 1182-1188`), a
// tuple or a named type with a plain mismatch and a function with the arity
// reason.

import girard
import probe_support.{error_with}

pub fn tuple_size_mismatch_is_a_type_mismatch_test() {
  // The second element is a tuple of another size: no element of the two is
  // unified, so the mismatch is the tuples', not a count of their elements.
  let source = "pub fn f(a) { [#(a, 1), #(True, 1, 1)] }"
  let assert girard.TypeMismatch(girard.Tuple([_, _, _]), girard.Tuple([_, _])) =
    error_with(source, [])
}

pub fn function_arity_mismatch_is_checked_before_parameters_test() {
  // The first parameters mismatch too, but the arities are compared first.
  let source = "pub fn f() { [fn(x: Int, _y) { x }, fn(z: String) { 1 }] }"
  let assert girard.ArityMismatch = error_with(source, [])
}
