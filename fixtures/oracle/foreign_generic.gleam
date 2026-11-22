// A type variable of one member of a mutually recursive group reaches another
// member through an unannotated parameter. The compiler copies it at every
// read in the other member, so `a` gets the looser `fn(a, Int) -> b`: an
// unsound signature, but the one 1.19.2 exports, and girard annotates what
// the compiler infers.

pub fn a(x, n: Int) -> v {
  case n {
    0 -> x
    _ -> b(x, n - 1)
  }
}

fn b(x: v, n: Int) -> v {
  a(x, n)
}
