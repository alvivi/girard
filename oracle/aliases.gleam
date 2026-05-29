pub type Id =
  Int

pub type Pair(a) =
  #(a, a)

pub fn identity(x: Id) -> Id {
  x
}

pub fn duplicate(x) {
  #(x, x)
}
