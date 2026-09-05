import gleam/result

pub fn result_try(rec_0: Result(Int, Nil)) {
  use v <- result.try(rec_0)
  Ok(v + 1)
}
