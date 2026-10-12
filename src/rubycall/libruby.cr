# Биндинги MRI Ruby C API (libruby). Запуск только с воркер-треда
# (см. RubyCall.ruby / PLAN.md) — все rb_* обязаны идти из одного треда,
# держащего GVL.

@[Link("ruby", pkg_config: "ruby")]
lib LibRuby
  alias Value = UInt64 # VALUE (unsigned long, LP64)
  alias Id = UInt64    # ID

  # --- встраивание ---------------------------------------------------------
  fun ruby_init_stack(addr : Value*)  # пометить стек main-треда для GC
  fun ruby_init
  fun ruby_script(name : UInt8*)
  fun ruby_cleanup(v : Int32)

  # --- вызовы ----------------------------------------------------------------
  fun rb_funcallv(recv : Value, mid : Id, argc : Int32, argv : Value*) : Value
  fun rb_funcallv_kw(recv : Value, mid : Id, argc : Int32, argv : Value*, kw_splat : Int32) : Value
  fun rb_block_call(recv : Value, mid : Id, argc : Int32, argv : Value*,
                    func : (Value, Value, Int32, Value*) -> Value, data2 : Value) : Value

  # --- защита от longjmp --------------------------------------------------------
  # Ruby-исключение делает longjmp; без rb_protect оно размотало бы стек
  # Crystal-фиберы. Каждый опасный вызов — только через rb_protect.
  fun rb_protect(proc : (Value -> Value), data : Value, state : Int32*) : Value
  fun rb_eval_string_protect(code : UInt8*, state : Int32*) : Value

  # --- ошибки ----------------------------------------------------------------------
  fun rb_errinfo : Value
  fun rb_set_errinfo(err : Value)
  fun rb_exc_new_cstr(klass : Value, msg : UInt8*) : Value
  fun rb_exc_raise(exc : Value) : NoReturn

  # --- GC: keep-слоты ----------------------------------------------------------------
  # VALUE, удерживаемый из Crystal-кучи, невидим для консервативного GC MRI
  # (фиберы — не нативные стеки воркера). Каждый обёрнутый VALUE живёт в
  # слоте, зарегистрированном через rb_gc_register_address.
  fun rb_gc_register_address(slot : Value*)
  fun rb_gc_unregister_address(slot : Value*)

  # --- конвертация ------------------------------------------------------------------------
  fun rb_ll2inum(v : Int64) : Value
  fun rb_num2ll(v : Value) : Int64
  fun rb_num2dbl(v : Value) : Float64
  fun rb_float_new(v : Float64) : Value
  fun rb_str_new(s : UInt8*, len : Int64) : Value
  fun rb_str_new_cstr(s : UInt8*) : Value
  fun rb_string_value_ptr(v : Value*) : UInt8*
  fun rb_str_strlen(s : Value) : Int64

  # --- массивы / хеши -----------------------------------------------------------------------
  fun rb_ary_new_capa(cap : Int64) : Value
  fun rb_ary_push(ary : Value, v : Value) : Value
  fun rb_ary_entry(ary : Value, i : Int64) : Value
  fun rb_hash_new : Value
  fun rb_hash_aref(h : Value, k : Value) : Value
  fun rb_hash_aset(h : Value, k : Value, v : Value) : Value
  fun rb_hash_size(h : Value) : Value

  # --- символы / идентификаторы ---------------------------------------------------------------
  fun rb_intern(name : UInt8*) : Id
  fun rb_id2name(id : Id) : UInt8*
  fun rb_sym2id(v : Value) : Id
  fun rb_id2sym(id : Id) : Value

  # --- типы / классы ----------------------------------------------------------------------------
  fun rb_obj_class(v : Value) : Value
  fun rb_obj_classname(v : Value) : UInt8*
  fun rb_obj_is_kind_of(v : Value, klass : Value) : Value

  # Глобальные VALUE-классы (данные, не указатели — биндим как UInt64).
  $rb_c_object = rb_cObject : Value
  $rb_c_integer = rb_cInteger : Value
  $rb_c_float = rb_cFloat : Value
  $rb_c_string = rb_cString : Value
  $rb_c_symbol = rb_cSymbol : Value
  $rb_c_array = rb_cArray : Value
  $rb_c_hash = rb_cHash : Value
  $rb_e_runtime_error = rb_eRuntimeError : Value
end

# Хелперы низкого уровня. ВСЁ здесь исполняется на воркер-треде
# (инвариант RubyCall.ruby); локальные переменные обычных методов живут
# на машинном стеке воркера → консервативный GC MRI их видит. VALUE в
# замыканиях/куче Crystal — запрещены (см. keep-слоты).
module RubyCall
  module Helpers
    MAX_ARGS = 32
    ARGV_BUF = 33 # MAX_ARGS + 1 (хвост — kwargs-hash)

    RB_PASS_KEYWORDS = 1

    # Спец-константы определяем в рантайме (eval nil/true/false) — не
    # хардкодим биты VALUE.
    class_property qnil : LibRuby::Value = 0_u64
    class_property qtrue : LibRuby::Value = 0_u64
    class_property qfalse : LibRuby::Value = 0_u64

    # --- fixnum-кодирование (immidiate, без GC) ------------------------------
    # LONG2FIX / FIX2LONG: fixnum = (x << 1) | 1
    def self.ll2fix(x : Int64) : LibRuby::Value
      if x >= -4611686018427387904 && x <= 4611686018427387903
        (x.to_u64! << 1) | 1
      else
        LibRuby.rb_ll2inum(x)
      end
    end

    def self.fix2ll(v : LibRuby::Value) : Int64
      v.to_i64! >> 1
    end

    # --- кэш идентификаторов -----------------------------------------------------
    @@mids = {} of String => LibRuby::Id

    def self.mid_for(name : String) : LibRuby::Id
      @@mids[name] ||= LibRuby.rb_intern(name)
    end

    # --- keep-слоты: временный корень для VALUE на время операции -----------------
    def self.keep(v : LibRuby::Value) : Pointer(LibRuby::Value)
      slot = Pointer(LibRuby::Value).malloc(1)
      slot.value = v
      LibRuby.rb_gc_register_address(slot)
      slot
    end

    def self.unkeep(slot : Pointer(LibRuby::Value)) : Nil
      LibRuby.rb_gc_unregister_address(slot)
    end

    # --- rb_protect-обёртка ---------------------------------------------------------
    # tramp — нетипизированный трамплин (->Helpers.xxx); data — VALUE,
    # уже укоренённый (контейнер/слот/стек). При state != 0 вытаскиваем
    # rb_errinfo, чистим его и кидаем RubyError.
    def self.protect(context : String, tramp : (LibRuby::Value -> LibRuby::Value), data : LibRuby::Value) : LibRuby::Value
      state = 0_i32
      result = LibRuby.rb_protect(tramp, data, pointerof(state))
      if state != 0
        err = LibRuby.rb_errinfo
        LibRuby.rb_set_errinfo(qnil)
        raise RubyError.from_value(err, context)
      end
      result
    end

    # --- главный драйвер вызова --------------------------------------------------------
    # data-массив: [recv, mid(fix), argc(fix), block_id(fix), *args, kw_hash|nil]
    # Контейнер рутируется сам; все промежуточные VALUE — на стеке обычных
    # методов воркера.
    def self.call(recv_slot : Pointer(LibRuby::Value), name : String,
                  args : Enumerable?, kwargs : Hash(String, RbArg)? = nil,
                  block_id : Int64 = 0) : LibRuby::Value
      mid = mid_for(name)
      n = args.try(&.size) || 0
      raise Error.new("too many ruby args (max #{MAX_ARGS})") if n > MAX_ARGS

      slot = keep(LibRuby.rb_ary_new_capa(n + 5))
      begin
        data = slot.value
        LibRuby.rb_ary_push(data, recv_slot.value)
        LibRuby.rb_ary_push(data, ll2fix(mid.to_i64))
        LibRuby.rb_ary_push(data, ll2fix(n.to_i64))
        LibRuby.rb_ary_push(data, ll2fix(block_id))
        args.try &.each { |a| LibRuby.rb_ary_push(data, Conversion.from_crystal(a)) }
        if kwargs && !kwargs.empty?
          LibRuby.rb_ary_push(data, hash_from(kwargs))
        else
          LibRuby.rb_ary_push(data, qnil)
        end
        protect("rb_funcall(#{name})", ->Helpers.call_tramp(LibRuby::Value), data)
      ensure
        unkeep(slot)
      end
    end

    # Трамплин rb_protect: локальные — на стеке воркера → видны GC MRI.
    def self.call_tramp(data : LibRuby::Value) : LibRuby::Value
      recv = LibRuby.rb_ary_entry(data, 0)
      mid = fix2ll(LibRuby.rb_ary_entry(data, 1)).to_u64!
      argc = fix2ll(LibRuby.rb_ary_entry(data, 2)).to_i32
      block_id = fix2ll(LibRuby.rb_ary_entry(data, 3)).to_i64

      argv = uninitialized LibRuby::Value[ARGV_BUF]
      i = 0
      while i < argc
        argv[i] = LibRuby.rb_ary_entry(data, 4 + i)
        i += 1
      end

      if block_id != 0
        return LibRuby.rb_block_call(recv, mid, argc, argv.to_unsafe,
          ->RubyCall.block_tramp(LibRuby::Value, LibRuby::Value, Int32, Pointer(LibRuby::Value)), ll2fix(block_id))
      end

      kw = LibRuby.rb_ary_entry(data, 4 + argc)
      if kw != qnil
        argv[argc] = kw
        return LibRuby.rb_funcallv_kw(recv, mid, argc + 1, argv.to_unsafe, RB_PASS_KEYWORDS)
      end

      LibRuby.rb_funcallv(recv, mid, argc, argv.to_unsafe)
    end

    # rb_num2ll может кинуть RangeError (bignum > i64) — через protect,
    # вызывающий при переполнении оставит объект обёрткой.
    def self.num2ll_tramp(data : LibRuby::Value) : LibRuby::Value
      Helpers.ll2fix(LibRuby.rb_num2ll(data))
    end

    # kwargs-хеш: в Ruby 3 ключевые слова обязаны иметь символьные ключи
    # (строковые → ArgumentError: missing keywords).
    def self.hash_from(kwargs : Hash(String, RbArg)) : LibRuby::Value
      h = LibRuby.rb_hash_new # контейнер рутирует элементы после aset
      kwargs.each do |k, v|
        pk = LibRuby.rb_id2sym(LibRuby.rb_intern(k.to_unsafe))
        pv = Conversion.from_crystal(v)
        LibRuby.rb_hash_aset(h, pk, pv)
      end
      h
    end

    # rb_eval_string_protect — protect встроен.
    def self.eval_str(code : String) : LibRuby::Value
      state = 0_i32
      result = LibRuby.rb_eval_string_protect(code.to_unsafe, pointerof(state))
      if state != 0
        err = LibRuby.rb_errinfo
        LibRuby.rb_set_errinfo(qnil)
        raise RubyError.from_value(err, "eval(#{code[0, 40]})")
      end
      result
    end

    def self.true?(v : LibRuby::Value) : Bool
      v != qnil && v != qfalse
    end

    def self.kind_of?(v : LibRuby::Value, klass : LibRuby::Value) : Bool
      LibRuby.rb_obj_is_kind_of(v, klass) == qtrue
    end
  end
end
