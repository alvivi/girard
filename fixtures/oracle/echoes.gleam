import gleam/int

pub fn piped(x: Int) -> Int {
  x |> echo
}

pub fn generic(x) {
  x |> echo
}

pub fn labelled(x: Int) -> Int {
  x |> echo as "x"
}

pub fn middle(x: Int) -> String {
  x |> echo |> int.to_string
}

pub fn prefix(x: Int, label: String) -> Int {
  echo x as label
}

pub fn asserted(x: Bool, label: String) -> Nil {
  assert x as label
}

pub fn let_asserted(x: Result(Int, Nil), label: String) -> Int {
  let assert Ok(n) = x as label
  n
}

pub fn outer_scope(r: Result(Int, Nil), x: String) -> Int {
  let assert Ok(x) = r as x
  x
}

pub fn later_message(r: Result(Int, Nil)) -> Int {
  let assert Ok(n) = r as describe(r)
  n
}

fn describe(_r: Result(Int, Nil)) -> String {
  "r"
}
