# RubyCall::Error / RubyError — порт идеи PyError из pycall.cr:
# class + message + backtrace снимаются сразу (VALUE в строку), чтобы
# не держать ссылку на исключение Ruby после размотки.

module RubyCall
  class Error < ::Exception
  end

  class RubyError < Error
    getter ruby_class : String
    getter ruby_message : String?
    getter ruby_backtrace : Array(String)?

    def initialize(@ruby_class, @ruby_message, @ruby_backtrace)
        msg = String.build do |io|
          io << @ruby_class
          io << ": " << @ruby_message if @ruby_message
          if (bt = @ruby_backtrace) && !bt.empty?
            bt.each { |line| io << "\n  " << line }
          end
        end
      super(msg)
    end

    # Исполняется на воркере внутри уже поднятого rb_errinfo.
    def self.from_value(err : LibRuby::Value, context : String) : RubyError
      return RubyError.new("RubyError", "(no exception raised by #{context})", nil) if err == Helpers.qnil

      slot = Helpers.keep(err)
      begin
        cls = String.new(LibRuby.rb_obj_classname(err))
        msg = nil
        bt = nil
        begin
          msg_v = Helpers.call(slot, "message", nil, nil)
          msg = Conversion.to_crystal(msg_v).as?(String)
        rescue RubyCall::Error
        end
        begin
          bt_v = Helpers.call(slot, "backtrace", nil, nil)
          if bt_v != Helpers.qnil
            bt_slot = Helpers.keep(bt_v)
            begin
              bt_wrap = RArray.new(bt_slot.value)
              lines = [] of String
              bt_wrap.each do |line|
                lines << line.to_s
              end
              bt = lines
            ensure
              Helpers.unkeep(bt_slot)
            end
          end
        rescue RubyCall::Error
        end
        RubyError.new(cls, msg, bt)
      ensure
        Helpers.unkeep(slot)
      end
    end
  end
end
