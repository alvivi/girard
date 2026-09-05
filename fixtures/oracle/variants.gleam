pub type Shape {
  Circle(radius: Float, name: String)
  Square(side: Float, name: String)
}

pub fn name_of(s: Shape) -> String {
  s.name
}

pub fn relabel(s: Shape, to: String) -> Shape {
  case s {
    Circle(radius:, ..) -> Circle(radius:, name: to)
    Square(side:, ..) -> Square(side:, name: to)
  }
}

pub type Node(a) {
  Branch(value: a, kids: List(Node(a)))
  Leaf(value: a)
}

// `kids` exists only in `Branch`; binding with `as` after the variant pattern
// narrows the value, making the non-shared field reachable.
pub fn kids_as(n: Node(a)) -> List(Node(a)) {
  case n {
    Branch(..) as b -> b.kids
    Leaf(..) -> []
  }
}

// The bare subject variable is narrowed to `Branch` inside that clause, so
// `n.kids` is reachable directly.
pub fn kids_subject(n: Node(a)) -> List(Node(a)) {
  case n {
    Branch(..) -> n.kids
    Leaf(..) -> []
  }
}

// A record update via the `Branch` constructor copies the kept field `kids`,
// which is not shared by every variant of `Node`. The value is narrowed to
// `Branch` first, which is what makes the update well-typed.
pub fn rekey(n: Node(a), v: a) -> Node(a) {
  case n {
    Branch(..) as b -> Branch(..b, value: v)
    Leaf(..) -> Leaf(value: v)
  }
}
