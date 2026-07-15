pub fn apply(value, function) {
  function(value)
}

pub fn compose(first, second) {
  fn(value) { second(first(value)) }
}

pub fn describe(flag) {
  case flag {
    True -> "yes"
    False -> "no"
  }
}
