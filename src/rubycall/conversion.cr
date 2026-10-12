# Конвертация типов Crystal ↔ Ruby (только на воркер-треде).

module RubyCall
  module Conversion
    class UnconvertibleError < RubyCall::Error
    end

    # Crystal → Ruby VALUE. Результат немедленно укореняется вызывающим
    # (push в контейнер / keep-слот / аргумент C-вызова) — сам по себе он
    # живёт только на стеке.
    def self.from_crystal(value) : LibRuby::Value
      case value
      when RWrap       then value.value
      when Nil         then Helpers.qnil
      when Bool        then value ? Helpers.qtrue : Helpers.qfalse
      when Int         then Helpers.ll2fix(value.to_i64)
      when Float       then LibRuby.rb_float_new(value.to_f64)
      when String      then LibRuby.rb_str_new(value.to_unsafe, value.bytesize.to_i64)
      when Symbol      then LibRuby.rb_id2sym(Helpers.mid_for(value.to_s))
      when Array
        ary = LibRuby.rb_ary_new_capa(value.size)
        value.each { |el| LibRuby.rb_ary_push(ary, from_crystal(el)) }
        ary
      when Hash
        h = LibRuby.rb_hash_new
        value.each do |k, v|
          pk = from_crystal(k)
          pv = from_crystal(v)
          LibRuby.rb_hash_aset(h, pk, pv)
        end
        h
      else
        raise UnconvertibleError.new("Unable to convert #{value.class} to Ruby value")
      end
    end

    # Ruby VALUE → Crystal. VALUE обязан быть укоренён (слот/контейнер),
    # т.к. здесь мы создаём Crystal-объекты (аллокации → GC).
    def self.to_crystal(v : LibRuby::Value) : RbValue
      return nil if v == Helpers.qnil
      return true if v == Helpers.qtrue
      return false if v == Helpers.qfalse

      if Helpers.kind_of?(v, LibRuby.rb_c_integer)
        # bignum за пределами i64 → оставить обёрткой
        begin
          return Helpers.fix2ll(Helpers.protect("rb_num2ll", ->Helpers.num2ll_tramp(LibRuby::Value), v))
        rescue RubyError
          return RWrap.new(v)
        end
      end

      return LibRuby.rb_num2dbl(v) if Helpers.kind_of?(v, LibRuby.rb_c_float)

      if Helpers.kind_of?(v, LibRuby.rb_c_string)
        ptr = LibRuby.rb_string_value_ptr(pointerof(v)) # v — на стеке вызывающего
        return String.new(ptr, LibRuby.rb_str_strlen(v).to_i32)
      end

      if Helpers.kind_of?(v, LibRuby.rb_c_symbol)
        name = LibRuby.rb_id2name(LibRuby.rb_sym2id(v))
        return String.new(name)
      end

      if Helpers.kind_of?(v, LibRuby.rb_c_array)
        return RArray.new(v)
      end

      if Helpers.kind_of?(v, LibRuby.rb_c_hash)
        return RHash.new(v)
      end

      RWrap.new(v)
    end
  end
end
