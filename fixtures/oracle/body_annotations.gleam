// Body annotations scoped as the compiler's hydrator scopes them: one name
// table per function, seeded with its signature's names, and saved and
// restored around a `let` value, each `case` subject, a `case` clause, a
// function body and a block. A name in scope is that variable; a name created
// in a scope that has closed is a generic every later read copies.

fn apply(f: fn(x) -> x, x: x) -> x {
  f(x)
}

fn apply2(f: fn(x, y) -> x, x: x, y: y) -> x {
  f(x, y)
}

// A body annotation reusing a signature name is that variable.
pub fn sig_reuse(x: a, y) {
  let y: a = y
  #(x, y)
}

// A lambda parameter's annotation in a call argument creates `a` in the
// enclosing block's scope, so the later `let z: a` reuses it.
pub fn stmt_leak(p, q) {
  apply(fn(x: a) { x }, p)
  let z: a = q
  #(p, z)
}

// The same lambda inside a `let` value: `a` leaves scope with the value.
pub fn let_value_scope(p, q) {
  let _ = apply(fn(x: a) { x }, p)
  let z: a = q
  #(p, z)
}

// A block's names leave scope with it, and reading `r` copies its generic.
pub fn block_scope(p, q) {
  let r = {
    let y: a = p
    y
  }
  let z: a = q
  #(r, z)
}

// A clause's names leave scope with it.
pub fn clause_scope(p, q) {
  case p {
    _ -> apply(fn(x: a) { x }, p)
  }
  let z: a = q
  #(p, z)
}

// A case subject's names leave scope with it.
pub fn subject_scope(p, q) {
  case apply(fn(x: a) { x }, p) {
    _ -> Nil
  }
  let z: a = q
  #(p, z)
}

// A lambda body's `let` names leave scope with the body; its parameter
// annotation's names belong to the enclosing scope.
pub fn lambda_body_scope(p, q, s, t) {
  apply2(
    fn(x, _u: b) {
      let y: a = x
      y
    },
    p,
    s,
  )
  let z: a = q
  let w: b = t
  #(p, z, w, s)
}

// Guard and body reads of a local that reached an out-of-scope generic copy
// it.
pub fn guard_read(p, n: Int) {
  let r = {
    let y: a = p
    y
  }
  case n {
    _ if r == r -> #(r, p)
    _ -> #(r, p)
  }
}

// An inner lambda's parameter annotation is hydrated in the outer lambda's
// body scope, where the outer `a` is visible.
pub fn nested_lambda_reuse(p, q) {
  let f = fn(x: a) {
    let g = fn(y: a) { y }
    let _ = g(q)
    #(x, q)
  }
  f(p)
}

// A body generic of one group member reaches the other through a shared,
// unannotated parameter and is copied there.
pub fn body_generic_a(x, n: Int) -> v {
  case n {
    0 -> x
    _ -> body_generic_b(x, n - 1)
  }
}

fn body_generic_b(x, n: Int) {
  let y: v = x
  body_generic_a(y, n)
}

// The body annotation is its own function's signature variable, which the
// other member copies at each read.
pub fn sig_then_body_a(x, n: Int) -> v {
  case n {
    0 -> x
    _ -> sig_then_body_b(x, n - 1, Nil)
  }
}

fn sig_then_body_b(x, n: Int, _tag: v) {
  let y: v = x
  sig_then_body_a(y, n)
}
