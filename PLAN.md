# rubycall.cr — «RubyCall»: вызов Ruby из Crystal

Зеркало `pycall.cr` (порт гема pycall): там Python из Crystal поверх
libpython, здесь — **MRI Ruby из Crystal поверх libruby**.
Готового аналога в шардах нет (Anyolite — mruby с обратным акцентом,
crystalruby — наоборот, Crystal внутри Ruby).

## Технология (как у pycall.cr)

`@[Link("ruby-3.4")]` + биндинги C API (`ruby_init`, `rb_funcall`,
`rb_str_new`, `rb_ary_*`, `rb_hash_*`, `rb_protect`, `rb_errinfo`),
обёртка `RWrap` вокруг `VALUE` с `method_missing`-макросом →
`rb_funcall`, конвертация типов обе стороны, `rb_errinfo` → исключение.

## Соответствие фич (1-в-1 с pycall.cr / геммою pycall)

| pycall.cr                             | rubycall.cr                          |
|----------------------------------------|--------------------------------------|
| `PyCall.init!`                         | `RubyCall.init!` (ruby_init на main-треде) |
| `import_module` → PyWrap               | `rb_const_get(Object, :Math)` → RWrap / `rb_eval_string` |
| `method_missing` (attr/call/setattr)   | `rb_funcall` + `rb_intern`           |
| операторы → `__add__` и т.п.           | `rb_funcall(recv, :+, 1, other)`     |
| сравнения → PyObject_RichCompare       | `rb_funcall(recv, :==, ...)`         |
| `[] / []=` → GetItem/SetItem           | `rb_ary_entry` / `rb_hash_aref` / `rb_obj_aset_result` (funcall :[]) |
| `List/Dict/Tuple/Set`-обёртки          | `Array`/`Hash`/`String`/`Symbol`-обёртки (T_ARRAY/T_HASH/T_STRING по `rb_type`) |
| `PyError` (type/value/traceback)       | `RubyCall::RubyError` (rb_errinfo → class/message/backtrace) |
| `Conversion.from_crystal/to_crystal`   | то же (nil/bool/int/float/string/array/hash/symbol) |
| `PyCall::Callable` (Proc → callable)   | `rb_block_call` + Data-Wrap колбэка  |
| `eval/exec` через __main__             | `rb_eval_string_protect`             |
| глобальный `MUTEX` + GIL (PyGILState)  | глобальный `MUTEX` + GVL-воркер (см. ниже) |
| oracle-спеки против python3            | oracle-спеки против `ruby -e`        |

## Глобальная блокировка — обязательный элемент (не опция!)

Как и в pycall.cr: **один глобальный мьютекс на весь шард**, НО механика
другая, потому что у MRI нет `PyGILState_Ensure` (взять GVL с любого
треда), `ruby_init` обязан идти на main-треде, а Crystal-фибера между
вызовами мигрирует между OS-тредами.

Схема — **мьютекс + выделенный Ruby-воркер-тред**:

```
фибера A ─┐                        ┌─→ воркер (единственный держит GVL,
фибера B ─┼─ MUTEX → очередь заявок─┤     единственный трогает VALUE,
фибера C ─┘   (канал)              └─←   живёт на одном стеке)
                 └──── ответ в per-request канал ──── фибере-автору
```

1. `RubyCall::MUTEX` (глобальный, как `PyCall::MUTEX`) — сериализует
   постановку заявок: в полёте ровно одна операция, interleaving
   составных вызовов (funcall → convert → wrap) исключён.
2. Воркер-тред — единственное место исполнения `rb_*`. Один нативный
   стек ⇒ консервативный GC MRI сканирует его корректно; GVL никогда
   не переходит между тредами.
3. Ответ — в per-request канал, фибера-автор ждёт свой результат
   (пересечение фибер невозможно).
4. Быстрого пути как `PyGILState_Check` здесь НЕТ и не надо: any-call
   всегда «заявка → воркер». Прямые вызовы `LibRuby.rb_*` вне воркера
   запрещены инвариантом кода (все хелперы — через `RubyCall.dispatch`).

## Три отличия от pycall.cr (главные риски)

1. **`rb_protect` на каждый вызов — обязателен.** Python при ошибке
   возвращает NULL + PyErr; MRI делает `longjmp`, который размотал бы
   стек Crystal-фиберы. Каждый `rb_funcall`/`rb_eval_string` — только
   через `rb_protect(func, arg, &state)`, state != 0 → `rb_errinfo` →
   `RubyError` (класть обратно через `rb_set_errinfo(Qnil)`).
2. **GC MRI не видит Crystal-кучу и стеки фибер.** Каждый завернутый
   `VALUE` живёт в слоте keep-таблицы, зарегистрированном через
   `rb_gc_register_address(&slot)`; снятие — в финалайзере. Регистрация
   и снятие требуют GVL ⇒ тоже заявки воркеру (отложенные, как
   pending-decrefs у гема pycall — тот же паттерн в обратную сторону).
   Иначе Ruby соберёт объект, на который ссылается живой RWrap.
3. **`ruby_init` на main-треде** до любых `rb_*` (инвариант как
   `Py_Initialize` до `PyGILState_*` в pycall.cr — там на это был
   отдельный краш). `init!` — под тем же `MUTEX`.

## Статус

**РЕАЛИЗОВАНО И ВЕРИФИЦИРОВАНО** (системный Ruby 3.3.8, `pkg-config "ruby"`,
libruby 3.3; сборка/спеки проверены 3× подряд — стабильно зелёные).

- `crystal spec` — 15 examples, 0 failures: полный oracle
  (`oracle/expected.yml`, снят с `/usr/bin/ruby`) + стресс
  «8 фибер × 100 итераций» на shared-массиве + параллельные
  `with_block`-блоки из 4 фибер.
- `crystal run examples/smoke.cr` — сквозной обход API, «SMOKE OK».

### Что легло в код (соответствие разделу «Порядок»)

1. `src/rubycall/libruby.cr` — биндинги + `Helpers`: `rb_protect`-обёртка
   с трамплинами, keep-слоты `rb_gc_register_address`, кэш `mid_for`,
   драйвер `call` (data-массив `[recv, mid, argc, block_id, *args, kw_hash]`,
   рутируемый через `rb_ary_*` — все промежуточные VALUE на стеке воркера).
2. `src/rubycall/rberror.cr` — `RubyError` (ruby_class/message/backtrace,
   снимаются сразу в воркере через тот же funcall-драйвер).
3. `src/rubycall/robj_wrapper.cr` — `RWrap` (`method_missing`-макрос →
   `__funcall`, операторы через `{% for %}`, `[]/[]=`, `with_block`,
   kwargs-нормализация `to_arg`), `RArray`/`RHash`-обёртки.
4. `src/rubycall/conversion.cr` — nil/bool/int/float/string/symbol/array/hash
   в обе стороны; bignum вне i64 → остаётся `RWrap`.
5. `src/rubycall_cr.cr` — `MUTEX` + воркер-тред + `BlockingQueue` на pipe
   (Channel из сырого треда нельзя), `init!` (воркер сам делает
   `ruby_init_stack` + `ruby_init` + снимок qnil/qtrue/qfalse через eval),
   `eval/exec/import`, BLOCKS-реестр + `block_tramp` (`rb_block_call`).

### Находки (грабли, см. также инварианты выше)

- **kwargs в Ruby 3 — только символьные ключи**: хеш со строковыми
  ключами молча даёт `ArgumentError: missing keywords` (воспроизведено
  чистым C-тестом с `rb_funcallv_kw`). `Helpers.hash_from` делает
  `rb_id2sym(rb_intern(key))`.
- `Math::PI`/`floor` — в Ruby не методы модуля: константы через
  `const_get`, `floor` у Numeric (`Rational(37,10).floor`).
- `Object` запрещён в generic-типах Crystal → `RbValue`/`RbResult`/`RbArg`
  union-алиасы; Proc-инвариантность → `nil.as(RbResult)` в хвосте
  dispatch-замыканий.
- `uninitialized LibRuby::Value[N]` не парсится с выражением → константа
  `ARGV_BUF = 33`.
- yield/`STDERR.puts` (Crystal IO) внутри `ruby {}`-блока на воркере
  запрещены → each через to_a, вывод только из фибер-автора.
- `rb_ary_len` в 3.3 нет — size через funcall; `ConditionVariable` —
  внутренний API stdlib, очередь на `LibC.pipe`.

## Запуск

```sh
cd rubycall.cr && crystal spec        # ruby-dev (pkg-config "ruby")
cd rubycall.cr && crystal run examples/smoke.cr
```
