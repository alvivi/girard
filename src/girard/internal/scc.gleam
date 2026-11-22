//// Strongly-connected components over a string-keyed graph, as the compiler
//// computes them: a port of petgraph 0.8.3's `TarjanScc` (Pearce's variant of
//// Tarjan's algorithm, `src/algo/scc/tarjan_scc.rs`), which Gleam 1.19.2's
//// `call_graph::into_dependency_order` calls through `tarjan_scc`.
////
//// The port keeps everything that decides the result's order: roots are tried
//// in node order, neighbours in the order given, a node is pushed when it
//// finishes rather than when it is discovered, and a root's component is the
//// stack suffix it dominates followed by the root itself. Components come out
//// in completion order, dependencies first.

import gleam/dict.{type Dict}
import gleam/list
import gleam/result

type Pearce {
  Pearce(
    // The next discovery index; reused once a component completes.
    index: Int,
    // Counts down from above any live index; a completed node's root index.
    component_count: Int,
    // Absent: not yet visited.
    root_index: Dict(String, Int),
    // Finished, non-root nodes; the head is the top of the stack.
    stack: List(String),
    // Completed components, most recently completed first.
    components: List(List(String)),
  )
}

/// Compute strongly-connected components of `nodes` under `edges` (each node's
/// neighbours in visit order), returned dependencies first: a component appears
/// before any component that depends on it. Each component lists its members in
/// the order the compiler infers them.
pub fn components(
  nodes: List(String),
  edges: Dict(String, List(String)),
) -> List(List(String)) {
  let initial =
    Pearce(
      index: 1,
      component_count: 1_000_000_000_000,
      root_index: dict.new(),
      stack: [],
      components: [],
    )
  let final =
    list.fold(nodes, initial, fn(state, node) {
      case dict.has_key(state.root_index, node) {
        True -> state
        False -> visit(state, node, edges)
      }
    })
  list.reverse(final.components)
}

fn visit(
  state: Pearce,
  v: String,
  edges: Dict(String, List(String)),
) -> Pearce {
  let v_index = state.index
  let state =
    Pearce(
      ..state,
      index: v_index + 1,
      root_index: dict.insert(state.root_index, v, v_index),
    )
  let neighbours = result.unwrap(dict.get(edges, v), [])
  let #(state, is_local_root) =
    list.fold(neighbours, #(state, True), fn(acc, w) {
      let #(state, is_local_root) = acc
      let state = case dict.has_key(state.root_index, w) {
        True -> state
        False -> visit(state, w, edges)
      }
      let w_root = root(state, w)
      case w_root < root(state, v) {
        True -> #(
          Pearce(..state, root_index: dict.insert(state.root_index, v, w_root)),
          False,
        )
        False -> #(state, is_local_root)
      }
    })
  case is_local_root {
    False -> Pearce(..state, stack: [v, ..state.stack])
    True -> complete(state, v)
  }
}

// `v` is a root: its component is every stack entry, from the top down, whose
// root index is not below `v`'s, then `v` itself. Each member's root index
// becomes the component count, and the discovery index backtracks by the
// component's size.
fn complete(state: Pearce, v: String) -> Pearce {
  let v_root = root(state, v)
  let count = state.component_count
  let #(popped, rest) =
    list.split_while(state.stack, fn(w) { root(state, w) >= v_root })
  // `popped` is top first; the component lists the stack bottom first, then
  // the root.
  let component = list.reverse([v, ..popped])
  let root_index =
    list.fold(component, state.root_index, fn(root_index, w) {
      dict.insert(root_index, w, count)
    })
  Pearce(
    index: state.index - list.length(component),
    component_count: count - 1,
    root_index:,
    stack: rest,
    components: [component, ..state.components],
  )
}

// A visited node's root index. Every caller has visited the node first, so the
// default is unreachable.
fn root(state: Pearce, node: String) -> Int {
  result.unwrap(dict.get(state.root_index, node), 0)
}
