# rubycall.cr

**RubyCall** — calling MRI Ruby from Crystal, in-process over **libruby**
(the Ruby C API). It mirrors `pycall.cr` (a port of the pycall gem):
there Python is embedded via libpython, here Ruby is embedded via
libruby. No existing Crystal shard covers this (Anyolite is mruby with
the opposite emphasis; crystalruby is Crystal inside Ruby).

Implemented and verified against system Ruby 3.3.8 (`pkg-config "ruby"`,
libruby 3.3); build and specs ran 3× in a row, stable green.

## Installation

```yaml
dependencies:
  rubycall_cr:
    github: OrelSokolov/rubycall.cr
```

```sh
shards install
```

Requires ruby-dev headers (`pkg-config "ruby"`).

## Usage

```crystal
require "rubycall_cr"

RubyCall.init!

math = RubyCall.import("Math")          # rb_const_get → RWrap
pi = math.const_get("PI")

obj = RubyCall.eval("Rational(37, 10)")
obj.floor                              # method_missing → rb_funcall
arr = RubyCall.eval("[3, 1, 2]")
arr.size                               # => 3
arr[0]                                 # rb_ary_entry

sorted = RubyCall.eval("[3, 1, 2].sort")
```

See `examples/smoke.cr` for an end-to-end tour of the API (prints
"SMOKE OK").

## Feature comparison vs pycall.cr (and the pycall gem)

| Feature | pycall.cr / pycall gem | rubycall.cr | Status |
|---|---|---|---|
| `init!` | `PyCall.init!` (`Py_Initialize`) | `RubyCall.init!` — `ruby_init` on the worker thread | ✅ |
| Import | `PyCall.import_module` → `PyWrap` | `rb_const_get(Object, :Math)` → `RWrap` / `rb_eval_string` | ✅ |
| `method_missing` (attr / call / setattr) | `macro method_missing` | `macro method_missing` → `rb_funcall` + `rb_intern` | ✅ |
| Operators | `__add__` etc. | `rb_funcall(recv, :+, 1, other)` | ✅ |
| Comparisons | `PyObject_RichCompare` | `rb_funcall(recv, :==, ...)` | ✅ |
| `[] / []=` | GetItem/SetItem | `rb_ary_entry` / `rb_hash_aref` / funcall `:[]` | ✅ |
| Collection wrappers | `PyCall::List/Dict/Tuple/Set` | `RArray` / `RHash` (dispatch on `rb_type`: T_ARRAY/T_HASH/T_STRING) | ✅ |
| Errors | `PyError` (type/value/traceback) | `RubyCall::RubyError` (`rb_errinfo` → class/message/backtrace) | ✅ |
| Conversion | `Conversion.from_crystal/to_crystal` | Same both ways: nil/bool/int/float/string/symbol/array/hash; bignum outside i64 stays `RWrap` | ✅ |
| Blocks/Procs → callable | `PyCall::Callable` (libffi) | `rb_block_call` + data-wrap callback trampolines (`with_block`) | ✅ |
| `eval`/`exec` | via `__main__` | `rb_eval_string_protect` | ✅ |
| kwargs | python kwargs | Ruby 3 keyword args — symbol keys only (`rb_id2sym(rb_intern(key))`; string keys silently raise `missing keywords`) | 🔶 |
| GIL/GVL discipline | `PyCall.gil` (PyGILState) + MUTEX | Global `MUTEX` + dedicated worker thread (see below); no `PyGILState_Check` fast path | 🔶 |

## Threading model (mandatory, not optional)

MRI has no `PyGILState_Ensure`, `ruby_init` must run on the main thread,
and Crystal fibers migrate between OS threads. Therefore:

1. One global `RubyCall::MUTEX` serializes request submission — exactly
   one operation in flight, so composite calls (funcall → convert →
   wrap) never interleave.
2. A dedicated worker thread is the only place `rb_*` runs. One native
   stack ⇒ MRI's conservative GC scans it correctly; the GVL never
   migrates across threads.
3. Replies go to per-request channels (a pipe-based `BlockingQueue` —
   Crystal `Channel` cannot be used from a raw thread); the requesting
   fiber waits for its own result.
4. Direct `LibRuby.rb_*` calls outside the worker are forbidden by code
   invariant (all helpers route through `RubyCall.dispatch`).

Additional hard invariants:

- Every `rb_funcall`/`rb_eval_string` goes through `rb_protect`
  (MRI's `longjmp` would unwind a Crystal fiber's stack); `state != 0`
  → `rb_errinfo` → `RubyError`.
- Every wrapped `VALUE` lives in a keep-slot registered with
  `rb_gc_register_address` (MRI's GC does not see the Crystal heap or
  fiber stacks); unregistration happens in finalizers (deferred worker
  requests, like pycall's pending decrefs).

## Deviations & Crystal-specific notes

- `Object` is forbidden as a Crystal generic argument → `RbValue`/
  `RbResult`/`RbArg` union aliases.
- `Math::PI` and `floor` are not module methods in Ruby: constants via
  `const_get`, `floor` on Numerics.
- `yield` / Crystal `STDERR.puts` inside a `ruby {}` block on the worker
  are forbidden — iteration via `to_a`, output only from the requesting
  fiber.
- `rb_ary_len` is absent in 3.3 — size via funcall.

## Testing

```sh
cd rubycall.cr && crystal spec            # 15 examples, 0 failures
cd rubycall.cr && crystal run examples/smoke.cr
```

The suite runs the full oracle (`oracle/expected.yml`, recorded with
`/usr/bin/ruby`) plus stress: 8 fibers × 100 iterations on a shared
array and parallel `with_block` blocks from 4 fibers.
