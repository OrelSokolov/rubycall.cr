# Сквозной пример rubycall_cr: вызов MRI Ruby из Crystal.
# Запуск: crystal run examples/smoke.cr
require "../src/rubycall_cr"

# версия + eval
p RubyCall.ruby_version
p RubyCall.eval("40 + 2")

# import модуля и method_missing → rb_funcall
math = RubyCall.import("Math").as(RubyCall::RWrap)
p math.const_get("PI")
p math.sin(0.5)
p math.hypot(3, 4)
p RubyCall.eval("Rational(37, 10)").as(RubyCall::RWrap).floor

# массив
lst = RubyCall.eval("[3, 1, 2]").as(RubyCall::RArray)
p lst.to_a
lst.sort!
p lst.to_a
lst << 99
p lst.to_a
p lst.include?(2)
p lst.size

# хеш
h = RubyCall.eval("{'a' => 1, 'b' => 2}").as(RubyCall::RHash)
p h["a"]
p h.fetch("zzz")          # nil
p h.has_key?("b")
p h.size
p h.to_h.map { |k, v| "#{k}=#{v}" }.sort.join(";")
p h.delete("b")

# операторы на непримитивах (Rational)
r1 = RubyCall.eval("Rational(1, 3)").as(RubyCall::RWrap)
r2 = RubyCall.eval("Rational(1, 6)").as(RubyCall::RWrap)
p (r1 + r2).to_s
p (r1 * r2).to_s
p (r1 - r2).to_s
p (r1 / r2).to_s
p r1 > r2
p r1 == RubyCall.eval("Rational(1, 3)")

# строки / inspect
p RubyCall.eval("'abc' * 3")
p RubyCall.eval("'42'").as(String).to_i
p RubyCall.eval("[1, 'x']").as(RubyCall::RWrap).inspect

# kwargs через rb_funcallv_kw
RubyCall.eval("def kwtest(a:, b:); a * 100 + b; end")
main = RubyCall.eval("self").as(RubyCall::RWrap)
p main.kwtest(a: 1, b: 7)

# блок Crystal → ruby-блок (rb_block_call)
p RubyCall.eval("[1, 2, 3]").as(RubyCall::RArray)
  .with_block("map") { |vals| vals[0].as(Int64) * 2 }.as(RubyCall::RArray).to_a

# мульти-yield
RubyCall.eval("def multi; yield 10, 20; end")
p main.with_block("multi") { |vals| vals[0].as(Int64) + vals[1].as(Int64) }

# ivar set/get
o = RubyCall.eval("Object.new").as(RubyCall::RWrap)
o.instance_variable_set("@x", 123)
p o.instance_variable_get("@x")

# respond_to?
p o.respond_to?(:to_s)
p RubyCall.callable?(RubyCall.eval("->(x) { x }"))
p RubyCall.callable?(RubyCall.eval("42"))

# исключения
begin
  RubyCall.eval("1/0")
rescue e : RubyCall::RubyError
  STDERR.puts "RubyError: #{e.ruby_class}"
end

STDERR.puts "SMOKE OK"
