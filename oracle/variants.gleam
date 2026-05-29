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
