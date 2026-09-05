pub type User {
  User(name: String, age: Int)
}

pub fn name_of(u: User) -> String {
  u.name
}

pub fn birthday(u: User) -> User {
  User(..u, age: u.age + 1)
}

pub fn make(n) {
  User(name: n, age: 0)
}
