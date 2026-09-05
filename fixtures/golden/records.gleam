pub type User {
  User(name: String, age: Int)
}

pub fn name(user: User) {
  user.name
}

pub fn birthday(user: User) {
  User(..user, age: user.age + 1)
}
