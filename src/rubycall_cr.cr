# rubycall_cr — «RubyCall»: вызов MRI Ruby из Crystal поверх libruby.
# Зеркало pycall.cr. Точка входа: require "rubycall_cr".
# (Thread — уже в prelude, отдельного require не требует.)

require "./rubycall/libruby"
require "./rubycall/types"
require "./rubycall/rberror"
require "./rubycall/conversion"
require "./rubycall/robj_wrapper"

module RubyCall
  VERSION = "0.1.0"

  # Глобальная блокировка на ВЕСЬ доступ к Ruby из Crystal (как
  # PyCall::MUTEX в pycall.cr). Составные операции (funcall→convert→wrap)
  # атомарны, interleaving фибер на разных тредах исключён.
  MUTEX = Mutex.new

  # Блокирующая очередь «сырой тред ↔ фибера». Channel непригоден (воркер
  # без планировщика фибер), ConditionVariable — внутренний API Crystal.
  #
  # Инвариант: глобальный MUTEX гарантирует ровно одну заявку в полёте,
  # поэтому буфер @items не требует блокировок; pipe-семафор (1 байт на
  # заявку) переводит pop в блокирующее чтение ядра без CPU.
  class BlockingQueue(T)
    def initialize
      @fds = uninitialized LibC::Int[2] # StaticArray(Int, 2)
      raise Error.new("pipe(2) failed") if LibC.pipe(@fds) != 0
      @items = Array(T).new
    end

    def push(x : T) : Nil
      @items << x
      byte = 1_u8
      r = LibC.write(@fds[1], pointerof(byte), 1)
      raise Error.new("queue write failed") if r < 0
    end

    def pop : T
      byte = 0_u8
      # блокирующее чтение (EINTR-повторы)
      while LibC.read(@fds[0], pointerof(byte), 1) < 0
      end
      @items.shift
    end
  end

  @@queue = BlockingQueue(Proc(RbResult)).new
  @@resp = BlockingQueue(RbResult | Exception).new # один ответ в полёте (сериализует MUTEX)

  @@worker : Thread?
  @@initialized = false

  # Блоки Crystal → ruby-блоки (rb_block_call). Доступ только с воркера
  # (под глобальным MUTEX) — обычный Hash без доп. блокировок.
  BLOCKS = {} of Int64 => Proc(Array(RbValue), RbValue)
  @@block_seq = 0_i64

  def self.register_block(blk : Proc(Array(RbValue), RbValue)) : Int64
    @@block_seq += 1
    BLOCKS[@@block_seq] = blk
    @@block_seq
  end

  def self.unregister_block(id : Int64) : Nil
    BLOCKS.delete(id)
  end

  # Трамплин rb_block_call: вызывается Ruby-ом (GIL/GVL уже на воркере).
  # data2 = fixnum(id реестра). Исключение кристалла → rb_exc_raise —
  # longjmp поймается внешним rb_protect драйвера.
  def self.block_tramp(first : LibRuby::Value, data2 : LibRuby::Value,
                       argc : Int32, argv : Pointer(LibRuby::Value)) : LibRuby::Value
    id = Helpers.fix2ll(data2).to_i64
    blk = BLOCKS[id]?
    unless blk
      LibRuby.rb_exc_raise(LibRuby.rb_exc_new_cstr(
        LibRuby.rb_e_runtime_error, "rubycall: lost block registry entry"))
    end

    vals = if argc == 0
             [Conversion.to_crystal(first)] of RbValue
           else
             Array(RbValue).new(argc) { |i| Conversion.to_crystal(argv[i]) }
           end

    result = begin
      blk.call(vals)
    rescue ex
      LibRuby.rb_exc_raise(LibRuby.rb_exc_new_cstr(
        LibRuby.rb_e_runtime_error, "rubycall block raised: #{ex.message}".to_unsafe))
    end

    Conversion.from_crystal(result)
  end

  # --- инициализация --------------------------------------------------------

  # Идемпотентна; VM поднимается ВНУТРИ воркер-треда: он же становится
  # main-Ruby-тредом (один стек → консервативный GC MRI корректен,
  # GVL никогда не переходит между тредами).
  def self.init! : Bool
    return false if @@initialized
    MUTEX.synchronize do
      return false if @@initialized
      @@worker = Thread.new { worker_loop }
      dispatch(-> { RubyCall.do_init; nil.as(RbResult) })
      @@initialized = true
    end
    true
  end

  def self.initialized? : Bool
    @@initialized
  end

  def self.ensure_init! : Nil
    init! unless @@initialized
  end

  def self.worker_loop : Nil
    loop do
      fn = @@queue.pop
      res = begin
        fn.call
      rescue ex
        ex
      end
      @@resp.push(res)
    end
  end

  # На воркере: стек воркера = main-стек Ruby; снимок qnil/qtrue/qfalse.
  def self.do_init : Nil
    dummy = uninitialized LibRuby::Value
    LibRuby.ruby_init_stack(pointerof(dummy))
    LibRuby.ruby_init()
    LibRuby.ruby_script("rubycall")

    state = 0_i32
    Helpers.qnil = LibRuby.rb_eval_string_protect("nil", pointerof(state))
    raise Error.new("ruby eval(nil) failed (state=#{state})") if state != 0
    Helpers.qtrue = LibRuby.rb_eval_string_protect("true", pointerof(state))
    raise Error.new("ruby eval(true) failed (state=#{state})") if state != 0
    Helpers.qfalse = LibRuby.rb_eval_string_protect("false", pointerof(state))
    raise Error.new("ruby eval(false) failed (state=#{state})") if state != 0

    # sanity: интерпретатор жив, исключения доходят
    one = Helpers.eval_str("1 + 1")
    raise Error.new("ruby sanity check failed") unless Helpers.fix2ll(one) == 2
  end

  # --- диспетчеризация ---------------------------------------------------------

  private def self.dispatch(fn : Proc(RbResult)) : RbResult
    @@queue.push(fn)
    res = @@resp.pop
    raise res if res.is_a?(Exception) # исключение из воркера (в т.ч. RubyError)
    res
  end

  # Единая точка входа для ЛЮБОГО обращения к Ruby.
  # - не на воркере: под глобальным MUTEX заявка уходит воркеру;
  # - на воркере (вложенный вызов): исполнить напрямую — мьютекс
  #   нереентерабелен, быстрый путь обязателен (аналог PyGILState_Check).
  def self.ruby(&fn : Proc(RbResult)) : RbResult
    ensure_init!
    if on_worker?
      fn.call
    else
      MUTEX.synchronize { dispatch(fn) }
    end
  end

  def self.on_worker? : Bool
    Thread.current == @@worker
  end

  # Снятие keep-слота из финалайзера (GC-тред Crystal): на воркере —
  # сразу; иначе заявкой (MUTEX; тред просто ждёт — дедлока нет, цикла
  # ожиданий не возникает). При мёртвом воркере — утечка лучше краша.
  def self.release(slot : Pointer(LibRuby::Value)) : Nil
    if on_worker?
      Helpers.unkeep(slot)
    else
      begin
        MUTEX.synchronize { dispatch(-> { Helpers.unkeep(slot); nil.as(RbResult) }) }
      rescue
      end
    end
  end

  # --- публичный API ------------------------------------------------------------

  def self.eval(code : String) : RbValue
    ruby { Conversion.to_crystal(Helpers.eval_str(code)) }.as(RbValue)
  end

  def self.exec(code : String) : Nil
    eval(code)
    nil
  end

  # Константа/модуль верхнего уровня: Math, Object, GC...
  def self.import(name : String | Symbol) : RbValue
    eval(name.to_s).as(RbValue)
  end

  def self.builtins
    import("Kernel")
  end

  # Ruby-строка версии: "3.4.5"
  def self.ruby_version : String
    eval("RUBY_VERSION").to_s
  end

  def self.callable?(obj : RbValue) : Bool
    return false unless w = obj.is_a?(RWrap) ? obj : nil
    w.respond_to?(:call)
  end
end
