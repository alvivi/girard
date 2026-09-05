import differential/labelled.{println}

pub fn shadowed_callee_labels() {
  let println = fn(who: String) -> String { who }
  println(message: "hi")
}
