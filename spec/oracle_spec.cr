# Oracle spec: порт обязан воспроизвести oracle/expected.yml — значения
# сняты с настоящего Ruby 3.3.8 (/usr/bin/ruby, libruby из pkg-config "ruby")
# в том же окружении.

require "spec"
require "../src/rubycall_cr"

EXPECTED = begin
  hash = {} of String => String
  File.read("#{__DIR__}/../oracle/expected.yml").each_line do |line|
    if line.includes?('\t')
      id, value = line.split('\t', 2)
      hash[id] = value.chomp
    end
  end
  hash
end

def check(id, value)
  (EXPECTED[id]? || "MISSING #{id}").should eq value.to_s
end

describe "RubyCall oracle" do
  math = RubyCall.import("Math").as(RubyCall::RWrap)
  main = RubyCall.eval("self").as(RubyCall::RWrap)

  it "version" do
    check("ruby.version", RubyCall.ruby_version)
  end

  it "module calls (method_missing) и константа" do
    check("math.pi", math.const_get("PI"))
    check("math.sin(0.5)", math.sin(0.5))
    check("math.hypot(3,4)", math.hypot(3, 4))
    check("rational.floor", RubyCall.eval("Rational(37, 10)").as(RubyCall::RWrap).floor)
  end

  it "eval" do
    check("eval.int", RubyCall.eval("40 + 2"))
  end

  it "Array wrapper" do
    lst = RubyCall.eval("[3, 1, 2]").as(RubyCall::RArray)
    check("list.to_a", lst.to_a)
    lst.sort!
    check("list.sort!", lst.to_a)
    lst << 99
    check("list.push", lst.to_a)
    check("list.include?", lst.include?(2))
    check("list.size", lst.size)
  end

  it "Hash wrapper" do
    h = RubyCall.eval("{'a' => 1, 'b' => 2}").as(RubyCall::RHash)
    check("dict.get", h["a"])
    check("dict.missing", h.fetch("zzz").to_s)
    check("dict.has_key?", h.has_key?("b"))
    check("dict.size", h.size)
    check("dict.to_h", h.to_h.map { |k, v| "#{k}=#{v}" }.sort.join(";"))
    check("dict.delete", h.delete("b"))
  end

  it "ruby-операторы через method_missing (Rational)" do
    a = RubyCall.eval("Rational(1, 3)").as(RubyCall::RWrap)
    b = RubyCall.eval("Rational(1, 6)").as(RubyCall::RWrap)
    check("rational.add", a + b)
    check("rational.mul", a * b)
    check("rational.sub", a - b)
    check("rational.div", a / b)
    check("rational.gt", a > b)
    check("rational.eq", a == RubyCall.eval("Rational(1, 3)"))
  end

  it "строки / inspect / to_i / to_f" do
    check("str.mul", RubyCall.eval("'abc' * 3"))
    check("str.to_i", RubyCall.eval("'42'").as(String).to_i)
    check("str.to_f", RubyCall.eval("'2.5'").as(String).to_f)
    check("repr", RubyCall.eval("[1, 'x']").as(RubyCall::RWrap).inspect)
  end

  it "kwargs-вызов (rb_funcallv_kw)" do
    RubyCall.eval("def kwtest(a:, b:); a * 100 + b; end")
    check("kwargs.kwtest", main.kwtest(a: 1, b: 7))
  end

  it "Proc → ruby-блок (rb_block_call)" do
    check("block.map", RubyCall.eval("[1, 2, 3]").as(RubyCall::RArray)
      .with_block("map") { |vals| vals[0].as(Int64) * 2 }.as(RubyCall::RArray).to_a)
    RubyCall.eval("def multi; yield 10, 20; end")
    check("block.multi", main.with_block("multi") { |vals| vals[0].as(Int64) + vals[1].as(Int64) })
  end

  it "ivar set/get, respond_to?" do
    o = RubyCall.eval("Object.new").as(RubyCall::RWrap)
    o.instance_variable_set("@x", 123)
    check("ivar.get", o.instance_variable_get("@x"))
    check("respond_to?", o.respond_to?(:to_s))
  end

  it "callable?" do
    check("callable?.proc", RubyCall.callable?(RubyCall.eval("->(x) { x }")))
    check("callable?.int", RubyCall.callable?(RubyCall.eval("42")))
  end

  it "конвертация Array/Hash из Crystal" do
    f = RubyCall.eval("->(x) { x }").as(RubyCall::RWrap)
    check("conv.array", f.call([1, 2, 3]).as(RubyCall::RArray).to_a)
    check("conv.hash", f.call({"a" => 1, "b" => 2}).as(RubyCall::RHash)
      .to_h.map { |k, v| "#{k}=#{v}" }.sort.join(";"))
  end

  it "RubyError с ruby-классом" do
    begin
      RubyCall.eval("1/0")
      fail("должно было упасть RubyError")
    rescue e : RubyCall::RubyError
      check("error.class", e.ruby_class)
    end
  end

  # Глобальный MUTEX + GVL-воркер: параллельные вызовы из множества фибер
  # (на N тредах кристаллического планировщика) не роняют интерпретатор
  # и не теряют данные.
  it "параллельные вызовы: 8 фибер × 100 итераций" do
    shared = RubyCall.eval("[]").as(RubyCall::RArray)
    ch = Channel(Nil).new
    8.times do
      spawn do
        100.times do |i|
          RubyCall.eval("#{i} * 2").as(Int64).should eq(i * 2)
          math.sin(0.5)
          shared << i
          shared.size
        end
        ch.send(nil)
      end
    end
    8.times { ch.receive }
    shared.size.should eq(800)
  end

  it "параллельные вызовы с блоками" do
    ch = Channel(Nil).new
    4.times do
      spawn do
        20.times do |i|
          mapped = RubyCall.eval("[#{i}, #{i + 1}]").as(RubyCall::RArray)
            .with_block("map") { |vals| vals[0].as(Int64) * 3 }.as(RubyCall::RArray)
          mapped.size.should eq(2)
        end
        ch.send(nil)
      end
    end
    4.times { ch.receive }
  end
end
