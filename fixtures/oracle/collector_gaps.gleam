pub type Address {
  Address(BitArray)
}

pub type Formatter {
  Formatter(render: fn(Int) -> String)
}

pub type Config {
  Config(retries: Int, timeout: Int)
}

pub type Box(a) {
  Box(name: a)
}

const size = 20

const retries = 3

const base = Config(1, 30)

pub const updated = Config(..base, retries:)

fn aaa_size() -> Int {
  8
}

fn render(_x: Int) -> String {
  "x"
}

pub fn zero() -> Address {
  Address(<<0:unit(8)-size(size)>>)
}

pub fn sized() -> BitArray {
  <<0:size(aaa_size() * 2)>>
}

pub fn defaults(config: Config) -> Config {
  Config(..config, retries:)
}

pub fn formatter(original: Formatter) -> Formatter {
  Formatter(..original, render:)
}

pub fn with_name(b, name) {
  Box(..b, name:)
}

pub fn name(x: Int, y: String) {
  #(with_name(Box(name: 0), x), with_name(Box(name: ""), y))
}

pub fn pad(value, width) {
  #(value, <<0:size(width)>>)
}

pub fn width(x: Int, y: String) {
  #(pad(x, 8), pad(y, 16))
}
