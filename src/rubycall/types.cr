# Замкнутый union «значение из Ruby» (Object нельзя в generic-аргументах
# Crystal — как PyValue в pycall.cr).

module RubyCall
  alias RbValue = Nil | Bool | Int64 | Float64 | String | RWrap

  # Результат ruby{}-блока (Object нельзя в generic-аргументах Crystal).
  alias RbResult = RbValue | Array(RbValue)

  # Значение для kwargs-вызовов (скаляры и обёртки; вложенные Array/Hash
  # конвертируются через Conversion при позиционных аргументах).
  alias RbArg = Nil | Bool | Int64 | Float64 | String | Symbol | RWrap
end
