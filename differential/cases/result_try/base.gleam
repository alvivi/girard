import gleam/result

pub fn result_try(result: Result(Int, Nil)) {
  use v <- result.try(result)
  Ok(v + 1)
}
