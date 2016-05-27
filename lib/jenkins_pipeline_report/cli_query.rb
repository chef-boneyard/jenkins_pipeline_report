module JenkinsPipelineReport
  module CliQuery
    def self.parse(query)
      if query.start_with?("!")
        Not.new(parse(query[1..-1]))
      elsif (q = query.split("!=", 2)) && q[1] || (q = query.split("<>", 2)) && q[1]
        NotEquals.new(Field.new(q[0]), parse(q[1]))
      elsif (q = query.split("=", 2)) && q[1]
        values = q[1].split(",")
        values = values.map { |value| Equals.new(Field.new(q[0]), Value.new(value)) }
        self.or(*values)
      elsif (q = query.split("~=, 2")) && q[1]
        Matches.new(Field.new(q[0]), Value.new(new Regexp(q[1])))
      else
        Exists.new(Field.new(query))
      end
    end

    def self.or(*queries)
      result = queries.first
      queries[1..-1].each do |query|
        result = Or.new(result, query)
      end
      result
    end

    def self.and(*queries)
      result = queries.first
      queries[1..-1].each do |query|
        result = And.new(result, query)
      end
      result
    end

    private

    class Field < Struct.new(:field)
      def composite_field
        @composite_field ||= field.split(".")
      end
      def resolve(build)
        value = build
        composite_field.each do |field|
          value = value[field]
          return nil if value.nil?
        end
        value
      end
    end
    class Value < Struct.new(:value)
      def resolve(build)
        value
      end
    end

    class Operation < Struct.new(:operands)
      def initialize(*operands)
        super(operands)
      end

      def resolve_operands(build)
        operands.map { |operand| operand.resolve(build) }
      end
      def resolve(build)
        match(*resolve_operands(build))
      end
      def ===(build)
        match(*resolve_operands(build))
      end
      # Subclasses implement def match(*values)
    end
    class Not < Operation
      def match(value)
        !value
      end
    end
    class And < Operation
      def match(a,b)
        a && b
      end
    end
    class Or < Operation
      def match(a,b)
        a || b
      end
    end
    class Exists < Operation
      def match(a)
        !a.nil?
      end
    end
    class Equals < Operation
      def match(a,b)
        a.to_s == b.to_s
      end
    end
    class NotEquals < Operation
      def match(a,b)
        a.to_s != b.to_s
      end
    end
    class Matches < Operation
      def match(a,b)
        b === a
      end
    end
  end
end
