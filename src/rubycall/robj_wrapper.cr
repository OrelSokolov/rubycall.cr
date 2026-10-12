# RWrap — зеркало PyWrap из pycall.cr: обёртка VALUE с keep-слотом GC,
# method_missing-диспетчеризация → rb_funcall, операторы, []/[]=.
#
# В отличие от Python, в Ruby любой атрибут — это сообщение/method call,
# поэтому нет дихотомии «callable/не-callable»: голый `obj.pi` ВСЕГДА
# вызов метода pi — семантика 1-в-1 с самим Ruby.

module RubyCall
  class RWrap
    OPERATOR_NAMES = {
      "+":  "+",
      "-":  "-",
      "*":  "*",
      "/":  "/",
      "%":  "%",
      "**": "**",
      "<<": "<<",
      ">>": ">>",
      "&":  "&",
      "|":  "|",
      "^":  "^",
    }

    @keep : Pointer(LibRuby::Value)

    # Только на воркере: v укореняется в зарегистрированном слоте.
    def initialize(v : LibRuby::Value)
      @keep = Helpers.keep(v)
    end

    def value : LibRuby::Value
      @keep.value
    end

    def finalize
      RubyCall.release(@keep)
    rescue
    end

    # --- method_missing → rb_funcall -----------------------------------

    macro method_missing(call)
      {% if call.name.id.stringify.ends_with?('=') && call.args.size == 1 && !call.named_args %}
        __funcall({{call.name.id.stringify}}, {{call.args.first}})
      {% else %}
        __funcall({{call.name.id.stringify}}{% for a in call.args %}, {{a}}{% end %}{% if call.named_args %}{% for na in call.named_args %}, {{na.name.id}}: {{na.value}}{% end %}{% end %})
      {% end %}
    end

    # Ruby-семантика: метод с 0 аргументов == голый атрибут → просто funcall.
    def __funcall(name : String, *args, **kwargs) : RbValue
      RubyCall.ruby do
        Conversion.to_crystal(Helpers.call(@keep, name, args, RWrap.kwargs_hash(kwargs)))
      end.as(RbValue)
    end

    # NamedTuple kwargs → Hash(String, RbArg). Литералы приходят как
    # Int32/Float32 — нормализуем в Int64/Float64.
    def self.to_arg(v) : RbArg
      case v
      when Int then v.to_i64
      when Float then v.to_f64
      when Bool, Nil, String, Symbol, RWrap then v
      else raise RubyCall::Error.new("Unsupported kwarg type #{v.class}")
      end
    end

    def self.kwargs_hash(kwargs) : Hash(String, RbArg)?
      return nil if kwargs.empty?
      h = {} of String => RbArg
      kwargs.each { |k, v| h[k.to_s] = RWrap.to_arg(v) }
      h
    end

    # Вызов с блоком Crystal (Proc), прокинутым как ruby-блок.
    def with_block(name : String, *args, **kwargs, &blk : Array(RbValue) -> RbValue) : RbValue
      RubyCall.ruby do
        kw = RWrap.kwargs_hash(kwargs)
        id = RubyCall.register_block(blk)
        begin
          Conversion.to_crystal(Helpers.call(@keep, name, args, kw, id))
        ensure
          RubyCall.unregister_block(id)
        end
      end.as(RbValue)
    end

    # --- операторы → funcall ------------------------------------------------

    {% for op, mid in OPERATOR_NAMES %}
      def {{op.id}}(other) : RbValue
        __funcall({{mid}}, other)
      end
    {% end %}

    def - : RbValue
      __funcall("-@")
    end

    def ~ : RbValue
      __funcall("~")
    end

    # --- сравнения -------------------------------------------------------------

    def ==(other) : Bool
      __funcall_bool("==", other)
    end

    def !=(other) : Bool
      __funcall_bool("!=", other)
    end

    def <(other) : Bool
      __funcall_bool("<", other)
    end

    def <=(other) : Bool
      __funcall_bool("<=", other)
    end

    def >(other) : Bool
      __funcall_bool(">", other)
    end

    def >=(other) : Bool
      __funcall_bool(">=", other)
    end

    def __funcall_bool(name : String, other) : Bool
      v = __funcall(name, other)
      !v.nil? && v != false # ruby-истинность
    end

    # --- индексация -----------------------------------------------------------------

    def [](*keys) : RbValue
      __funcall("[]", *keys)
    end

    def []=(*keys, value) : RbValue
      __funcall("[]=", *keys, value)
    end

    # --- представление ------------------------------------------------------------

    def to_s(io : IO) : Nil
      io << __funcall("to_s").to_s
    end

    def inspect(io : IO) : Nil
      io << __funcall("inspect").to_s
    end

    def respond_to?(name : String | Symbol) : Bool
      __funcall_bool("respond_to?", name.to_s)
    end

    def ruby_class_name : String
      RubyCall.ruby { String.new(LibRuby.rb_obj_classname(value)) }
    end

    def kind_of_ruby_class?(klass : self) : Bool
      RubyCall.ruby { Helpers.true?(LibRuby.rb_obj_is_kind_of(value, klass.value)) }
    end

    def same?(other : self) : Bool
      value == other.value
    end
  end

  # Обёртка Ruby Array.
  class RArray < RWrap
    def size : Int64
      RubyCall.ruby { Helpers.fix2ll(Helpers.call(@keep, "length", nil, nil)) }.as(Int64)
    end

    def length : Int64
      size
    end

    # rb_ary_entry не может кинуть; массив укоренён слотом RWrap.
    # NOTE: yield внутри ruby{}-блока запрещён (захваченный блок) —
    # материализуем через to_a и итерируем на кристал-стороне.
    def each
      to_a.each { |v| yield v }
      self
    end

    def to_a : Array(RbValue)
      RubyCall.ruby do
        n = size
        Array(RbValue).new(n) { |i| Conversion.to_crystal(LibRuby.rb_ary_entry(value, i)) }
      end.as(Array(RbValue))
    end

    def <<(item) : self
      __funcall("<<", item)
      self
    end

    def push(*items) : self
      items.each { |i| __funcall("<<", i) }
      self
    end

    def sort! : self
      __funcall("sort!")
      self
    end

    def include?(item) : Bool
      __funcall_bool("include?", item)
    end
  end

  # Обёртка Ruby Hash.
  class RHash < RWrap
    def size : Int64
      RubyCall.ruby { Helpers.fix2ll(LibRuby.rb_hash_size(value)) }.as(Int64)
    end

    def length : Int64
      size
    end

    def fetch(key) : RbValue
      RubyCall.ruby { Conversion.to_crystal(LibRuby.rb_hash_aref(value, Conversion.from_crystal(key))) }.as(RbValue)
    end

    def [](key) : RbValue
      v = fetch(key)
      raise RubyError.new("KeyError", "key not found: #{key.inspect}", nil) if v.nil?
      v
    end

    def []=(key, val) : RbValue
      __funcall("[]=", key, val)
    end

    def has_key?(key) : Bool
      __funcall_bool("key?", key)
    end

    def delete(key) : RbValue
      __funcall("delete", key)
    end

    def each
      keys.to_a.each do |k|
        v = fetch(k)
        yield({k, v})
      end
      self
    end

    def keys : RArray
      __funcall("keys").as(RArray)
    end

    def to_h : Hash(RbValue, RbValue)
      hash = {} of RbValue => RbValue
      each { |(k, v)| hash[k] = v }
      hash
    end
  end
end
