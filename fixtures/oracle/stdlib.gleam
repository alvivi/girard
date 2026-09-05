import gleam/list
import gleam/option.{type Option, Some}

pub fn inc_all(xs) {
  list.map(xs, fn(x) { x + 1 })
}

pub fn head(xs) {
  list.first(xs)
}

pub fn lift(x) -> Option(a) {
  Some(x)
}

pub fn fold_sum(xs) {
  list.fold(xs, 0, fn(acc, x) { acc + x })
}
